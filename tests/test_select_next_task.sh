#!/usr/bin/env bash
# claude-code/skills/improvement-dispatch/scripts/select-next-task に対するテスト。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 1. claude-code/skills/improvement-dispatch/scripts/select-next-task の選定ロジック検証 ==="
# improvement ループの6ステータスが揃った一時 backlog リポジトリに対して
# select-next-task を実行し、選定ロジック（除外集合の計算・依存確認・優先度ソート・
# 閾値判定）の各パターンを検証する。

# 一時リポジトリの準備に bin/setup-improvement-loop は使わない。select-next-task が要るのは
# 6ステータスが揃った .backlog/config.yml だけで（閾値は引数で受け取るため config.my.yml は
# 読まない）、setup を通すと backlog CLI が5回起動して約900ms かかるためである。
# 引数: <変数名> <task_prefix>。一時リポジトリを作り、そのパスを変数に入れる。
make_select_repo() {
  local dir
  dir="$(mktemp -d)"
  register_tmp_cleanup "$dir"
  (cd "$dir" && git init -q)
  mkdir -p "$dir/.backlog"
  cat > "$dir/.backlog/config.yml" <<YAML
project_name: "select-next-task-test"
default_status: "To Do"
statuses: ["Proposed", "To Do", "In Progress", "In Review", "Approved", "Done"]
labels: []
date_format: yyyy-mm-dd
max_column_width: 20
auto_open_browser: true
default_port: 6420
remote_operations: false
auto_commit: false
filesystem_only: false
bypass_git_hooks: false
check_active_branches: true
active_branch_days: 30
task_prefix: "$2"
YAML
  printf -v "$1" '%s' "$dir"
}

# 引数: <リポジトリ> <backlog の引数...>。テストの前提を作るための backlog 呼び出し。
bl() {
  local repo="$1"
  shift
  (cd "$repo" && backlog "$@" --plain >/dev/null)
}

# select_expect <ラベル> <リポジトリ> <max_in_progress> <max_in_review> <期待する終了コード> [出力に含むべき行...]
select_expect() {
  local label="$1" repo="$2" max_ip="$3" max_ir="$4" code="$5"
  shift 5
  run_in "$repo" "$SELECT_SCRIPT" "$max_ip" "$max_ir"
  assert "select-next-task: $label" run_result "$code" "$@"
}

make_select_repo TMP_REPO_SELECT task

# --- 1a. NO_CANDIDATE: To Do タスクが1件も無い ---
select_expect "To Do が無いとき RESULT: NO_CANDIDATE（exit 2）" "$TMP_REPO_SELECT" 1 3 2 'RESULT: NO_CANDIDATE'

# 依存は create 時に付ける（後から edit で付ける呼び出しを省く）。TASK-3 は TASK-1 に依存する。
bl "$TMP_REPO_SELECT" task create "Low task" --priority low
bl "$TMP_REPO_SELECT" task create "High task" --priority high
bl "$TMP_REPO_SELECT" task create "Medium task A" --priority medium --dep task-1
bl "$TMP_REPO_SELECT" task create "Medium task B" --priority medium

# --- 1b. 通常選定: 優先度最高（High、TASK-2）が選ばれる ---
select_expect "優先度最高（High, TASK-2）が選定される" "$TMP_REPO_SELECT" 1 3 0 'TASK_ID: TASK-2'

# --- 1c. blocked:needs-decision ラベル除外と、依存タスク未完了の除外 ---
# blocked の除外が壊れると TASK-2、依存の除外が壊れると TASK-3 が選ばれて FAIL する。
bl "$TMP_REPO_SELECT" task edit TASK-2 --label 'blocked:needs-decision'
select_expect "blocked:needs-decision 付き（TASK-2）と、未完了の依存（TASK-1）を持つ TASK-3 を除外し、TASK-4 を選ぶ" \
  "$TMP_REPO_SELECT" 1 3 0 'TASK_ID: TASK-4'

# --- 1d. 依存解消後の再選定と、同優先度タイブレークがID最小になる ---
# 依存タスクを Done にすると、除外されていた TASK-3 が同優先度の TASK-4 より先に選ばれる。
bl "$TMP_REPO_SELECT" task edit TASK-1 -s "Done"
select_expect "依存タスク（TASK-1）が Done になると、同優先度でID最小の TASK-3 が選ばれる" "$TMP_REPO_SELECT" 1 3 0 'TASK_ID: TASK-3'

# --- 1e. max_in_progress GATED ---
bl "$TMP_REPO_SELECT" task edit TASK-3 -s "In Progress"
select_expect "In Progress が max_in_progress 以上のとき RESULT: GATED / REASON: max_in_progress（exit 1）" \
  "$TMP_REPO_SELECT" 1 3 1 'RESULT: GATED' 'REASON: max_in_progress' 'IN_PROGRESS_COUNT: 1'

# --- 1f. max_in_review GATED ---
# TASK-3 は In Progress のまま、max_in_progress を 2 にして In Progress のゲートを通す。
bl "$TMP_REPO_SELECT" task edit TASK-4 -s "In Review"
select_expect "In Review が max_in_review 以上のとき RESULT: GATED / REASON: max_in_review（exit 1）" \
  "$TMP_REPO_SELECT" 2 1 1 'RESULT: GATED' 'REASON: max_in_review' 'IN_REVIEW_COUNT: 1'

echo ""
echo "=== 2. task_prefix をカスタマイズしたリポジトリでの回帰テスト（TASK-54） ==="
# ID は .backlog/config.yml の task_prefix に応じて変わる（task_prefix: "issue" なら
# "ISSUE-<n>"）。ID 抽出・件数カウントを "TASK-" 固定パターンで行うと、prefix を
# カスタマイズしたリポジトリでは常に0件になり、To Do が実在しても NO_CANDIDATE を返し続け、
# 閾値によるゲーティングも機能しなくなる。その回帰テストである。
# In Review の件数も In Progress と同じ関数で数えるので、ゲートの確認は In Progress で行う。
make_select_repo TMP_REPO_CUSTOM_PREFIX_SELECT issue

# --- 2a. AC#1: To Do タスクが存在するとき RESULT: SELECTED / 正しい TASK_ID (ISSUE-1) ---
bl "$TMP_REPO_CUSTOM_PREFIX_SELECT" task create "Custom prefix task" --priority high
select_expect "AC#1: task_prefix をカスタマイズしたリポジトリ（ISSUE-1）でも RESULT: SELECTED / TASK_ID: ISSUE-1 を返す" \
  "$TMP_REPO_CUSTOM_PREFIX_SELECT" 1 3 0 'RESULT: SELECTED' 'TASK_ID: ISSUE-1'

# --- 2b. AC#2: In Progress の件数が max_in_progress 以上のとき RESULT: GATED ---
bl "$TMP_REPO_CUSTOM_PREFIX_SELECT" task edit ISSUE-1 -s "In Progress"
select_expect "AC#2: task_prefix をカスタマイズしたリポジトリでも In Progress の件数が正しく数えられ RESULT: GATED / REASON: max_in_progress を返す" \
  "$TMP_REPO_CUSTOM_PREFIX_SELECT" 1 3 1 'RESULT: GATED' 'REASON: max_in_progress' 'IN_PROGRESS_COUNT: 1'

echo ""
echo "=== 3. 複数依存・存在しない依存の扱い（TASK-99） ==="
# backlog CLI 1.53.0 の task view --plain は "Dependencies:" 行を出さず、
# "Dependency Graph:" の "Depends on" 木で依存を表す。依存の一部だけが Done の場合、
# 推移的依存を持つ場合、存在しない依存を持つ場合に、直接依存を正しく読み取って
# 判定できることを確かめる。1.48.0 の "Dependencies:" 行の形式でも同じ結果になる。
# 3 節は実 CLI の出力形式を確かめる経路として実 CLI のまま残す。両形式の依存解析と存在しない
# 依存の扱いは、実 CLI のバージョンによらず 4b〜4f がスタブで検証する。
# 状態・依存・優先度は create 時に指定し、edit は To Do の候補を外すときだけ呼ぶ。
make_select_repo TMP_REPO_DEPS_SELECT task

# 依存先として TASK-1（Done）、TASK-2（In Review。未完了）、TASK-3（Done）を用意する。
# 木の中で未完了の依存が "├─" 側・"└─" 側のどちらに来ても除外できることを確かめるため、
# TASK-4 は TASK-2（未完了）・TASK-3（Done）の順、TASK-5 は TASK-1（Done）・TASK-2（未完了）の順に依存させる。
# TASK-6 は Done の TASK-1・TASK-3 だけに依存させる。
bl "$TMP_REPO_DEPS_SELECT" task create "Dep done A" -s "Done"
bl "$TMP_REPO_DEPS_SELECT" task create "Dep open" -s "In Review"
bl "$TMP_REPO_DEPS_SELECT" task create "Dep done B" -s "Done"
bl "$TMP_REPO_DEPS_SELECT" task create "Open dep first" --priority high --dep task-2,task-3
bl "$TMP_REPO_DEPS_SELECT" task create "Open dep last" --priority high --dep task-1,task-2
bl "$TMP_REPO_DEPS_SELECT" task create "All deps done" --priority medium --dep task-1,task-3

# --- 3a. 依存の一部だけが未完了のタスク（TASK-4・TASK-5）は並び順によらず除外され、全依存 Done の TASK-6 が選ばれる ---
select_expect "未完了の依存（TASK-2）が先頭でも末尾でも TASK-4・TASK-5 を除外し、全依存 Done の TASK-6 を選ぶ" \
  "$TMP_REPO_DEPS_SELECT" 1 3 0 'TASK_ID: TASK-6'

# --- 3b. 判定は直接依存だけで行う。直接依存（TASK-7）が Done なら、その先の推移的依存（TASK-2）が未完了でも TASK-8 は選ばれる ---
# 1.48.0 の "Dependencies:" 行も直接依存だけを列挙するので、その挙動に揃える。
# select-next-task は To Do の候補をすべて view するので、3a の候補は Proposed に移して
# 以降の選定での view を減らす（edit 3回で、以降3回の選定の view 計約24回を省く）。
bl "$TMP_REPO_DEPS_SELECT" task edit TASK-4 -s "Proposed"
bl "$TMP_REPO_DEPS_SELECT" task edit TASK-5 -s "Proposed"
bl "$TMP_REPO_DEPS_SELECT" task edit TASK-6 -s "Proposed"
bl "$TMP_REPO_DEPS_SELECT" task create "Done with open dep" -s "Done" --dep task-2
bl "$TMP_REPO_DEPS_SELECT" task create "Needs TASK-7" --priority low --dep task-7
select_expect "直接依存（TASK-7）が Done なら、推移的依存（TASK-2）が未完了でも TASK-8 を選ぶ" \
  "$TMP_REPO_DEPS_SELECT" 1 3 0 'TASK_ID: TASK-8'

# --- 3c. 存在しない依存を持つタスクは ERROR にならず、未完了扱いで除外される ---
# backlog CLI は存在しない ID を --dep で受け付けないため、依存先タスクが後から
# 消えた状況をタスクファイルの frontmatter を直接書き換えて再現する（一時リポジトリ内のみ）。
# Done の直接依存（TASK-7）の後ろに存在しない依存（TASK-77）を足す。
dep_task_file="$(ls "$TMP_REPO_DEPS_SELECT"/.backlog/tasks/task-8\ -*.md)"
# テストの依存を bash・git・backlog に限るため、perl や sed -i（GNU/BSD で書式が違う）は使わない。
awk '{ print } $0 == "  - TASK-7" { print "  - TASK-77" }' "$dep_task_file" > "$dep_task_file.tmp" \
  && mv "$dep_task_file.tmp" "$dep_task_file"
select_expect "存在しない依存（TASK-77）を持つ TASK-8 を未完了扱いで除外し NO_CANDIDATE を返す" \
  "$TMP_REPO_DEPS_SELECT" 1 3 2 'RESULT: NO_CANDIDATE'

# --- 3d. 説明文に依存表記と同じ見た目の行があっても依存として読まない ---
# 自由記述の説明文（例: 不具合報告に CLI 出力を貼ったもの）の "Dependencies:" 行や
# "Depends on" 木を依存と誤読すると、存在しない ID の view が失敗して RESULT: ERROR になる。
bl "$TMP_REPO_DEPS_SELECT" task create "Quotes CLI output" --priority high \
  -d $'Dependencies: see notes\nDependency Graph:\n--------------------------------------------------\nDepends on (1 direct, 1 total):\n└─ foo - fake'
select_expect "説明文中の依存表記に似た行を無視し、依存の無い TASK-9 を選ぶ" "$TMP_REPO_DEPS_SELECT" 1 3 0 'TASK_ID: TASK-9'

echo ""
echo "=== 4. backlog CLI の出力順・バージョンによらない選定ロジックの検証（TASK-103） ==="
# 実 CLI（1.53.0）の task list は最初から優先度→ID順で返し、task view の依存の形式は
# CLI のバージョンで違う。そのため 1〜3 節だけでは、select-next-task 自身の
# 優先度→数値ID順の選定と、実行環境の CLI と違うバージョンの形式の依存解析が壊れても検出できない。
# ここでは PATH の先頭に backlog のスタブを置き、固定の出力を返させて検証する。
# スタブは SELECT_STUB_FIXTURE_DIR 配下の次のファイルを返す。
#   task list --plain                         -> list.txt
#   task list --status "To Do" --labels blocked:needs-decision --plain -> blocked.txt
#   task view <ID> --plain                    -> view-<ID>.txt（無ければ exit 1）
# それ以外の呼び出しは想定外として exit 1 にする。

STUB_ROOT_SELECT="$(mktemp -d)"
register_tmp_cleanup "$STUB_ROOT_SELECT"
mkdir -p "$STUB_ROOT_SELECT/bin"
cat > "$STUB_ROOT_SELECT/bin/backlog" <<'STUB'
#!/usr/bin/env bash
set -u
dir="${SELECT_STUB_FIXTURE_DIR:?}"
if [ "$#" -eq 3 ] && [ "$1 $2 $3" = "task list --plain" ]; then
  cat "$dir/list.txt"
  exit 0
fi
if [ "$#" -eq 7 ] && [ "$1 $2 $3 $4 $5 $6 $7" = "task list --status To Do --labels blocked:needs-decision --plain" ]; then
  cat "$dir/blocked.txt"
  exit 0
fi
if [ "$#" -eq 4 ] && [ "$1 $2 $4" = "task view --plain" ] && [ -f "$dir/view-$3.txt" ]; then
  cat "$dir/view-$3.txt"
  exit 0
fi
printf 'backlog スタブ: 想定外の呼び出し: %s\n' "$*" >&2
exit 1
STUB
chmod +x "$STUB_ROOT_SELECT/bin/backlog"

# $1 = フィクスチャのディレクトリ、$2 以降 = タスクID。依存無しの view をID ごとに書く。
write_stub_view_without_deps() {
  local dir="$1"
  shift
  local id
  for id in "$@"; do
    printf 'Task %s - stub\n==================================================\n\nStatus: ○ To Do\n\nDescription:\n--------------------------------------------------\nstub\n' \
      "$id" > "$dir/view-$id.txt"
  done
}

# --- 4a. CLI が優先度・ID の順になっていない一覧を返しても、High の中で数値ID最小（TASK-4）を選ぶ ---
# 先頭は Low、High は TASK-9・TASK-10・TASK-4 の順に並べる。選定ループを無効化すると TASK-1、
# 同優先度のID比較を無効化すると TASK-9、ID を文字列で比べると TASK-10 が選ばれて FAIL する。
FIXTURE_ORDER_SELECT="$STUB_ROOT_SELECT/order"
mkdir -p "$FIXTURE_ORDER_SELECT"
cat > "$FIXTURE_ORDER_SELECT/list.txt" <<'LIST'
To Do:
  [LOW] TASK-1 - Low first
  TASK-2 - No priority
  [MEDIUM] TASK-3 - Medium
  [HIGH] TASK-9 - High nine
  [HIGH] TASK-10 - High ten
  [HIGH] TASK-4 - High four
  [MEDIUM] TASK-5 - Medium five

LIST
: > "$FIXTURE_ORDER_SELECT/blocked.txt"
write_stub_view_without_deps "$FIXTURE_ORDER_SELECT" TASK-1 TASK-2 TASK-3 TASK-9 TASK-10 TASK-4 TASK-5
select_out="$(cd "$STUB_ROOT_SELECT" && PATH="$STUB_ROOT_SELECT/bin:$PATH" SELECT_STUB_FIXTURE_DIR="$FIXTURE_ORDER_SELECT" "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-4'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: CLI が未ソートの順で返しても、優先度最高（High）の中で数値ID最小の TASK-4 を選ぶ"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: 未ソートの候補一覧からの選定結果が期待と異なる（TASK-4 を期待、exit ${select_exit}）:
$select_out"
fi

# --- 4b. 1.48.0 形式の "Dependencies:" 行を読み、未完了の依存を持つタスクを除外する ---
# High の TASK-4 は "Dependencies: TASK-3, TASK-7" を持ち、TASK-3 は Done、TASK-7 は In Progress。
# 未完了の依存を末尾に置き、カンマ区切りの全要素を見ていることも確かめる。
# 1.48.0 形式の解析を無効化すると TASK-4 が選ばれて FAIL する。
# 4b〜4f のフィクスチャは、各節に書いたバージョンの実 CLI の stdout を写したものである
# （取得日 2026-09-27。File: 行の一時リポジトリのパスだけ "<一時リポジトリ>" に置き換えた）。
# 4b は backlog CLI 1.48.0 の出力。TASK-1・TASK-2・TASK-5 を作ってから archive し、ID を揃えた。
FIXTURE_DEPS148_SELECT="$STUB_ROOT_SELECT/deps148"
mkdir -p "$FIXTURE_DEPS148_SELECT"
cat > "$FIXTURE_DEPS148_SELECT/list.txt" <<'LIST'
To Do:
  [HIGH] TASK-4 - Has open dep
  [MEDIUM] TASK-6 - Has done dep

In Progress:
  TASK-7 - Open dep

Done:
  TASK-3 - Done dep

LIST
cat > "$FIXTURE_DEPS148_SELECT/blocked.txt" <<'LIST'
No tasks found.
LIST
cat > "$FIXTURE_DEPS148_SELECT/view-TASK-4.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-4 - Has-open-dep.md

Task TASK-4 - Has open dep
==================================================

Status: ○ To Do
Priority: High
Ordinal: 4000
Created: 2026-09-27 05:26 (UTC)
Updated: 2026-09-27 05:26 (UTC)
Dependencies: TASK-3, TASK-7

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

VIEW
cat > "$FIXTURE_DEPS148_SELECT/view-TASK-6.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-6 - Has-done-dep.md

Task TASK-6 - Has done dep
==================================================

Status: ○ To Do
Priority: Medium
Ordinal: 6000
Created: 2026-09-27 05:26 (UTC)
Updated: 2026-09-27 05:26 (UTC)
Dependencies: TASK-3

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

VIEW
cat > "$FIXTURE_DEPS148_SELECT/view-TASK-3.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-3 - Done-dep.md

Task TASK-3 - Done dep
==================================================

Status: ✔ Done
Ordinal: 3000
Created: 2026-09-27 05:26 (UTC)
Updated: 2026-09-27 05:26 (UTC)

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

VIEW
cat > "$FIXTURE_DEPS148_SELECT/view-TASK-7.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-7 - Open-dep.md

Task TASK-7 - Open dep
==================================================

Status: ◒ In Progress
Ordinal: 7000
Created: 2026-09-27 05:26 (UTC)
Updated: 2026-09-27 05:26 (UTC)

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

VIEW
# max_in_progress は In Progress の TASK-7 でゲートされないよう 2 にする。
select_out="$(cd "$STUB_ROOT_SELECT" && PATH="$STUB_ROOT_SELECT/bin:$PATH" SELECT_STUB_FIXTURE_DIR="$FIXTURE_DEPS148_SELECT" "$SELECT_SCRIPT" 2 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-6'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: 1.48.0 形式の Dependencies: 行から未完了の依存（TASK-7）を読み、TASK-4 を除外して TASK-6 を選ぶ"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: 1.48.0 形式の依存行を持つタスクの選定結果が期待と異なる（TASK-6 を期待、exit ${select_exit}）:
$select_out"
fi

# --- 4c. 1.53.0 形式の "Dependency Graph:" の木から直接依存だけを読む ---
# backlog CLI 1.53.0 の出力。TASK-1 は In Progress、TASK-2 は TASK-1 に依存する Done。
# High の TASK-3 は TASK-1（未完了）に直接依存し、High の TASK-4 は TASK-2（Done）に直接依存する。
# TASK-4 の木には推移的依存の TASK-1（未完了）がインデント付きで出て、木の後には
# Proposed の TASK-6 を並べた "Dependents" セクションが続く。
# 期待は TASK-3 を除外して TASK-4 を選ぶこと。木の解析を無効化すると TASK-3 が選ばれ、
# 推移的依存を依存として読むと TASK-4 も除外され、Dependents の木まで読むとスタブに view の無い
# ID を引いて RESULT: ERROR になり、どちらも FAIL する。
FIXTURE_TREE153_SELECT="$STUB_ROOT_SELECT/tree153"
mkdir -p "$FIXTURE_TREE153_SELECT"
cat > "$FIXTURE_TREE153_SELECT/list.txt" <<'LIST'
Proposed:
  TASK-5 - Depends on TASK-3
  TASK-6 - Depends on TASK-4

To Do:
  [HIGH] TASK-3 - Direct open dep
  [HIGH] TASK-4 - Transitive open dep only

In Progress:
  TASK-1 - Open dep

Done:
  TASK-2 - Done dep with open dep

LIST
cat > "$FIXTURE_TREE153_SELECT/blocked.txt" <<'LIST'
No tasks found.
LIST
cat > "$FIXTURE_TREE153_SELECT/view-TASK-3.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-3 - Direct-open-dep.md

Task TASK-3 - Direct open dep
==================================================

Status: ○ To Do
Priority: High
Ordinal: 3000
Created: 2026-09-27 05:26 (UTC)

Dependency Graph:
--------------------------------------------------
Depends on (1 direct, 1 total):
└─ TASK-1 - Open dep [In Progress]

Dependents (1 direct, 1 total):
└─ TASK-5 - Depends on TASK-3 [Proposed]

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

VIEW
cat > "$FIXTURE_TREE153_SELECT/view-TASK-4.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-4 - Transitive-open-dep-only.md

Task TASK-4 - Transitive open dep only
==================================================

Status: ○ To Do
Priority: High
Ordinal: 4000
Created: 2026-09-27 05:26 (UTC)

Dependency Graph:
--------------------------------------------------
Depends on (1 direct, 2 total):
└─ TASK-2 - Done dep with open dep [completed]
   └─ TASK-1 - Open dep [In Progress]

Dependents (1 direct, 1 total):
└─ TASK-6 - Depends on TASK-4 [Proposed]

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

VIEW
cat > "$FIXTURE_TREE153_SELECT/view-TASK-1.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-1 - Open-dep.md

Task TASK-1 - Open dep
==================================================

Status: ◒ In Progress
Ordinal: 1000
Created: 2026-09-27 05:26 (UTC)
Updated: 2026-09-27 05:26 (UTC)

Dependency Graph:
--------------------------------------------------
Dependents (2 direct, 5 total):
├─ TASK-2 - Done dep with open dep [completed]
│  └─ TASK-4 - Transitive open dep only [To Do]
│     └─ TASK-6 - Depends on TASK-4 [Proposed]
└─ TASK-3 - Direct open dep [To Do]
   └─ TASK-5 - Depends on TASK-3 [Proposed]

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

VIEW
cat > "$FIXTURE_TREE153_SELECT/view-TASK-2.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-2 - Done-dep-with-open-dep.md

Task TASK-2 - Done dep with open dep
==================================================

Status: ✔ Done
Ordinal: 2000
Created: 2026-09-27 05:26 (UTC)
Updated: 2026-09-27 05:26 (UTC)

Dependency Graph:
--------------------------------------------------
Depends on (1 direct, 1 total):
└─ TASK-1 - Open dep [In Progress]

Dependents (1 direct, 2 total):
└─ TASK-4 - Transitive open dep only [To Do]
   └─ TASK-6 - Depends on TASK-4 [Proposed]

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

VIEW
# max_in_progress は In Progress の TASK-1 でゲートされないよう 2 にする。
select_out="$(cd "$STUB_ROOT_SELECT" && PATH="$STUB_ROOT_SELECT/bin:$PATH" SELECT_STUB_FIXTURE_DIR="$FIXTURE_TREE153_SELECT" "$SELECT_SCRIPT" 2 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-4'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: 1.53.0 形式の木から、未完了の直接依存（TASK-1）を持つ TASK-3 を除外し、推移的依存だけが未完了の TASK-4 を選ぶ"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: 1.53.0 形式の木を持つタスクの選定結果が期待と異なる（TASK-4 を期待、exit ${select_exit}）:
$select_out"
fi

# --- 4d. 1.53.0 形式の "unknown task ID"（存在しない依存）を持つタスクを選ばない ---
# backlog CLI 1.53.0 の出力。High の TASK-1 の依存に存在しない TASK-77 を frontmatter で書き足した。
# 実 CLI の TASK-77 の view は exit 1 なので、スタブにも view-TASK-77.txt を置かない
# （unknown を依存 ID として view すると RESULT: ERROR になって FAIL する）。
FIXTURE_UNKNOWN153_SELECT="$STUB_ROOT_SELECT/unknown153"
mkdir -p "$FIXTURE_UNKNOWN153_SELECT"
cat > "$FIXTURE_UNKNOWN153_SELECT/list.txt" <<'LIST'
To Do:
  [HIGH] TASK-1 - Missing dep
  [LOW] TASK-2 - No deps

LIST
cat > "$FIXTURE_UNKNOWN153_SELECT/blocked.txt" <<'LIST'
No tasks found.
LIST
cat > "$FIXTURE_UNKNOWN153_SELECT/view-TASK-1.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-1 - Missing-dep.md

Task TASK-1 - Missing dep
==================================================

Status: ○ To Do
Priority: High
Ordinal: 1000
Created: 2026-09-27 05:26 (UTC)

Dependency Graph:
--------------------------------------------------
Depends on (1 direct, 1 total):
└─ TASK-77 - unknown task ID

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

VIEW
cat > "$FIXTURE_UNKNOWN153_SELECT/view-TASK-2.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-2 - No-deps.md

Task TASK-2 - No deps
==================================================

Status: ○ To Do
Priority: Low
Ordinal: 2000
Created: 2026-09-27 05:26 (UTC)

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

VIEW
select_out="$(cd "$STUB_ROOT_SELECT" && PATH="$STUB_ROOT_SELECT/bin:$PATH" SELECT_STUB_FIXTURE_DIR="$FIXTURE_UNKNOWN153_SELECT" "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-2'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: 1.53.0 形式の unknown task ID（TASK-77）を依存に持つ TASK-1 を選ばず、TASK-2 を選ぶ"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: 1.53.0 形式の unknown task ID を持つタスクの選定結果が期待と異なる（TASK-2 を期待、exit ${select_exit}）:
$select_out"
fi

# --- 4e. 1.53.0 形式の "ambiguous task ID"（ID が一意に決まらない依存）を持つタスクを選ばない ---
# backlog CLI 1.53.0 の出力。Done の TASK-1 のファイルを別名で複製し、High の TASK-2 をそれに依存させた。
# 実 CLI の TASK-1 の view は exit 1 なので、スタブにも view-TASK-1.txt を置かない。
# なお実 1.53.0 は重複 ID があると task list --plain 自体を exit 1 で終える（stdout は下のとおり）。
# そのため実環境では select-next-task は最初の task list で RESULT: ERROR になる。スタブは exit 0 で
# 返すので、ここでは list と view の間に重複が生じた場合に備えた木の ambiguous の扱いを検証する。
FIXTURE_AMBIGUOUS153_SELECT="$STUB_ROOT_SELECT/ambiguous153"
mkdir -p "$FIXTURE_AMBIGUOUS153_SELECT"
cat > "$FIXTURE_AMBIGUOUS153_SELECT/list.txt" <<'LIST'
To Do:
  [HIGH] TASK-2 - Ambiguous dep
  [LOW] TASK-3 - No deps

Done:
  TASK-1 - Ambiguous dep target copy
  TASK-1 - Ambiguous dep target

LIST
cat > "$FIXTURE_AMBIGUOUS153_SELECT/blocked.txt" <<'LIST'
No tasks found.
LIST
cat > "$FIXTURE_AMBIGUOUS153_SELECT/view-TASK-2.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-2 - Ambiguous-dep.md

Task TASK-2 - Ambiguous dep
==================================================

Status: ○ To Do
Priority: High
Ordinal: 2000
Created: 2026-09-27 05:26 (UTC)

Dependency Graph:
--------------------------------------------------
Depends on (1 direct, 1 total):
└─ TASK-1 - ambiguous task ID

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

VIEW
cat > "$FIXTURE_AMBIGUOUS153_SELECT/view-TASK-3.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-3 - No-deps.md

Task TASK-3 - No deps
==================================================

Status: ○ To Do
Priority: Low
Ordinal: 3000
Created: 2026-09-27 05:26 (UTC)

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

VIEW
select_out="$(cd "$STUB_ROOT_SELECT" && PATH="$STUB_ROOT_SELECT/bin:$PATH" SELECT_STUB_FIXTURE_DIR="$FIXTURE_AMBIGUOUS153_SELECT" "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-3'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: 1.53.0 形式の ambiguous task ID（TASK-1）を依存に持つ TASK-2 を選ばず、TASK-3 を選ぶ"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: 1.53.0 形式の ambiguous task ID を持つタスクの選定結果が期待と異なる（TASK-3 を期待、exit ${select_exit}）:
$select_out"
fi

# --- 4f. 1.48.0 形式の存在しない依存（Status 行の無い view）を持つタスクを選ばない ---
# backlog CLI 1.48.0 の出力。High の TASK-1 の依存に存在しない TASK-77 を frontmatter で書き足した。
# 実 1.48.0 の TASK-77 の view は stdout が空（"Task TASK-77 not found." は stderr）で exit 0 なので、
# view-TASK-77.txt は空にする。Status 行が無い依存を Done 扱いにすると TASK-1 が選ばれて FAIL する。
FIXTURE_MISSING148_SELECT="$STUB_ROOT_SELECT/missing148"
mkdir -p "$FIXTURE_MISSING148_SELECT"
cat > "$FIXTURE_MISSING148_SELECT/list.txt" <<'LIST'
To Do:
  [HIGH] TASK-1 - Missing dep
  [LOW] TASK-2 - No deps

LIST
cat > "$FIXTURE_MISSING148_SELECT/blocked.txt" <<'LIST'
No tasks found.
LIST
cat > "$FIXTURE_MISSING148_SELECT/view-TASK-1.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-1 - Missing-dep.md

Task TASK-1 - Missing dep
==================================================

Status: ○ To Do
Priority: High
Ordinal: 1000
Created: 2026-09-27 05:26 (UTC)
Dependencies: TASK-77

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

VIEW
cat > "$FIXTURE_MISSING148_SELECT/view-TASK-2.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-2 - No-deps.md

Task TASK-2 - No deps
==================================================

Status: ○ To Do
Priority: Low
Ordinal: 2000
Created: 2026-09-27 05:26 (UTC)

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

VIEW
: > "$FIXTURE_MISSING148_SELECT/view-TASK-77.txt"
select_out="$(cd "$STUB_ROOT_SELECT" && PATH="$STUB_ROOT_SELECT/bin:$PATH" SELECT_STUB_FIXTURE_DIR="$FIXTURE_MISSING148_SELECT" "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-2'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: 1.48.0 形式の存在しない依存（TASK-77、Status 行の無い view）を持つ TASK-1 を選ばず、TASK-2 を選ぶ"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: 1.48.0 形式の存在しない依存を持つタスクの選定結果が期待と異なる（TASK-2 を期待、exit ${select_exit}）:
$select_out"
fi

echo ""
echo "=== 5. 空き枠（max_in_progress − In Progress）の数まで選ぶ（TASK-141） ==="
# 1 回の起動で空き枠を埋める件数を引き渡すため、select-next-task は SELECTED のとき
# TASK_ID 行を空き枠の数まで優先順に出す。TASK_ID 行の集合と順序を完全一致で確かめる
# （存在だけを見ると、除外漏れや上限超過で余分な行が出ても PASS してしまう）。

# assert_selected_ids <ラベル> <期待する終了コード> [期待する ID...]: RUN_OUT の TASK_ID 行が、
# 期待する ID を順に並べたものと完全に一致すれば PASS。ID を渡さなければ TASK_ID 行が無いことを見る。
assert_selected_ids() {
  local label="$1" code="$2"
  shift 2
  local actual expected="" id
  actual="$(grep '^TASK_ID: ' <<< "$RUN_OUT" || true)"
  for id in "$@"; do
    expected="${expected:+$expected
}TASK_ID: $id"
  done
  if [ "$RUN_EXIT" -eq "$code" ] && [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label
$ASSERT_DETAIL"
  fi
}

# $1 = フィクスチャのディレクトリ。スタブで select-next-task を実行し RUN_OUT / RUN_EXIT を設定する。
# 残りの引数は select-next-task にそのまま渡す。
run_select_stub() {
  local fixture="$1"
  shift
  run_in "$STUB_ROOT_SELECT" env PATH="$STUB_ROOT_SELECT/bin:$PATH" SELECT_STUB_FIXTURE_DIR="$fixture" "$SELECT_SCRIPT" "$@"
}

# --- 5a. AC#1: 候補が空き枠以上あれば、空き枠ちょうどの件数を優先度→数値ID順に選ぶ ---
# max_in_progress 4・In Progress 1 件で空き枠は 3。候補は 6 件。High の TASK-9・TASK-10、
# Medium で ID 最小の TASK-3 の 3 件だけが選ばれる。打ち切りが壊れると 4 件以上、
# ID を文字列で比べると TASK-10 が TASK-9 より先に出て FAIL する。
FIXTURE_SLOTS_SELECT="$STUB_ROOT_SELECT/slots"
mkdir -p "$FIXTURE_SLOTS_SELECT"
cat > "$FIXTURE_SLOTS_SELECT/list.txt" <<'LIST'
To Do:
  [LOW] TASK-1 - Low
  TASK-2 - No priority
  [MEDIUM] TASK-5 - Medium five
  [HIGH] TASK-10 - High ten
  [MEDIUM] TASK-3 - Medium three
  [HIGH] TASK-9 - High nine

In Progress:
  TASK-20 - Running

LIST
: > "$FIXTURE_SLOTS_SELECT/blocked.txt"
write_stub_view_without_deps "$FIXTURE_SLOTS_SELECT" TASK-1 TASK-2 TASK-5 TASK-10 TASK-3 TASK-9
run_select_stub "$FIXTURE_SLOTS_SELECT" 4 3
assert_selected_ids "select-next-task: AC#1: 空き枠 3（max_in_progress 4・In Progress 1）に対し候補 6 件から TASK-9・TASK-10・TASK-3 の 3 件を順に選ぶ" 0 TASK-9 TASK-10 TASK-3
assert "select-next-task: 複数件を選んでも 1 行目は RESULT: SELECTED" first_line_is 'RESULT: SELECTED'
# 空き枠が 1 なら、候補が複数あっても TASK_ID は 1 行だけ（max_in_progress 1 の従来の挙動と同じ）。
# 一覧に In Progress が 1 件（TASK-20）あるので、max_in_progress 2 で空き枠 1 にする。
run_select_stub "$FIXTURE_SLOTS_SELECT" 2 3
assert_selected_ids "select-next-task: 空き枠 1 なら候補 6 件でも TASK_ID は最良の TASK-9 の 1 行だけ" 0 TASK-9

# --- 5b. AC#2・AC#3: 候補が空き枠より少なければ候補だけを選ぶ。blocked と依存未完了は除外したまま ---
# max_in_progress 5・In Progress 1 件で空き枠は 4。High の TASK-1 は blocked:needs-decision、
# High の TASK-2 は In Progress の TASK-20 に依存する（1.48.0 形式）。残る TASK-3・TASK-4 の 2 件だけを選ぶ。
FIXTURE_FEW_SELECT="$STUB_ROOT_SELECT/few"
mkdir -p "$FIXTURE_FEW_SELECT"
cat > "$FIXTURE_FEW_SELECT/list.txt" <<'LIST'
To Do:
  [HIGH] TASK-1 - Blocked
  [HIGH] TASK-2 - Open dep
  [MEDIUM] TASK-3 - Medium
  [LOW] TASK-4 - Low

In Progress:
  TASK-20 - Running

LIST
cat > "$FIXTURE_FEW_SELECT/blocked.txt" <<'LIST'
To Do:
  [HIGH] TASK-1 - Blocked
LIST
write_stub_view_without_deps "$FIXTURE_FEW_SELECT" TASK-1 TASK-3 TASK-4
printf 'Task TASK-2 - Open dep\n==================================================\n\nStatus: ○ To Do\nDependencies: TASK-20\n\nDescription:\n--------------------------------------------------\nstub\n' \
  > "$FIXTURE_FEW_SELECT/view-TASK-2.txt"
printf 'Task TASK-20 - Running\n==================================================\n\nStatus: ◒ In Progress\n\nDescription:\n--------------------------------------------------\nstub\n' \
  > "$FIXTURE_FEW_SELECT/view-TASK-20.txt"
run_select_stub "$FIXTURE_FEW_SELECT" 5 3
assert_selected_ids "select-next-task: AC#2・AC#3: 空き枠 4 に対し、blocked（TASK-1）と依存未完了（TASK-2）を除いた TASK-3・TASK-4 の 2 件だけを選ぶ" 0 TASK-3 TASK-4

# --- 5c. AC#3: 空き枠があっても max_in_review に達していれば 1 件も選ばない ---
FIXTURE_REVIEW_GATE_SELECT="$STUB_ROOT_SELECT/review-gate"
mkdir -p "$FIXTURE_REVIEW_GATE_SELECT"
cat > "$FIXTURE_REVIEW_GATE_SELECT/list.txt" <<'LIST'
To Do:
  [HIGH] TASK-1 - Ready
  [HIGH] TASK-2 - Ready too

In Review:
  TASK-10 - Review one
  TASK-11 - Review two

LIST
: > "$FIXTURE_REVIEW_GATE_SELECT/blocked.txt"
write_stub_view_without_deps "$FIXTURE_REVIEW_GATE_SELECT" TASK-1 TASK-2
run_select_stub "$FIXTURE_REVIEW_GATE_SELECT" 5 2
assert_selected_ids "select-next-task: AC#3: 空き枠 5 でも In Review が max_in_review（2）に達していれば GATED で TASK_ID を出さない" 1
assert "select-next-task: AC#3: そのときの REASON は max_in_review" run_result 1 'RESULT: GATED' 'REASON: max_in_review'

# --- 5d. AC#5: To Do の A と、A に依存する B を同じ呼び出しで選ばない（実 CLI） ---
# TASK-1 は Done。A（TASK-2、Medium）は TASK-1 に依存し、B（TASK-3、High）は A に依存する。
# C（TASK-4、Low）は依存無し。空き枠 3 でも、A はまだ Done ではないので B は選ばれず A・C の 2 件になる。
# A を Done にした後の呼び出しで初めて B が選ばれる。
make_select_repo TMP_REPO_CHAIN_SELECT task
bl "$TMP_REPO_CHAIN_SELECT" task create "Done base" -s "Done"
bl "$TMP_REPO_CHAIN_SELECT" task create "A" --priority medium --dep task-1
bl "$TMP_REPO_CHAIN_SELECT" task create "B depends on A" --priority high --dep task-2
bl "$TMP_REPO_CHAIN_SELECT" task create "C" --priority low
run_in "$TMP_REPO_CHAIN_SELECT" "$SELECT_SCRIPT" 3 3
assert_selected_ids "select-next-task: AC#5: 空き枠 3 でも、A（TASK-2）に依存する B（TASK-3）は選ばず A・C（TASK-4）を選ぶ" 0 TASK-2 TASK-4
bl "$TMP_REPO_CHAIN_SELECT" task edit TASK-2 -s "Done"
run_in "$TMP_REPO_CHAIN_SELECT" "$SELECT_SCRIPT" 3 3
assert_selected_ids "select-next-task: AC#5: A が Done になった後の呼び出しで B（TASK-3）が選ばれる" 0 TASK-3 TASK-4

echo ""
echo "=== 6. modified_files が重なるタスクを同時に In Progress にしない（TASK-144） ==="
# 同じファイルを変える作業ブランチを同時に進めると、後からマージする方が衝突しやすい。
# select-next-task は In Progress のタスク・同じ呼び出しで先に選んだ候補と modified_files が重なる
# 候補を後回しにし、DEFERRED 行で相手と重なったファイルを出す。
# Modified files 行の位置は CLI のバージョンで違う（1.48.0 はメタデータ部、1.53.0 は本文の節の後）。
# 両形式をスタブで毎回確かめる（形式は tests/test_notes_records.sh の実出力のフィクスチャと同じ）。

# write_stub_view_modified <dir> <ID> <148|153> [modified file...]: 依存の無い view を書く。
# ファイルを渡さなければ Modified files 行を出さない。
write_stub_view_modified() {
  local dir="$1" id="$2" format="$3"
  shift 3
  local files="" f
  for f in "$@"; do
    files="${files:+$files, }$f"
  done
  {
    printf 'Task %s - stub\n==================================================\n\nStatus: ○ To Do\n' "$id"
    if [ "$format" = 148 ] && [ -n "$files" ]; then
      printf 'Modified files: %s\n' "$files"
    fi
    printf '\nDescription:\n--------------------------------------------------\nstub\n\n'
    printf 'Acceptance Criteria:\n--------------------------------------------------\nNo acceptance criteria defined\n\n'
    printf 'Definition of Done:\n--------------------------------------------------\nNo Definition of Done items defined\n\n'
    if [ "$format" = 153 ] && [ -n "$files" ]; then
      printf 'Modified files: %s\n\n' "$files"
    fi
  } > "$dir/view-$id.txt"
}

# assert_deferred_lines <ラベル> [期待する DEFERRED 行...]: RUN_OUT の DEFERRED 行が、期待する行を
# 順に並べたものと完全に一致すれば PASS。行を渡さなければ DEFERRED 行が無いことを見る。
assert_deferred_lines() {
  local label="$1"
  shift
  local actual expected="" l
  actual="$(grep '^DEFERRED: ' <<< "$RUN_OUT" || true)"
  for l in "$@"; do
    expected="${expected:+$expected
}$l"
  done
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label
$ASSERT_DETAIL"
  fi
}

# --- 6a. AC#1・AC#4: To Do 同士で重なる候補は優先度の高い 1 件だけを選び、残りを後回しにして報告する ---
# 空き枠 5、In Progress 無し。TASK-1（High、a.md・b.md）を選ぶ。TASK-2（High、b.md）と TASK-5（Low、a.md）は
# TASK-1 と重なるので後回し。TASK-3（Medium、c.md）と modified_files の無い TASK-4 は選ぶ。
# 1.48.0 形式と 1.53.0 形式を混ぜ、どちらの形式の読み取りが壊れても FAIL するようにする。
FIXTURE_OVERLAP_TODO_SELECT="$STUB_ROOT_SELECT/overlap-todo"
mkdir -p "$FIXTURE_OVERLAP_TODO_SELECT"
cat > "$FIXTURE_OVERLAP_TODO_SELECT/list.txt" <<'LIST'
To Do:
  [LOW] TASK-5 - Low a
  [HIGH] TASK-2 - High b
  [MEDIUM] TASK-3 - Medium c
  [LOW] TASK-4 - Low none
  [HIGH] TASK-1 - High ab

LIST
: > "$FIXTURE_OVERLAP_TODO_SELECT/blocked.txt"
write_stub_view_modified "$FIXTURE_OVERLAP_TODO_SELECT" TASK-1 153 a.md b.md
write_stub_view_modified "$FIXTURE_OVERLAP_TODO_SELECT" TASK-2 148 b.md
write_stub_view_modified "$FIXTURE_OVERLAP_TODO_SELECT" TASK-3 153 c.md
write_stub_view_modified "$FIXTURE_OVERLAP_TODO_SELECT" TASK-4 153
write_stub_view_modified "$FIXTURE_OVERLAP_TODO_SELECT" TASK-5 148 'dir/x y.md' a.md
run_select_stub "$FIXTURE_OVERLAP_TODO_SELECT" 5 3
assert_selected_ids "select-next-task: AC#1: To Do 同士で modified_files が重なる候補（TASK-1 と TASK-2・TASK-5）からは TASK-1 だけを選び、重ならない TASK-3・TASK-4 も選ぶ" 0 TASK-1 TASK-3 TASK-4
assert_deferred_lines "select-next-task: AC#4: 後回しにした TASK-2・TASK-5 について、相手（TASK-1）と重なったファイルを DEFERRED 行で出す" \
  'DEFERRED: TASK-2 CONFLICTS_WITH: TASK-1 FILES: b.md' \
  'DEFERRED: TASK-5 CONFLICTS_WITH: TASK-1 FILES: a.md'
assert "select-next-task: DEFERRED 行があっても 1 行目は RESULT: SELECTED" first_line_is 'RESULT: SELECTED'

# --- 6b. AC#2・AC#4: In Progress のタスクと重なる候補は空き枠があっても選ばない ---
# In Progress の TASK-20 は a.md を変える。空き枠 4。TASK-1（High、b.md）を選ぶ。TASK-2（Medium、a.md・b.md）は
# TASK-20 とも、先に選んだ TASK-1 とも重なるので、相手ごとに DEFERRED 行を出す。TASK-3（Low、c.md）は選ぶ。
FIXTURE_OVERLAP_IP_SELECT="$STUB_ROOT_SELECT/overlap-in-progress"
mkdir -p "$FIXTURE_OVERLAP_IP_SELECT"
cat > "$FIXTURE_OVERLAP_IP_SELECT/list.txt" <<'LIST'
To Do:
  [HIGH] TASK-1 - High b
  [MEDIUM] TASK-2 - Medium ab
  [LOW] TASK-3 - Low c

In Progress:
  TASK-20 - Running a

LIST
: > "$FIXTURE_OVERLAP_IP_SELECT/blocked.txt"
write_stub_view_modified "$FIXTURE_OVERLAP_IP_SELECT" TASK-1 148 b.md
write_stub_view_modified "$FIXTURE_OVERLAP_IP_SELECT" TASK-2 153 a.md b.md
write_stub_view_modified "$FIXTURE_OVERLAP_IP_SELECT" TASK-3 153 c.md
write_stub_view_modified "$FIXTURE_OVERLAP_IP_SELECT" TASK-20 153 a.md
run_select_stub "$FIXTURE_OVERLAP_IP_SELECT" 5 3
assert_selected_ids "select-next-task: AC#2: In Progress の TASK-20 と重なる TASK-2 は空き枠 4 があっても選ばず、TASK-1・TASK-3 を選ぶ" 0 TASK-1 TASK-3
assert_deferred_lines "select-next-task: AC#4: TASK-2 は In Progress の TASK-20（a.md）と、先に選んだ TASK-1（b.md）の相手ごとに DEFERRED 行を出す" \
  'DEFERRED: TASK-2 CONFLICTS_WITH: TASK-20 FILES: a.md' \
  'DEFERRED: TASK-2 CONFLICTS_WITH: TASK-1 FILES: b.md'

# 候補がすべて In Progress と重なるなら NO_CANDIDATE で、DEFERRED 行に理由を出す。
FIXTURE_OVERLAP_ALL_SELECT="$STUB_ROOT_SELECT/overlap-all"
mkdir -p "$FIXTURE_OVERLAP_ALL_SELECT"
cat > "$FIXTURE_OVERLAP_ALL_SELECT/list.txt" <<'LIST'
To Do:
  [HIGH] TASK-1 - High a

In Progress:
  TASK-20 - Running a

LIST
: > "$FIXTURE_OVERLAP_ALL_SELECT/blocked.txt"
write_stub_view_modified "$FIXTURE_OVERLAP_ALL_SELECT" TASK-1 153 a.md
write_stub_view_modified "$FIXTURE_OVERLAP_ALL_SELECT" TASK-20 148 a.md
run_select_stub "$FIXTURE_OVERLAP_ALL_SELECT" 3 3
assert "select-next-task: AC#2: 候補がすべて In Progress と重なれば RESULT: NO_CANDIDATE（exit 2）" run_result 2 'RESULT: NO_CANDIDATE'
assert "select-next-task: NO_CANDIDATE でも 1 行目は RESULT 行" first_line_is 'RESULT: NO_CANDIDATE'
assert_selected_ids "select-next-task: 候補がすべて後回しなら TASK_ID 行を出さない" 2
assert_deferred_lines "select-next-task: AC#4: NO_CANDIDATE のときも後回しの理由（TASK-1 と TASK-20 の a.md）を DEFERRED 行で出す" \
  'DEFERRED: TASK-1 CONFLICTS_WITH: TASK-20 FILES: a.md'

# --- 6c. AC#3: 重ならなければ従来どおり空き枠の数だけ選び、max_in_progress 1 の挙動は変わらない ---
FIXTURE_NO_OVERLAP_SELECT="$STUB_ROOT_SELECT/no-overlap"
mkdir -p "$FIXTURE_NO_OVERLAP_SELECT"
cat > "$FIXTURE_NO_OVERLAP_SELECT/list.txt" <<'LIST'
To Do:
  [HIGH] TASK-1 - a
  [HIGH] TASK-2 - a too
  [MEDIUM] TASK-3 - b
  [LOW] TASK-4 - c
  [LOW] TASK-5 - d

LIST
: > "$FIXTURE_NO_OVERLAP_SELECT/blocked.txt"
write_stub_view_modified "$FIXTURE_NO_OVERLAP_SELECT" TASK-1 153 a.md
write_stub_view_modified "$FIXTURE_NO_OVERLAP_SELECT" TASK-2 153 a.md
write_stub_view_modified "$FIXTURE_NO_OVERLAP_SELECT" TASK-3 148 b.md
write_stub_view_modified "$FIXTURE_NO_OVERLAP_SELECT" TASK-4 153 c.md
write_stub_view_modified "$FIXTURE_NO_OVERLAP_SELECT" TASK-5 153 d.md
# 空き枠 3。TASK-2 は TASK-1 と重なるので飛ばし、重ならない TASK-3・TASK-4 で枠を埋める。
# 枠が埋まった後の TASK-5 は選ばれない（DEFERRED は TASK-2 だけ）。
run_select_stub "$FIXTURE_NO_OVERLAP_SELECT" 3 3
assert_selected_ids "select-next-task: AC#3: 重なる TASK-2 を飛ばしても、重ならない候補で空き枠 3 をちょうど埋める" 0 TASK-1 TASK-3 TASK-4
assert_deferred_lines "select-next-task: AC#3: 枠が埋まった後の候補は DEFERRED に載せない" \
  'DEFERRED: TASK-2 CONFLICTS_WITH: TASK-1 FILES: a.md'
# max_in_progress 1（In Progress 0 件）では、重なる候補があっても従来どおり最良の 1 件だけを選び、DEFERRED 行は出ない。
run_select_stub "$FIXTURE_NO_OVERLAP_SELECT" 1 3
assert_selected_ids "select-next-task: AC#3: max_in_progress 1 では従来どおり最良の TASK-1 だけを選ぶ" 0 TASK-1
assert_deferred_lines "select-next-task: AC#3: max_in_progress 1 では DEFERRED 行を出さない"

# --- 6d. 自由記述の中の Modified files 行を modified_files として読まない ---
# TASK-2 の実際の modified_files は z.md だけで、説明文（Comments 節の見出しと同じ見た目の組を続けて）と notes に「Modified files: a.md」を書いている。
# 1.53.0 形式で Modified files 行の後に Comments 節が続く並びも確かめる。説明文や notes の行を拾うと
# TASK-1（a.md）と重なって TASK-2 が後回しになり FAIL する。
# TASK-3 は modified_files を持たず、Final Summary の末尾（直前が空行でない行）に「Modified files: a.md」を書いている。
# 実 CLI 1.53.0 はこの並びをそのまま出力の末尾に出す。これを拾うと TASK-3 が後回しになり FAIL する。
FIXTURE_FAKE_LINE_SELECT="$STUB_ROOT_SELECT/fake-line"
mkdir -p "$FIXTURE_FAKE_LINE_SELECT"
cat > "$FIXTURE_FAKE_LINE_SELECT/list.txt" <<'LIST'
To Do:
  [HIGH] TASK-1 - Real a
  [MEDIUM] TASK-2 - Mentions a
  [LOW] TASK-3 - Summary mentions a

LIST
: > "$FIXTURE_FAKE_LINE_SELECT/blocked.txt"
cat > "$FIXTURE_FAKE_LINE_SELECT/view-TASK-3.txt" <<'VIEW'
Task TASK-3 - Summary mentions a
==================================================

Status: ○ To Do

Description:
--------------------------------------------------
stub

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

Final Summary:
--------------------------------------------------
summary
Modified files: a.md

VIEW
write_stub_view_modified "$FIXTURE_FAKE_LINE_SELECT" TASK-1 148 a.md
cat > "$FIXTURE_FAKE_LINE_SELECT/view-TASK-2.txt" <<'VIEW'
Task TASK-2 - Mentions a
==================================================

Status: ○ To Do

Description:
--------------------------------------------------
quoted output:

Modified files: a.md

Comments:
--------------------------------------------------
quoted end

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

Implementation Notes:
--------------------------------------------------
note

Modified files: a.md
more note

Modified files: z.md

Comments:
--------------------------------------------------
#1 - 2026-10-24 14:02 (UTC)
cmt

VIEW
run_select_stub "$FIXTURE_FAKE_LINE_SELECT" 3 3
assert_selected_ids "select-next-task: 説明文・notes・Final Summary 中の Modified files 行を読まず、実際の modified_files（z.md）で判定して TASK-1・TASK-2・TASK-3 を選ぶ" 0 TASK-1 TASK-2 TASK-3
assert_deferred_lines "select-next-task: 説明文・notes・Final Summary 中の Modified files 行で DEFERRED を出さない"

# --- 6e. 実 CLI の出力でも modified_files を読み、In Progress と重なる候補を後回しにする ---
# 実行環境の CLI のバージョンの実出力で 6a〜6d と同じ読み取りが成り立つことを確かめる。
make_select_repo TMP_REPO_OVERLAP_SELECT task
bl "$TMP_REPO_OVERLAP_SELECT" task create "Running" -s "In Progress" --modified-file 'skills/x/SKILL.md' --modified-file 'refs/a b.md'
bl "$TMP_REPO_OVERLAP_SELECT" task create "Overlaps running" --priority high --modified-file 'refs/a b.md'
bl "$TMP_REPO_OVERLAP_SELECT" task create "Separate" --priority low --modified-file 'other.sh'
bl "$TMP_REPO_OVERLAP_SELECT" task edit TASK-1 --append-notes 'note'
run_in "$TMP_REPO_OVERLAP_SELECT" "$SELECT_SCRIPT" 3 3
assert_selected_ids "select-next-task: 実 CLI: In Progress の TASK-1 と重なる TASK-2 を選ばず TASK-3 を選ぶ" 0 TASK-3
assert_deferred_lines "select-next-task: 実 CLI: TASK-2 と TASK-1 が refs/a b.md で重なることを DEFERRED 行で出す" \
  'DEFERRED: TASK-2 CONFLICTS_WITH: TASK-1 FILES: refs/a b.md'
bl "$TMP_REPO_OVERLAP_SELECT" task edit TASK-1 -s "In Review"
run_in "$TMP_REPO_OVERLAP_SELECT" "$SELECT_SCRIPT" 3 3
assert_selected_ids "select-next-task: 実 CLI: 相手（TASK-1）が In Progress を抜けた後の呼び出しで TASK-2 が通常どおり選ばれる" 0 TASK-2 TASK-3

finish_tests
