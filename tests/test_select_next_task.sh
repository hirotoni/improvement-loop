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
# 判定できることを確かめる。1.48.0 の "Dependencies:" 行の形式でも同じ結果になる
# （PATH に 1.48.0 の backlog を置いてこのファイルを実行すると確かめられる）。

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

finish_tests
