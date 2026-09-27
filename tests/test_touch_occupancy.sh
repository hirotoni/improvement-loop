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

TO_OCCUPANCY_FILE="$TO_WORKTREE_DIR/.worktree-occupancy"

# 占有記録の書式（bin/lib/occupancy.sh の occupancy_write_file が書く3行）の検査は
# このファイルに集める。create-worktree も同じ関数で書くので、test_create_worktree.sh は
# 「正しい TASK_ID で書いたか」「再利用時に書き直したか」だけを確かめる。
# 引数: <節のラベル>。TASK_ID・ASSIGNED_AT（ISO8601）・ASSIGNED_AT_EPOCH（数値）の各1行、
# 計3行だけで、TASK_ID 行が重複していないことを確かめる。
to_check_occupancy_format() {
  local label="$1" content
  content="$(cat "$TO_OCCUPANCY_FILE" 2>/dev/null)"
  ASSERT_DETAIL="占有記録の中身:
$content"
  assert "$label: 占有記録に想定した TASK_ID が記録される" has_line "$content" "TASK_ID=$TO_TASK_ID"
  assert "$label: 占有記録に ASSIGNED_AT_EPOCH が数値として記録される" \
    grep -Eq '^ASSIGNED_AT_EPOCH=[0-9]+$' "$TO_OCCUPANCY_FILE"
  assert "$label: 占有記録に ASSIGNED_AT が ISO8601 形式（UTC）で記録される" \
    grep -Eq '^ASSIGNED_AT=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$TO_OCCUPANCY_FILE"
  assert "$label: 占有記録が3行で、TASK_ID 行が重複しない（追記ではなく上書き）" \
    [ "$(wc -l < "$TO_OCCUPANCY_FILE" | tr -d ' '):$(grep -Fxc "TASK_ID=$TO_TASK_ID" "$TO_OCCUPANCY_FILE")" = "3:1" ]
}

echo ""
echo "--- 14a. 正常系: 登録済みワークツリー・一致する task_id -> RESULT: OK で占有記録を作成する ---"
run_in "$TMP_TO_REPO" "$TOUCH_OCCUPANCY_SCRIPT" "$TO_WORKTREE_DIR" "$TO_TASK_ID"
assert "14a: 登録済みワークツリー・一致する task_id では RESULT: OK（exit 0）" \
  run_result 0 'RESULT: OK'
assert "14a: 占有記録ファイル(.worktree-occupancy)がワークツリー直下に作成される（AC#1）" [ -f "$TO_OCCUPANCY_FILE" ]
to_check_occupancy_format "14a"

echo ""
echo "--- 14b. 冪等性・上書き更新: 2回目の実行でタイムスタンプが更新され、記録が壊れない ---"
# sleep で時刻を進める代わりに、古い時刻の占有記録を先に書いておく。
TO_OLD_EPOCH=1
printf 'TASK_ID=%s\nASSIGNED_AT=1970-01-01T00:00:01Z\nASSIGNED_AT_EPOCH=%s\n' "$TO_TASK_ID" "$TO_OLD_EPOCH" > "$TO_OCCUPANCY_FILE"
run_in "$TMP_TO_REPO" "$TOUCH_OCCUPANCY_SCRIPT" "$TO_WORKTREE_DIR" "$TO_TASK_ID"
assert "14b: 2回目の実行も RESULT: OK（exit 0）" run_result 0 'RESULT: OK'
TO_SECOND_EPOCH="$(grep '^ASSIGNED_AT_EPOCH=' "$TO_OCCUPANCY_FILE" 2>/dev/null | cut -d= -f2)"
ASSERT_DETAIL="事前に書いた epoch=${TO_OLD_EPOCH}, 実行後=${TO_SECOND_EPOCH:-なし}"
assert "14b: 2回目の実行でタイムスタンプが更新される" [ "${TO_SECOND_EPOCH:-0}" -gt "$TO_OLD_EPOCH" ]
to_check_occupancy_format "14b"

echo ""
echo "--- 14c. 異常系: 存在しないワークツリーパスを渡すとエラーになる（AC#2） ---"
run_in "$TMP_TO_REPO" "$TOUCH_OCCUPANCY_SCRIPT" "${TMP_TO_REPO}-does-not-exist" "$TO_TASK_ID"
assert "14c: 存在しないワークツリーパスを渡すと RESULT: ERROR（非ゼロ終了）になる（AC#2）" \
  run_result nz 'RESULT: ERROR'

echo ""
echo "--- 14d. 異常系: 登録済みワークツリーだが一致しない task_id を渡すとエラーになる（AC#2） ---"
TO_MISMATCHED_TASK_ID="task-93-mismatched-task-id"
run_in "$TMP_TO_REPO" "$TOUCH_OCCUPANCY_SCRIPT" "$TO_WORKTREE_DIR" "$TO_MISMATCHED_TASK_ID"
assert "14d: 一致しない task_id を渡すと RESULT: ERROR（非ゼロ終了）になる（AC#2）" \
  run_result nz 'RESULT: ERROR'
assert_not "14d: 一致しない task_id で既存の占有記録が上書きされていない（AC#2）" \
  grep -Fxq "TASK_ID=$TO_MISMATCHED_TASK_ID" "$TO_OCCUPANCY_FILE"

echo ""
echo "--- 14e. 異常系: 引数の個数が不正だとエラーになる ---"
run_in "$TMP_TO_REPO" "$TOUCH_OCCUPANCY_SCRIPT" "$TO_WORKTREE_DIR"
assert "14e: 引数不足で touch-occupancy を実行するとエラーになる" [ "$RUN_EXIT" -ne 0 ]

echo ""
echo "--- 14f. 異常系: task_id の形式が不正だとエラーになる ---"
run_in "$TMP_TO_REPO" "$TOUCH_OCCUPANCY_SCRIPT" "$TO_WORKTREE_DIR" "Not_A_Valid_Task_Id"
assert "14f: task_id の形式が不正だと RESULT: ERROR（非ゼロ終了）になる" \
  run_result nz 'RESULT: ERROR'

finish_tests
