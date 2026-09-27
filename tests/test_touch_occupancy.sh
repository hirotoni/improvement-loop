#!/usr/bin/env bash
# claude-code/skills/improvement-dispatch/scripts/touch-occupancy に対するテスト。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 14. claude-code/skills/improvement-dispatch/scripts/touch-occupancy の動作確認 ==="
# 一時 git リポジトリに対して実際に実行して検証する。

TMP_TO_REPO="$(mktemp -d)"
# macOS の mktemp -d はシンボリックリンク経由のパスを返し、touch-occupancy 内部の
# pwd -P による正規化後と一致しない。ここでも同じ正規化をしておく。
TMP_TO_REPO="$(cd "$TMP_TO_REPO" && pwd -P)"
TO_WORKTREE_DIR="${TMP_TO_REPO}-wt"
register_tmp_cleanup "$TMP_TO_REPO" "$TO_WORKTREE_DIR"

(cd "$TMP_TO_REPO" && git init -q -b main && git commit -q --allow-empty -m init)

TO_TASK_ID="task-93-touch-occupancy-test"
TO_BRANCH="improvement/$TO_TASK_ID"
(cd "$TMP_TO_REPO" && git worktree add -q -b "$TO_BRANCH" "$TO_WORKTREE_DIR" main)

echo ""
echo "--- 14a. 正常系: 登録済みワークツリー・一致する task_id -> RESULT: OK で占有記録を作成する ---"
to_out_a="$(cd "$TMP_TO_REPO" && "$TOUCH_OCCUPANCY_SCRIPT" "$TO_WORKTREE_DIR" "$TO_TASK_ID" 2>&1)"
to_exit_a=$?
TO_OCCUPANCY_FILE="$TO_WORKTREE_DIR/.worktree-occupancy"
if [ "$to_exit_a" -eq 0 ] && printf '%s\n' "$to_out_a" | grep -Fxq 'RESULT: OK'; then
  pass "14a: 登録済みワークツリー・一致する task_id では RESULT: OK（exit 0）"
else
  fail "14a: 期待した結果と異なる（exit ${to_exit_a}）:
$to_out_a"
fi

if [ -f "$TO_OCCUPANCY_FILE" ]; then
  pass "14a: 占有記録ファイル(.worktree-occupancy)がワークツリー直下に作成される（AC#1）"
else
  fail "14a: 占有記録ファイルが作成されていない: $TO_OCCUPANCY_FILE"
fi

if grep -Fxq "TASK_ID=$TO_TASK_ID" "$TO_OCCUPANCY_FILE" 2>/dev/null; then
  pass "14a: 占有記録に想定した TASK_ID が記録される"
else
  fail "14a: 占有記録に想定した TASK_ID が記録されていない: $(cat "$TO_OCCUPANCY_FILE" 2>/dev/null)"
fi

if grep -Eq '^ASSIGNED_AT_EPOCH=[0-9]+$' "$TO_OCCUPANCY_FILE" 2>/dev/null; then
  pass "14a: 占有記録に ASSIGNED_AT_EPOCH が数値として記録される"
else
  fail "14a: 占有記録に ASSIGNED_AT_EPOCH が記録されていない: $(cat "$TO_OCCUPANCY_FILE" 2>/dev/null)"
fi

echo ""
echo "--- 14b. 冪等性・上書き更新: 2回目の実行でタイムスタンプが更新され、記録が壊れない ---"
TO_FIRST_EPOCH="$(grep '^ASSIGNED_AT_EPOCH=' "$TO_OCCUPANCY_FILE" 2>/dev/null | cut -d= -f2)"
sleep 1
to_out_b="$(cd "$TMP_TO_REPO" && "$TOUCH_OCCUPANCY_SCRIPT" "$TO_WORKTREE_DIR" "$TO_TASK_ID" 2>&1)"
to_exit_b=$?
TO_SECOND_EPOCH="$(grep '^ASSIGNED_AT_EPOCH=' "$TO_OCCUPANCY_FILE" 2>/dev/null | cut -d= -f2)"
if [ "$to_exit_b" -eq 0 ] && printf '%s\n' "$to_out_b" | grep -Fxq 'RESULT: OK'; then
  pass "14b: 2回目の実行も RESULT: OK（exit 0）"
else
  fail "14b: 期待した結果と異なる（exit ${to_exit_b}）:
$to_out_b"
fi

if [ -n "$TO_FIRST_EPOCH" ] && [ -n "$TO_SECOND_EPOCH" ] && [ "$TO_SECOND_EPOCH" -gt "$TO_FIRST_EPOCH" ]; then
  pass "14b: 2回目の実行でタイムスタンプが更新される"
else
  fail "14b: 2回目の実行でタイムスタンプが更新されていない: 1回目=${TO_FIRST_EPOCH:-なし}, 2回目=${TO_SECOND_EPOCH:-なし}"
fi

to_occupancy_line_count="$(wc -l < "$TO_OCCUPANCY_FILE" 2>/dev/null | tr -d ' ')"
to_occupancy_taskid_count="$(grep -Fxc "TASK_ID=$TO_TASK_ID" "$TO_OCCUPANCY_FILE" 2>/dev/null || true)"
if [ "$to_occupancy_line_count" = "3" ] && [ "$to_occupancy_taskid_count" = "1" ]; then
  pass "14b: 2回目の実行後も占有記録が壊れていない（TASK_ID行が重複せず、3行のまま）"
else
  fail "14b: 2回目の実行後、占有記録が壊れている（総行数: ${to_occupancy_line_count}, TASK_ID行: ${to_occupancy_taskid_count}件）:
$(cat "$TO_OCCUPANCY_FILE" 2>/dev/null)"
fi

echo ""
echo "--- 14c. 異常系: 存在しないワークツリーパスを渡すとエラーになる（AC#2） ---"
TO_NONEXISTENT_DIR="${TMP_TO_REPO}-does-not-exist"
to_out_c="$(cd "$TMP_TO_REPO" && "$TOUCH_OCCUPANCY_SCRIPT" "$TO_NONEXISTENT_DIR" "$TO_TASK_ID" 2>&1)"
to_exit_c=$?
if [ "$to_exit_c" -ne 0 ] && printf '%s\n' "$to_out_c" | grep -Fxq 'RESULT: ERROR'; then
  pass "14c: 存在しないワークツリーパスを渡すと RESULT: ERROR（非ゼロ終了）になる（AC#2）"
else
  fail "14c: 期待した結果と異なる（exit ${to_exit_c}）:
$to_out_c"
fi

echo ""
echo "--- 14d. 異常系: 登録済みワークツリーだが一致しない task_id を渡すとエラーになる（AC#2） ---"
TO_MISMATCHED_TASK_ID="task-93-mismatched-task-id"
to_out_d="$(cd "$TMP_TO_REPO" && "$TOUCH_OCCUPANCY_SCRIPT" "$TO_WORKTREE_DIR" "$TO_MISMATCHED_TASK_ID" 2>&1)"
to_exit_d=$?
if [ "$to_exit_d" -ne 0 ] && printf '%s\n' "$to_out_d" | grep -Fxq 'RESULT: ERROR'; then
  pass "14d: 一致しない task_id を渡すと RESULT: ERROR（非ゼロ終了）になる（AC#2）"
else
  fail "14d: 期待した結果と異なる（exit ${to_exit_d}）:
$to_out_d"
fi

if ! grep -Fxq "TASK_ID=$TO_MISMATCHED_TASK_ID" "$TO_OCCUPANCY_FILE" 2>/dev/null; then
  pass "14d: 一致しない task_id で既存の占有記録が上書きされていない（AC#2）"
else
  fail "14d: 一致しない task_id で既存の占有記録が誤って上書きされてしまった（AC#2違反）:
$(cat "$TO_OCCUPANCY_FILE" 2>/dev/null)"
fi

echo ""
echo "--- 14e. 異常系: 引数の個数が不正だとエラーになる ---"
if (cd "$TMP_TO_REPO" && "$TOUCH_OCCUPANCY_SCRIPT" "$TO_WORKTREE_DIR" >/dev/null 2>&1); then
  fail "14e: 引数不足で touch-occupancy を実行してもエラーにならない"
else
  pass "14e: 引数不足で touch-occupancy を実行するとエラーになる"
fi

echo ""
echo "--- 14f. 異常系: task_id の形式が不正だとエラーになる ---"
to_out_f="$(cd "$TMP_TO_REPO" && "$TOUCH_OCCUPANCY_SCRIPT" "$TO_WORKTREE_DIR" "Not_A_Valid_Task_Id" 2>&1)"
to_exit_f=$?
if [ "$to_exit_f" -ne 0 ] && printf '%s\n' "$to_out_f" | grep -Fxq 'RESULT: ERROR'; then
  pass "14f: task_id の形式が不正だと RESULT: ERROR（非ゼロ終了）になる"
else
  fail "14f: 期待した結果と異なる（exit ${to_exit_f}）:
$to_out_f"
fi

finish_tests
