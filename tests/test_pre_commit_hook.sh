#!/usr/bin/env bash
# githooks/pre-commit に対するテスト。
#
# フックは tests/run.sh を実行するだけの薄いラッパーで、非ゼロ終了でコミットが
# 止まるのは git 本体の仕様なので、ここでは検証しない。確かめるのは、フックとして
# 起動されるのに必要な実行ビットが付いていることだけである。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== githooks/pre-commit の動作確認 ==="

if [ ! -f "$PRECOMMIT_HOOK" ]; then
  fail "githooks/pre-commit が存在しない: $PRECOMMIT_HOOK"
elif [ ! -x "$PRECOMMIT_HOOK" ]; then
  fail "githooks/pre-commit に実行ビットが無い"
else
  pass "githooks/pre-commit が実行可能ファイルとして存在する"
fi

finish_tests
