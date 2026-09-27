#!/usr/bin/env bash
# claude-code/skills/improvement-dispatch/scripts/select-next-task に対するテスト。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 7. claude-code/skills/improvement-dispatch/scripts/select-next-task の選定ロジック検証 ==="
# improvement ループの6ステータスが揃った一時 backlog リポジトリに対して
# select-next-task を実行し、選定ロジック（除外集合の計算・依存確認・優先度ソート・
# 閾値判定）の各パターンを検証する。

TMP_REPO_SELECT="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_SELECT"

# 一時リポジトリの準備に bin/setup-improvement-loop は使わない。select-next-task が要るのは
# 6ステータスが揃った .backlog/config.yml だけで（閾値は引数で受け取るため config.my.yml は
# 読まない）、setup を通すと backlog CLI が5回起動して約900ms かかるためである。
(cd "$TMP_REPO_SELECT" && git init -q)
mkdir -p "$TMP_REPO_SELECT/.backlog"
cat > "$TMP_REPO_SELECT/.backlog/config.yml" <<'YAML'
project_name: "select-next-task-test"
default_assignee: ["@improvement-loop-bot"]
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
task_prefix: "task"
YAML

# --- 7a. NO_CANDIDATE: To Do タスクが1件も無い ---
select_out="$(cd "$TMP_REPO_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 2 ] && printf '%s\n' "$select_out" | grep -Fxq 'RESULT: NO_CANDIDATE'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: To Do が無いとき RESULT: NO_CANDIDATE（exit 2）"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: To Do が無いときの結果が期待と異なる（exit ${select_exit}）:
$select_out"
fi

(cd "$TMP_REPO_SELECT" && backlog task create "Low task" --priority low --plain >/dev/null)
(cd "$TMP_REPO_SELECT" && backlog task create "High task" --priority high --plain >/dev/null)
(cd "$TMP_REPO_SELECT" && backlog task create "Medium task A" --priority medium --plain >/dev/null)
(cd "$TMP_REPO_SELECT" && backlog task create "Medium task B" --priority medium --plain >/dev/null)

# --- 7b. 通常選定: 優先度最高（High、TASK-2）が選ばれる ---
select_out="$(cd "$TMP_REPO_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-2'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: 優先度最高（High, TASK-2）が選定される"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: 通常選定の結果が期待と異なる（TASK-2 を期待、exit ${select_exit}）:
$select_out"
fi

# --- 7c. blocked:needs-decision ラベル除外 + 同優先度タイブレークがID最小になる ---
(cd "$TMP_REPO_SELECT" && backlog task edit TASK-2 --label 'blocked:needs-decision' --plain >/dev/null)
select_out="$(cd "$TMP_REPO_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-3'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: blocked:needs-decision 付き（TASK-2）を除外し、同優先度でID最小（TASK-3）を選ぶ"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: blocked ラベル除外後の結果が期待と異なる（TASK-3 を期待、exit ${select_exit}）:
$select_out"
fi

# --- 7d. 依存タスク未完了の除外、依存解消後の再選定 ---
(cd "$TMP_REPO_SELECT" && backlog task edit TASK-3 --dep task-1 --plain >/dev/null)
select_out="$(cd "$TMP_REPO_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-4'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: 未完了の依存（TASK-1）を持つ TASK-3 を除外し、TASK-4 を選ぶ"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: 依存未完了除外後の結果が期待と異なる（TASK-4 を期待、exit ${select_exit}）:
$select_out"
fi

# 依存タスクを Done にすると、除外されていた TASK-3 が再び選ばれる
# （同優先度内でID最小が優先されることの確認も兼ねる）。
(cd "$TMP_REPO_SELECT" && backlog task edit TASK-1 -s "Done" --plain >/dev/null)
select_out="$(cd "$TMP_REPO_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-3'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: 依存タスク（TASK-1）が Done になると TASK-3 が再び選ばれる"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: 依存解消後の結果が期待と異なる（TASK-3 を期待、exit ${select_exit}）:
$select_out"
fi

# --- 7e. max_in_progress GATED ---
(cd "$TMP_REPO_SELECT" && backlog task edit TASK-3 -s "In Progress" --plain >/dev/null)
select_out="$(cd "$TMP_REPO_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 1 ] && printf '%s\n' "$select_out" | grep -Fxq 'RESULT: GATED' \
    && printf '%s\n' "$select_out" | grep -Fxq 'REASON: max_in_progress'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: In Progress が max_in_progress 以上のとき RESULT: GATED / REASON: max_in_progress（exit 1）"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: max_in_progress ゲートの結果が期待と異なる（exit ${select_exit}）:
$select_out"
fi
(cd "$TMP_REPO_SELECT" && backlog task edit TASK-3 -s "To Do" --plain >/dev/null)

# --- 7f. max_in_review GATED ---
(cd "$TMP_REPO_SELECT" && backlog task edit TASK-3 -s "In Review" --plain >/dev/null)
(cd "$TMP_REPO_SELECT" && backlog task edit TASK-4 -s "In Review" --plain >/dev/null)
select_out="$(cd "$TMP_REPO_SELECT" && "$SELECT_SCRIPT" 1 2 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 1 ] && printf '%s\n' "$select_out" | grep -Fxq 'RESULT: GATED' \
    && printf '%s\n' "$select_out" | grep -Fxq 'REASON: max_in_review'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: In Review が max_in_review 以上のとき RESULT: GATED / REASON: max_in_review（exit 1）"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: max_in_review ゲートの結果が期待と異なる（exit ${select_exit}）:
$select_out"
fi

echo ""
echo "=== 8. task_prefix をカスタマイズしたリポジトリでの回帰テスト（TASK-54） ==="
# ID は .backlog/config.yml の task_prefix に応じて変わる（task_prefix: "issue" なら
# "ISSUE-<n>"）。ID 抽出・件数カウントを "TASK-" 固定パターンで行うと、prefix を
# カスタマイズしたリポジトリでは常に0件になり、To Do が実在しても NO_CANDIDATE を返し続け、
# 閾値によるゲーティングも機能しなくなる。その回帰テストである。

TMP_REPO_CUSTOM_PREFIX_SELECT="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_CUSTOM_PREFIX_SELECT"

(cd "$TMP_REPO_CUSTOM_PREFIX_SELECT" && git init -q)
mkdir -p "$TMP_REPO_CUSTOM_PREFIX_SELECT/.backlog"
cat > "$TMP_REPO_CUSTOM_PREFIX_SELECT/.backlog/config.yml" <<'YAML'
project_name: "custom-prefix-select-test"
default_status: "To Do"
statuses: ["Proposed", "To Do", "In Progress", "In Review", "Approved", "Done"]
labels: []
date_format: yyyy-mm-dd
max_column_width: 20
auto_open_browser: true
default_port: 6420
remote_operations: true
auto_commit: false
filesystem_only: false
bypass_git_hooks: false
check_active_branches: true
active_branch_days: 30
task_prefix: "issue"
YAML

# --- 8a. AC#1: To Do タスクが存在するとき RESULT: SELECTED / 正しい TASK_ID (ISSUE-1) ---
(cd "$TMP_REPO_CUSTOM_PREFIX_SELECT" && backlog task create "Custom prefix task" --priority high --plain >/dev/null)
select_out="$(cd "$TMP_REPO_CUSTOM_PREFIX_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'RESULT: SELECTED' \
    && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: ISSUE-1'; then
  pass "AC#1: task_prefix をカスタマイズしたリポジトリ（ISSUE-1）でも RESULT: SELECTED / TASK_ID: ISSUE-1 を返す"
else
  fail "AC#1: task_prefix カスタマイズ時の選定結果が期待と異なる（TASK_ID: ISSUE-1 を期待、exit ${select_exit}）:
$select_out"
fi

# --- 8b. AC#2: In Progress の件数が max_in_progress 以上のとき RESULT: GATED ---
(cd "$TMP_REPO_CUSTOM_PREFIX_SELECT" && backlog task edit ISSUE-1 -s "In Progress" --plain >/dev/null)
select_out="$(cd "$TMP_REPO_CUSTOM_PREFIX_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 1 ] && printf '%s\n' "$select_out" | grep -Fxq 'RESULT: GATED' \
    && printf '%s\n' "$select_out" | grep -Fxq 'REASON: max_in_progress' \
    && printf '%s\n' "$select_out" | grep -Fxq 'IN_PROGRESS_COUNT: 1'; then
  pass "AC#2: task_prefix をカスタマイズしたリポジトリでも In Progress の件数が正しく数えられ RESULT: GATED / REASON: max_in_progress を返す"
else
  fail "AC#2: task_prefix カスタマイズ時の max_in_progress ゲート結果が期待と異なる（exit ${select_exit}）:
$select_out"
fi

# --- 8c. AC#2: In Review の件数が max_in_review 以上のとき RESULT: GATED ---
(cd "$TMP_REPO_CUSTOM_PREFIX_SELECT" && backlog task edit ISSUE-1 -s "In Review" --plain >/dev/null)
select_out="$(cd "$TMP_REPO_CUSTOM_PREFIX_SELECT" && "$SELECT_SCRIPT" 1 1 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 1 ] && printf '%s\n' "$select_out" | grep -Fxq 'RESULT: GATED' \
    && printf '%s\n' "$select_out" | grep -Fxq 'REASON: max_in_review' \
    && printf '%s\n' "$select_out" | grep -Fxq 'IN_REVIEW_COUNT: 1'; then
  pass "AC#2: task_prefix をカスタマイズしたリポジトリでも In Review の件数が正しく数えられ RESULT: GATED / REASON: max_in_review を返す"
else
  fail "AC#2: task_prefix カスタマイズ時の max_in_review ゲート結果が期待と異なる（exit ${select_exit}）:
$select_out"
fi

echo ""
echo "=== 9. 複数依存・存在しない依存の扱い（TASK-99） ==="
# backlog CLI 1.53.0 の task view --plain は "Dependencies:" 行を出さず、
# "Dependency Graph:" の "Depends on" 木で依存を表す。依存の一部だけが Done の場合、
# 推移的依存を持つ場合、存在しない依存を持つ場合に、直接依存を正しく読み取って
# 判定できることを確かめる。1.48.0 の "Dependencies:" 行の形式でも同じ結果になる。
# 9 節は実 CLI の出力形式を確かめる経路として実 CLI のまま残す。両形式の依存解析と存在しない
# 依存の扱いは、実 CLI のバージョンによらず 10b〜10f がスタブで検証する。

TMP_REPO_DEPS_SELECT="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_DEPS_SELECT"

(cd "$TMP_REPO_DEPS_SELECT" && git init -q)
mkdir -p "$TMP_REPO_DEPS_SELECT/.backlog"
cat > "$TMP_REPO_DEPS_SELECT/.backlog/config.yml" <<'YAML'
project_name: "deps-select-test"
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
task_prefix: "task"
YAML

# 依存先として TASK-1（Done）、TASK-2（In Review。未完了）、TASK-3（Done）を用意する。
# 木の中で未完了の依存が "├─" 側・"└─" 側のどちらに来ても除外できることを確かめるため、
# TASK-4 は TASK-2（未完了）・TASK-3（Done）の順、TASK-5 は TASK-1（Done）・TASK-2（未完了）の順に依存させる。
# TASK-6 は Done の TASK-1・TASK-3 だけに依存させる。
(cd "$TMP_REPO_DEPS_SELECT" && backlog task create "Dep done A" --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task create "Dep open" --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task create "Dep done B" --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task create "Open dep first" --priority high --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task create "Open dep last" --priority high --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task create "All deps done" --priority medium --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task edit TASK-1 -s "Done" --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task edit TASK-2 -s "In Review" --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task edit TASK-3 -s "Done" --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task edit TASK-4 --dep task-2,task-3 --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task edit TASK-5 --dep task-1,task-2 --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task edit TASK-6 --dep task-1,task-3 --plain >/dev/null)

# --- 9a. 依存の一部だけが未完了のタスク（TASK-4・TASK-5）は並び順によらず除外され、全依存 Done の TASK-6 が選ばれる ---
select_out="$(cd "$TMP_REPO_DEPS_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-6'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: 未完了の依存（TASK-2）が先頭でも末尾でも TASK-4・TASK-5 を除外し、全依存 Done の TASK-6 を選ぶ"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: 一部未完了の依存を持つタスクの除外結果が期待と異なる（TASK-6 を期待、exit ${select_exit}）:
$select_out"
fi

# --- 9b. 判定は直接依存だけで行う。直接依存（TASK-7）が Done なら、その先の推移的依存（TASK-2）が未完了でも TASK-8 は選ばれる ---
# 従来の "Dependencies:" 行（1.48.0）も直接依存だけを列挙していたので、その挙動に揃える。
(cd "$TMP_REPO_DEPS_SELECT" && backlog task edit TASK-4 -s "Proposed" --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task edit TASK-5 -s "Proposed" --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task edit TASK-6 -s "Proposed" --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task create "Done with open dep" --dep task-2 --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task edit TASK-7 -s "Done" --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task create "Needs TASK-7" --priority low --dep task-7 --plain >/dev/null)
select_out="$(cd "$TMP_REPO_DEPS_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-8'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: 直接依存（TASK-7）が Done なら、推移的依存（TASK-2）が未完了でも TASK-8 を選ぶ"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: 推移的依存を持つタスクの結果が期待と異なる（TASK-8 を期待、exit ${select_exit}）:
$select_out"
fi

# --- 9c. 存在しない依存を持つタスクは ERROR にならず、未完了扱いで除外される ---
# backlog CLI は存在しない ID を --dep で受け付けないため、依存先タスクが後から
# 消えた状況をタスクファイルの frontmatter を直接書き換えて再現する（一時リポジトリ内のみ）。
(cd "$TMP_REPO_DEPS_SELECT" && backlog task edit TASK-8 -s "Proposed" --plain >/dev/null)
(cd "$TMP_REPO_DEPS_SELECT" && backlog task edit TASK-6 -s "To Do" --plain >/dev/null)
dep_task_file="$(ls "$TMP_REPO_DEPS_SELECT"/.backlog/tasks/task-6\ -*.md)"
# テストの依存を bash・git・backlog に限るため、perl や sed -i（GNU/BSD で書式が違う）は使わない。
awk '{ print } $0 == "  - TASK-3" { print "  - TASK-77" }' "$dep_task_file" > "$dep_task_file.tmp" \
  && mv "$dep_task_file.tmp" "$dep_task_file"
select_out="$(cd "$TMP_REPO_DEPS_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 2 ] && printf '%s\n' "$select_out" | grep -Fxq 'RESULT: NO_CANDIDATE'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: 存在しない依存（TASK-77）を持つ TASK-6 を未完了扱いで除外し NO_CANDIDATE を返す"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: 存在しない依存を持つタスクの結果が期待と異なる（NO_CANDIDATE を期待、exit ${select_exit}）:
$select_out"
fi

# --- 9d. 説明文に依存表記と同じ見た目の行があっても依存として読まない ---
# 自由記述の説明文（例: 不具合報告に CLI 出力を貼ったもの）の "Dependencies:" 行や
# "Depends on" 木を依存と誤読すると、存在しない ID の view が失敗して RESULT: ERROR になる。
(cd "$TMP_REPO_DEPS_SELECT" && backlog task create "Quotes CLI output" --priority high \
  -d $'Dependencies: see notes\nDependency Graph:\n--------------------------------------------------\nDepends on (1 direct, 1 total):\n└─ foo - fake' \
  --plain >/dev/null)
select_out="$(cd "$TMP_REPO_DEPS_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-9'; then
  pass "claude-code/skills/improvement-dispatch/scripts/select-next-task: 説明文中の依存表記に似た行を無視し、依存の無い TASK-9 を選ぶ"
else
  fail "claude-code/skills/improvement-dispatch/scripts/select-next-task: 説明文中の依存表記に似た行を依存として読んだ（TASK-9 を期待、exit ${select_exit}）:
$select_out"
fi

echo ""
echo "=== 10. backlog CLI の出力順・バージョンによらない選定ロジックの検証（TASK-103） ==="
# 実 CLI（1.53.0）の task list は最初から優先度→ID順で返し、task view の依存の形式は
# CLI のバージョンで違う。そのため 7〜9 節だけでは、select-next-task 自身の
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

# --- 10a. CLI が優先度・ID の順になっていない一覧を返しても、High の中で数値ID最小（TASK-4）を選ぶ ---
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

# --- 10b. 1.48.0 形式の "Dependencies:" 行を読み、未完了の依存を持つタスクを除外する ---
# High の TASK-4 は "Dependencies: TASK-3, TASK-7" を持ち、TASK-3 は Done、TASK-7 は In Progress。
# 未完了の依存を末尾に置き、カンマ区切りの全要素を見ていることも確かめる。
# 1.48.0 形式の解析を無効化すると TASK-4 が選ばれて FAIL する。
# 10b〜10f のフィクスチャは、各節に書いたバージョンの実 CLI の stdout を写したものである
# （取得日 2026-09-27。File: 行の一時リポジトリのパスだけ "<一時リポジトリ>" に置き換えた）。
# 10b は backlog CLI 1.48.0 の出力。TASK-1・TASK-2・TASK-5 を作ってから archive し、ID を揃えた。
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

# --- 10c. 1.53.0 形式の "Dependency Graph:" の木から直接依存だけを読む ---
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

# --- 10d. 1.53.0 形式の "unknown task ID"（存在しない依存）を持つタスクを選ばない ---
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

# --- 10e. 1.53.0 形式の "ambiguous task ID"（ID が一意に決まらない依存）を持つタスクを選ばない ---
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

# --- 10f. 1.48.0 形式の存在しない依存（Status 行の無い view）を持つタスクを選ばない ---
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

finish_tests
