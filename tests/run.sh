#!/usr/bin/env bash
# tests/run.sh
#
# improvement-loop の依存ゼロの最小テストランナー。
# 依存は bash/zsh・git・backlog のみ。いずれか欠けていれば、各テスト
# ファイルがその旨を報告してスキップする（テスト対象の不具合として
# 失敗にはしない）。
#
# tests/ 配下には、対象スクリプトごとに独立した test_*.sh が置かれている
# （TASK-36: 従来この run.sh 自体が全セクションを1ファイル・1プロセスで
# 直列実行していたモノリシック構成から分割した）。このファイルは、それら
# 各ファイルを順にサブプロセスとして実行し、標準出力をそのまま表示しつつ、
# 各ファイル末尾のサマリー行（"PASS: x, FAIL: y, SKIP: z"）を合算して
# 全体のPASS/FAIL/SKIPを報告する薄い共通ランナーである。
#
# 個々のスクリプトのテストだけを実行したい場合は、対応する test_*.sh を
# 直接実行すればよい（例: bash tests/test_select_next_task.sh）。
# githooks/pre-commit はこのファイルを唯一のエントリポイントとして実行し、
# 1件でもFAILがあれば非ゼロで終了する（分割前と同じ契約）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# TEST_FILES: 実行するテストファイルの一覧。対象スクリプトが増えたら
# ここに1行追加するだけでよい。
TEST_FILES=(
  "test_syntax.sh"
  "test_setup_improvement_loop.sh"
  "test_list_opted_in_repos.sh"
  "test_select_next_task.sh"
  "test_merge_reviewed_branch.sh"
  "test_create_worktree.sh"
  "test_pre_commit_hook.sh"
  "test_check_handoff.sh"
  "test_skill_script_lookup.sh"
  "test_check_progress_recovery.sh"
  "test_check_forbidden_allowed_paths.sh"
)

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

SUMMARY_RE='^PASS: ([0-9]+), FAIL: ([0-9]+), SKIP: ([0-9]+)$'

for test_file in "${TEST_FILES[@]}"; do
  test_path="$SCRIPT_DIR/$test_file"

  if [ ! -f "$test_path" ]; then
    echo "FAIL: テストファイルが見つからない: $test_path"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    continue
  fi

  echo ""
  echo "##### $test_file #####"

  output="$(bash "$test_path" 2>&1)"
  exit_code=$?
  printf '%s\n' "$output"

  summary_line="$(printf '%s\n' "$output" | grep -E "$SUMMARY_RE" | tail -1)"
  if [ -n "$summary_line" ] && [[ "$summary_line" =~ $SUMMARY_RE ]]; then
    TOTAL_PASS=$((TOTAL_PASS + BASH_REMATCH[1]))
    TOTAL_FAIL=$((TOTAL_FAIL + BASH_REMATCH[2]))
    TOTAL_SKIP=$((TOTAL_SKIP + BASH_REMATCH[3]))
  elif [ "$exit_code" -ne 0 ]; then
    # サマリー行を出さずに異常終了するのは、依存不足によるスキップ
    # （exit 0）以外では想定していない。非0終了なのにサマリー行が無い
    # 場合は、テストファイル自体が壊れている可能性が高いため FAIL 扱いにする。
    echo "FAIL: $test_file がサマリー行を出力せずに異常終了した（exit ${exit_code}）"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
done

echo ""
echo "=== 総合サマリー ==="
printf 'PASS: %d, FAIL: %d, SKIP: %d\n' "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_SKIP"

if [ "$TOTAL_FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
