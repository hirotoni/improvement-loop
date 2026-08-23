#!/usr/bin/env bash
# tests/test_select_next_task.sh
#
# claude-skills/improvement-dispatch/scripts/select-next-task に対するテスト。
# 単体で実行すると、このファイルの検証だけが走る。tests/run.sh から
# 全体実行の一部としても呼ばれる。
#
# 依存は bash/zsh・git・backlog のみ。いずれか欠けていれば、その旨を
# 報告してスキップする（テスト対象の不具合として失敗にはしない）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 7. claude-skills/improvement-dispatch/scripts/select-next-task の選定ロジック検証 ==="
# improvement-dispatch 手順4の選定ロジック（除外集合の計算・依存確認・
# 優先度ソート・max_in_progress/max_in_review の閾値判定）を切り出した
# claude-skills/improvement-dispatch/scripts/select-next-task を、improvement ループの6ステータスが揃った一時
# backlog リポジトリに対して実行し、次の6パターンを検証する。
#   7a. NO_CANDIDATE（To Do タスクが1件も無い）
#   7b. 通常選定（優先度最高のものが選ばれる）
#   7c. blocked:needs-decision ラベル除外 + 同優先度タイブレーク（ID最小）
#   7d. 未完了の依存タスクを持つものの除外、依存解消後の再選定
#   7e. max_in_progress 以上のときの GATED
#   7f. max_in_review 以上のときの GATED

TMP_REPO_SELECT="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_SELECT"

(cd "$TMP_REPO_SELECT" && git init -q)
select_setup_output="$("$SETUP_SCRIPT" "$TMP_REPO_SELECT" 2>&1)"
select_setup_exit=$?
if [ "$select_setup_exit" -ne 0 ]; then
  fail "claude-skills/improvement-dispatch/scripts/select-next-task 検証用の一時リポジトリの準備（setup-improvement-loop）が失敗した（exit ${select_setup_exit}）:
$select_setup_output"
fi

# --- 7a. NO_CANDIDATE: To Do タスクが1件も無い ---
select_out="$(cd "$TMP_REPO_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 2 ] && printf '%s\n' "$select_out" | grep -Fxq 'RESULT: NO_CANDIDATE'; then
  pass "claude-skills/improvement-dispatch/scripts/select-next-task: To Do が無いとき RESULT: NO_CANDIDATE（exit 2）"
else
  fail "claude-skills/improvement-dispatch/scripts/select-next-task: To Do が無いときの結果が期待と異なる（exit ${select_exit}）:
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
  pass "claude-skills/improvement-dispatch/scripts/select-next-task: 優先度最高（High, TASK-2）が選定される"
else
  fail "claude-skills/improvement-dispatch/scripts/select-next-task: 通常選定の結果が期待と異なる（TASK-2 を期待、exit ${select_exit}）:
$select_out"
fi

# --- 7c. blocked:needs-decision ラベル除外 + 同優先度タイブレークがID最小になる ---
(cd "$TMP_REPO_SELECT" && backlog task edit TASK-2 --label 'blocked:needs-decision' --plain >/dev/null)
select_out="$(cd "$TMP_REPO_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-3'; then
  pass "claude-skills/improvement-dispatch/scripts/select-next-task: blocked:needs-decision 付き（TASK-2）を除外し、同優先度でID最小（TASK-3）を選ぶ"
else
  fail "claude-skills/improvement-dispatch/scripts/select-next-task: blocked ラベル除外後の結果が期待と異なる（TASK-3 を期待、exit ${select_exit}）:
$select_out"
fi

# --- 7d. 依存タスク未完了の除外、依存解消後の再選定 ---
(cd "$TMP_REPO_SELECT" && backlog task edit TASK-3 --dep task-1 --plain >/dev/null)
select_out="$(cd "$TMP_REPO_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-4'; then
  pass "claude-skills/improvement-dispatch/scripts/select-next-task: 未完了の依存（TASK-1）を持つ TASK-3 を除外し、TASK-4 を選ぶ"
else
  fail "claude-skills/improvement-dispatch/scripts/select-next-task: 依存未完了除外後の結果が期待と異なる（TASK-4 を期待、exit ${select_exit}）:
$select_out"
fi

# 依存タスクを Done にすると、除外されていた TASK-3 が再び選ばれる
# （同優先度内でID最小が優先されることの確認も兼ねる）。
(cd "$TMP_REPO_SELECT" && backlog task edit TASK-1 -s "Done" --plain >/dev/null)
select_out="$(cd "$TMP_REPO_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 0 ] && printf '%s\n' "$select_out" | grep -Fxq 'TASK_ID: TASK-3'; then
  pass "claude-skills/improvement-dispatch/scripts/select-next-task: 依存タスク（TASK-1）が Done になると TASK-3 が再び選ばれる"
else
  fail "claude-skills/improvement-dispatch/scripts/select-next-task: 依存解消後の結果が期待と異なる（TASK-3 を期待、exit ${select_exit}）:
$select_out"
fi

# --- 7e. max_in_progress GATED ---
(cd "$TMP_REPO_SELECT" && backlog task edit TASK-3 -s "In Progress" --plain >/dev/null)
select_out="$(cd "$TMP_REPO_SELECT" && "$SELECT_SCRIPT" 1 3 2>&1)"
select_exit=$?
if [ "$select_exit" -eq 1 ] && printf '%s\n' "$select_out" | grep -Fxq 'RESULT: GATED' \
    && printf '%s\n' "$select_out" | grep -Fxq 'REASON: max_in_progress'; then
  pass "claude-skills/improvement-dispatch/scripts/select-next-task: In Progress が max_in_progress 以上のとき RESULT: GATED / REASON: max_in_progress（exit 1）"
else
  fail "claude-skills/improvement-dispatch/scripts/select-next-task: max_in_progress ゲートの結果が期待と異なる（exit ${select_exit}）:
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
  pass "claude-skills/improvement-dispatch/scripts/select-next-task: In Review が max_in_review 以上のとき RESULT: GATED / REASON: max_in_review（exit 1）"
else
  fail "claude-skills/improvement-dispatch/scripts/select-next-task: max_in_review ゲートの結果が期待と異なる（exit ${select_exit}）:
$select_out"
fi

finish_tests
