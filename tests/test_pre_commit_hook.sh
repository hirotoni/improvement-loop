#!/usr/bin/env bash
# githooks/pre-commit に対するテスト。
#
# フック自体は `git rev-parse --show-toplevel` で解決したリポジトリルート直下の
# tests/run.sh を実行するだけの薄いラッパーなので、一時リポジトリの直下に
# tests/run.sh という名前でスタブを置けば、実運用と同じ経路（core.hooksPath 経由の
# 起動 → ルートの tests/run.sh 実行）を保ったまま外部依存無しに検証できる。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 11. githooks/pre-commit の動作確認 ==="

if [ ! -f "$PRECOMMIT_HOOK" ]; then
  fail "githooks/pre-commit が存在しない: $PRECOMMIT_HOOK"
elif [ ! -x "$PRECOMMIT_HOOK" ]; then
  fail "githooks/pre-commit に実行ビットが無い"
else
  pass "githooks/pre-commit が実行可能ファイルとして存在する"
fi

TMP_HOOK_REPO="$(mktemp -d)"
register_tmp_cleanup "$TMP_HOOK_REPO"

(cd "$TMP_HOOK_REPO" && git init -q -b main)
git -C "$TMP_HOOK_REPO" config user.email "test@example.com"
git -C "$TMP_HOOK_REPO" config user.name "Test"

mkdir -p "$TMP_HOOK_REPO/githooks"
cp "$PRECOMMIT_HOOK" "$TMP_HOOK_REPO/githooks/pre-commit"
chmod +x "$TMP_HOOK_REPO/githooks/pre-commit"
git -C "$TMP_HOOK_REPO" config core.hooksPath githooks

mkdir -p "$TMP_HOOK_REPO/tests"

# ---- FAIL するスタブ: コミットが阻止されることを確認する ----
cat > "$TMP_HOOK_REPO/tests/run.sh" <<'STUB'
#!/usr/bin/env bash
echo "PASS: 0, FAIL: 1, SKIP: 0"
exit 1
STUB
chmod +x "$TMP_HOOK_REPO/tests/run.sh"

git -C "$TMP_HOOK_REPO" add -A
head_before_fail="$(git -C "$TMP_HOOK_REPO" rev-parse HEAD 2>/dev/null || echo NONE)"
hook_fail_output="$(cd "$TMP_HOOK_REPO" && git commit -q -m "should be blocked" 2>&1)"
hook_fail_exit=$?
head_after_fail="$(git -C "$TMP_HOOK_REPO" rev-parse HEAD 2>/dev/null || echo NONE)"

if [ "$hook_fail_exit" -ne 0 ]; then
  pass "tests/run.sh が FAIL するとき、git commit が非ゼロで終了する（pre-commit フックがブロックする）"
else
  fail "tests/run.sh が FAIL しても git commit が成功してしまった（exit 0）: $hook_fail_output"
fi

if [ "$head_before_fail" = "$head_after_fail" ]; then
  pass "tests/run.sh が FAIL するとき、コミットが実際には作成されない（HEAD が進まない）"
else
  fail "tests/run.sh が FAIL したのにコミットが作成されてしまった（HEAD が進んだ）"
fi

# ---- PASS するスタブ: コミットが成功することを確認する ----
cat > "$TMP_HOOK_REPO/tests/run.sh" <<'STUB'
#!/usr/bin/env bash
echo "PASS: 1, FAIL: 0, SKIP: 0"
exit 0
STUB
chmod +x "$TMP_HOOK_REPO/tests/run.sh"

git -C "$TMP_HOOK_REPO" add -A
head_before_pass="$(git -C "$TMP_HOOK_REPO" rev-parse HEAD 2>/dev/null || echo NONE)"
hook_pass_output="$(cd "$TMP_HOOK_REPO" && git commit -q -m "should succeed" 2>&1)"
hook_pass_exit=$?
head_after_pass="$(git -C "$TMP_HOOK_REPO" rev-parse HEAD 2>/dev/null || echo NONE)"

if [ "$hook_pass_exit" -eq 0 ]; then
  pass "tests/run.sh が成功するとき、git commit が成功する（exit 0）"
else
  fail "tests/run.sh が成功しても git commit が失敗した: $hook_pass_output"
fi

if [ "$head_before_pass" != "$head_after_pass" ] && [ "$head_after_pass" != "NONE" ]; then
  pass "tests/run.sh が成功するとき、コミットが実際に作成される（HEAD が進む）"
else
  fail "tests/run.sh が成功したのにコミットが作成されなかった（HEAD が進んでいない）"
fi

finish_tests
