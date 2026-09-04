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

finish_tests
