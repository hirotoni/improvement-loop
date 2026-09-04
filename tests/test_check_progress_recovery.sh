#!/usr/bin/env bash
# tests/test_check_progress_recovery.sh
#
# claude-code/skills/improvement-dispatch/scripts/check-progress-recovery に対する
# テスト。単体で実行すると、このファイルの検証だけが走る。tests/run.sh から
# 全体実行の一部としても呼ばれる。
#
# 依存は bash/zsh・git・backlog のみ。いずれか欠けていれば、その旨を
# 報告してスキップする（テスト対象の不具合として失敗にはしない）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 13. claude-code/skills/improvement-dispatch/scripts/check-progress-recovery の動作確認 ==="
# improvement-dispatch 手順2-3（In Progress タスクの引き渡し先が失われたと
# 確定した後の復旧診断）を切り出した claude-code/skills/improvement-dispatch/scripts/check-progress-recovery を、
# 一時 git リポジトリに対して実際に実行して検証する（TASK-21 受入基準 #1-#3 に対応）。
#   13a. ワークツリー有り・ブランチ有り・新しいコミット有り -> REUSE_WORKTREE_REDISPATCH（AC#1）
#   13b. ワークツリー無し・ブランチ有り・新しいコミット有り -> RECREATE_WORKTREE_REDISPATCH（AC#2）
#   13c. ブランチが存在しない -> REVERT_TO_TODO（AC#3）
#   13d. ブランチは存在するが新しいコミットが無い -> REVERT_TO_TODO（AC#3）
#   13e. 引数の妥当性検証（引数不足・base_branch が解決できない）
#
# 占有記録（.worktree-occupancy、TASK-40）の鮮度を追加の判定材料にする
# TASK-41 の回帰テスト:
#   13f. ブランチ有り・新しいコミット無し・占有記録が新しい
#        -> REUSE_WORKTREE_REDISPATCH に上書きされる（AC#1）
#   13g. ブランチ有り・新しいコミット無し・占有記録が古い
#        -> 既存通り REVERT_TO_TODO のまま変わらない（AC#2）
#   13h. ブランチ有り・新しいコミット無し・占有記録が存在しない
#        -> 既存通り REVERT_TO_TODO のまま変わらない（AC#2・AC#3）

TMP_CR_REPO="$(mktemp -d)"
# macOS では mktemp -d が返すパス（/var/...）がシンボリックリンクであり、
# claude-code/skills/improvement-dispatch/scripts/check-progress-recovery 内部の pwd -P による正規化後
# （/private/var/...）と文字列比較が一致しない。ここでも同じ正規化をしておく。
TMP_CR_REPO="$(cd "$TMP_CR_REPO" && pwd -P)"
CR_WORKTREE_DIR="${TMP_CR_REPO}-wt"
register_tmp_cleanup "$TMP_CR_REPO" "$CR_WORKTREE_DIR"

(cd "$TMP_CR_REPO" && git init -q -b main && git commit -q --allow-empty -m init)
(cd "$TMP_CR_REPO" && git worktree add -q -b feature-recovery-a "$CR_WORKTREE_DIR" main)
(cd "$CR_WORKTREE_DIR" && git commit -q --allow-empty -m "in-progress work")

echo ""
echo "--- 13a. ワークツリー有り・ブランチ有り・新しいコミット有り -> REUSE_WORKTREE_REDISPATCH ---"
cr_out_a="$(cd "$TMP_CR_REPO" && "$CHECK_RECOVERY_SCRIPT" "$CR_WORKTREE_DIR" feature-recovery-a main 2>&1)"
cr_exit_a=$?
if [ "$cr_exit_a" -eq 0 ] && printf '%s\n' "$cr_out_a" | grep -Fxq 'RESULT: REUSE_WORKTREE_REDISPATCH'; then
  pass "13a: ワークツリー・ブランチともに存在し新しいコミットがある場合、RESULT: REUSE_WORKTREE_REDISPATCH（exit 0）（AC#1）"
else
  fail "13a: 期待した結果と異なる（exit ${cr_exit_a}）:
$cr_out_a"
fi
if printf '%s\n' "$cr_out_a" | grep -Fxq 'WORKTREE_EXISTS: true' \
    && printf '%s\n' "$cr_out_a" | grep -Fxq 'BRANCH_EXISTS: true' \
    && printf '%s\n' "$cr_out_a" | grep -Fxq 'NEW_COMMITS: 1'; then
  pass "13a: WORKTREE_EXISTS/BRANCH_EXISTS/NEW_COMMITS の内訳が期待通り出力される"
else
  fail "13a: 診断内訳の出力が期待と異なる:
$cr_out_a"
fi

echo ""
echo "--- 13b. ワークツリー無し・ブランチ有り・新しいコミット有り -> RECREATE_WORKTREE_REDISPATCH ---"
(cd "$TMP_CR_REPO" && git worktree remove "$CR_WORKTREE_DIR")
cr_out_b="$(cd "$TMP_CR_REPO" && "$CHECK_RECOVERY_SCRIPT" "$CR_WORKTREE_DIR" feature-recovery-a main 2>&1)"
cr_exit_b=$?
if [ "$cr_exit_b" -eq 1 ] && printf '%s\n' "$cr_out_b" | grep -Fxq 'RESULT: RECREATE_WORKTREE_REDISPATCH'; then
  pass "13b: ワークツリーが無く、ブランチに新しいコミットがある場合、RESULT: RECREATE_WORKTREE_REDISPATCH（exit 1）（AC#2）"
else
  fail "13b: 期待した結果と異なる（exit ${cr_exit_b}）:
$cr_out_b"
fi
if printf '%s\n' "$cr_out_b" | grep -Fxq 'WORKTREE_EXISTS: false' \
    && printf '%s\n' "$cr_out_b" | grep -Fxq 'BRANCH_EXISTS: true'; then
  pass "13b: WORKTREE_EXISTS: false / BRANCH_EXISTS: true が出力される"
else
  fail "13b: 診断内訳の出力が期待と異なる:
$cr_out_b"
fi

echo ""
echo "--- 13c. ブランチが存在しない -> REVERT_TO_TODO ---"
cr_out_c="$(cd "$TMP_CR_REPO" && "$CHECK_RECOVERY_SCRIPT" "$CR_WORKTREE_DIR" no-such-branch main 2>&1)"
cr_exit_c=$?
if [ "$cr_exit_c" -eq 2 ] && printf '%s\n' "$cr_out_c" | grep -Fxq 'RESULT: REVERT_TO_TODO'; then
  pass "13c: ブランチが存在しない場合、RESULT: REVERT_TO_TODO（exit 2）（AC#3）"
else
  fail "13c: 期待した結果と異なる（exit ${cr_exit_c}）:
$cr_out_c"
fi
if printf '%s\n' "$cr_out_c" | grep -Fxq 'BRANCH_EXISTS: false' \
    && printf '%s\n' "$cr_out_c" | grep -Fxq 'NEW_COMMITS: N/A'; then
  pass "13c: BRANCH_EXISTS: false / NEW_COMMITS: N/A が出力される"
else
  fail "13c: 診断内訳の出力が期待と異なる:
$cr_out_c"
fi

echo ""
echo "--- 13d. ブランチは存在するが base_branch から見て新しいコミットが無い -> REVERT_TO_TODO ---"
(cd "$TMP_CR_REPO" && git branch feature-recovery-no-progress)
cr_out_d="$(cd "$TMP_CR_REPO" && "$CHECK_RECOVERY_SCRIPT" "$CR_WORKTREE_DIR" feature-recovery-no-progress main 2>&1)"
cr_exit_d=$?
if [ "$cr_exit_d" -eq 2 ] && printf '%s\n' "$cr_out_d" | grep -Fxq 'RESULT: REVERT_TO_TODO'; then
  pass "13d: ブランチはあるが新しいコミットが無い場合、RESULT: REVERT_TO_TODO（exit 2）（AC#3）"
else
  fail "13d: 期待した結果と異なる（exit ${cr_exit_d}）:
$cr_out_d"
fi
if printf '%s\n' "$cr_out_d" | grep -Fxq 'BRANCH_EXISTS: true' \
    && printf '%s\n' "$cr_out_d" | grep -Fxq 'NEW_COMMITS: 0'; then
  pass "13d: BRANCH_EXISTS: true / NEW_COMMITS: 0 が出力される"
else
  fail "13d: 診断内訳の出力が期待と異なる:
$cr_out_d"
fi

echo ""
echo "--- 13e. 引数の妥当性検証 ---"
if (cd "$TMP_CR_REPO" && "$CHECK_RECOVERY_SCRIPT" "$CR_WORKTREE_DIR" feature-recovery-a >/dev/null 2>&1); then
  fail "13e: 引数不足で claude-code/skills/improvement-dispatch/scripts/check-progress-recovery を実行してもエラーにならない"
else
  pass "13e: 引数不足で claude-code/skills/improvement-dispatch/scripts/check-progress-recovery を実行するとエラーになる"
fi

cr_out_badbase="$(cd "$TMP_CR_REPO" && "$CHECK_RECOVERY_SCRIPT" "$CR_WORKTREE_DIR" feature-recovery-a no-such-base 2>&1)"
cr_exit_badbase=$?
if [ "$cr_exit_badbase" -eq 3 ] && printf '%s\n' "$cr_out_badbase" | grep -Fxq 'RESULT: ERROR'; then
  pass "13e: base_branch が解決できない場合、RESULT: ERROR（exit 3）"
else
  fail "13e: base_branch が解決できない場合の結果が期待と異なる（exit ${cr_exit_badbase}）:
$cr_out_badbase"
fi

# ---- TASK-41: 占有記録（.worktree-occupancy）の鮮度を判定材料にする回帰テスト ----
# 13a-13e とは別に、ワークツリー有り・ブランチ有り・新しいコミット無し
# （＝コミット履歴だけでは REVERT_TO_TODO になるケース）を作り、その中で
# .worktree-occupancy の有無・鮮度を切り替えて検証する。
CR_WORKTREE_DIR2="${TMP_CR_REPO}-wt2"
register_tmp_cleanup "$CR_WORKTREE_DIR2"
(cd "$TMP_CR_REPO" && git worktree add -q -b feature-recovery-occupancy "$CR_WORKTREE_DIR2" main)

echo ""
echo "--- 13f. 占有記録が新しい -> REVERT_TO_TODO ではなく REUSE_WORKTREE_REDISPATCH（AC#1） ---"
now_epoch="$(date -u +%s)"
cat > "$CR_WORKTREE_DIR2/.worktree-occupancy" <<EOF
TASK_ID=task-999-occupancy-fresh-test
ASSIGNED_AT=$(date -u +%FT%TZ)
ASSIGNED_AT_EPOCH=$now_epoch
EOF
cr_out_f="$(cd "$TMP_CR_REPO" && "$CHECK_RECOVERY_SCRIPT" "$CR_WORKTREE_DIR2" feature-recovery-occupancy main 2>&1)"
cr_exit_f=$?
if [ "$cr_exit_f" -eq 0 ] && printf '%s\n' "$cr_out_f" | grep -Fxq 'RESULT: REUSE_WORKTREE_REDISPATCH'; then
  pass "13f: 新しいコミットが無くても占有記録が新しければ RESULT: REUSE_WORKTREE_REDISPATCH（exit 0）（AC#1）"
else
  fail "13f: 期待した結果と異なる（exit ${cr_exit_f}）:
$cr_out_f"
fi
if printf '%s\n' "$cr_out_f" | grep -Fxq 'NEW_COMMITS: 0' \
    && printf '%s\n' "$cr_out_f" | grep -Fxq 'OCCUPANCY_RECORD_EXISTS: true' \
    && printf '%s\n' "$cr_out_f" | grep -Fxq 'OCCUPANCY_FRESH: true'; then
  pass "13f: NEW_COMMITS: 0 と OCCUPANCY_RECORD_EXISTS: true / OCCUPANCY_FRESH: true が出力される（AC#3）"
else
  fail "13f: 診断内訳の出力が期待と異なる:
$cr_out_f"
fi

echo ""
echo "--- 13g. 占有記録が古い -> 既存通り REVERT_TO_TODO のまま変わらない（AC#2） ---"
stale_epoch=$((now_epoch - 3600))
cat > "$CR_WORKTREE_DIR2/.worktree-occupancy" <<EOF
TASK_ID=task-999-occupancy-fresh-test
ASSIGNED_AT=$(date -u +%FT%TZ)
ASSIGNED_AT_EPOCH=$stale_epoch
EOF
cr_out_g="$(cd "$TMP_CR_REPO" && "$CHECK_RECOVERY_SCRIPT" "$CR_WORKTREE_DIR2" feature-recovery-occupancy main 2>&1)"
cr_exit_g=$?
if [ "$cr_exit_g" -eq 2 ] && printf '%s\n' "$cr_out_g" | grep -Fxq 'RESULT: REVERT_TO_TODO'; then
  pass "13g: 占有記録が古い（1時間前）場合も RESULT: REVERT_TO_TODO のまま変わらない（exit 2）（AC#2）"
else
  fail "13g: 期待した結果と異なる（exit ${cr_exit_g}）:
$cr_out_g"
fi
if printf '%s\n' "$cr_out_g" | grep -Fxq 'OCCUPANCY_RECORD_EXISTS: true' \
    && printf '%s\n' "$cr_out_g" | grep -Fxq 'OCCUPANCY_FRESH: false'; then
  pass "13g: OCCUPANCY_RECORD_EXISTS: true / OCCUPANCY_FRESH: false が出力される（AC#3）"
else
  fail "13g: 診断内訳の出力が期待と異なる:
$cr_out_g"
fi

echo ""
echo "--- 13h. 占有記録が存在しない -> 既存通り REVERT_TO_TODO のまま変わらない（AC#2・AC#3） ---"
rm -f "$CR_WORKTREE_DIR2/.worktree-occupancy"
cr_out_h="$(cd "$TMP_CR_REPO" && "$CHECK_RECOVERY_SCRIPT" "$CR_WORKTREE_DIR2" feature-recovery-occupancy main 2>&1)"
cr_exit_h=$?
if [ "$cr_exit_h" -eq 2 ] && printf '%s\n' "$cr_out_h" | grep -Fxq 'RESULT: REVERT_TO_TODO'; then
  pass "13h: 占有記録が無い場合も RESULT: REVERT_TO_TODO のまま変わらない（exit 2）（AC#2、TASK-40導入前のワークツリー相当）"
else
  fail "13h: 期待した結果と異なる（exit ${cr_exit_h}）:
$cr_out_h"
fi
if printf '%s\n' "$cr_out_h" | grep -Fxq 'OCCUPANCY_RECORD_EXISTS: false' \
    && printf '%s\n' "$cr_out_h" | grep -Fxq 'OCCUPANCY_AGE_SECONDS: N/A' \
    && printf '%s\n' "$cr_out_h" | grep -Fxq 'OCCUPANCY_FRESH: N/A'; then
  pass "13h: OCCUPANCY_RECORD_EXISTS: false / OCCUPANCY_AGE_SECONDS: N/A / OCCUPANCY_FRESH: N/A が出力される（AC#3）"
else
  fail "13h: 診断内訳の出力が期待と異なる:
$cr_out_h"
fi

finish_tests
