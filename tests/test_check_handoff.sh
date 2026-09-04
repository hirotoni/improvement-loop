#!/usr/bin/env bash
# claude-code/skills/improvement-work/scripts/check-handoff に対するテスト。
# 一時 git リポジトリを作り、3条件（作業ディレクトリ一致・ブランチ一致・
# .backlog シンボリックリンクの健全性）の判定を実際に実行して検証する。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 12. claude-code/skills/improvement-work/scripts/check-handoff の動作確認 ==="

TMP_HANDOFF_REPO="$(mktemp -d)"
# macOS の mktemp -d はシンボリックリンク経由のパスを返す。check-handoff 内部の
# pwd -P による正規化後のパスと比較するため、ここでも同じ正規化をしておく。
TMP_HANDOFF_REPO="$(cd "$TMP_HANDOFF_REPO" && pwd -P)"
register_tmp_cleanup "$TMP_HANDOFF_REPO"

HANDOFF_BRANCH="improvement/task-99-handoff-check"
(cd "$TMP_HANDOFF_REPO" && git init -q -b "$HANDOFF_BRANCH" && git commit -q --allow-empty -m init)
ln -s "$TMP_HANDOFF_REPO" "$TMP_HANDOFF_REPO/.backlog"

echo ""
echo "--- 12a. 3条件すべてを満たすとき、成功（exit 0）で終了する（AC#1） ---"
handoff_ok_output="$(cd "$TMP_HANDOFF_REPO" && "$CHECK_HANDOFF_SCRIPT" "$TMP_HANDOFF_REPO" "$HANDOFF_BRANCH" 2>&1)"
handoff_ok_exit=$?
if [ "$handoff_ok_exit" -eq 0 ]; then
  pass "12a: 作業ディレクトリ・ブランチ・.backlog シンボリックリンクが全て期待通りのとき、exit 0 で終了する"
else
  fail "12a: 3条件を満たすはずなのに exit 0 で終了しなかった（${handoff_ok_exit}）: $handoff_ok_output"
fi

echo ""
echo "--- 12b. 作業ディレクトリが期待するパスと異なるとき、失敗（非0終了コード）で終了する（AC#2） ---"
handoff_wrongdir_output="$(cd "$TMP_HANDOFF_REPO" && "$CHECK_HANDOFF_SCRIPT" "$TMP_HANDOFF_REPO/does-not-exist" "$HANDOFF_BRANCH" 2>&1)"
handoff_wrongdir_exit=$?
if [ "$handoff_wrongdir_exit" -ne 0 ]; then
  pass "12b: 作業ディレクトリが異なるとき、非0終了コードで終了する（${handoff_wrongdir_exit}）"
else
  fail "12b: 作業ディレクトリが異なるはずなのに exit 0 で終了した"
fi
if grep -Fq "作業ディレクトリ" <<<"$handoff_wrongdir_output"; then
  pass "12b: 作業ディレクトリの不一致がエラーメッセージに明示される"
else
  fail "12b: 作業ディレクトリの不一致がエラーメッセージに明示されていない: $handoff_wrongdir_output"
fi

echo ""
echo "--- 12c. 現在のブランチが期待するブランチ名と異なるとき、失敗（非0終了コード）で終了する（AC#3） ---"
handoff_wrongbranch_output="$(cd "$TMP_HANDOFF_REPO" && "$CHECK_HANDOFF_SCRIPT" "$TMP_HANDOFF_REPO" "some-other-branch" 2>&1)"
handoff_wrongbranch_exit=$?
if [ "$handoff_wrongbranch_exit" -ne 0 ]; then
  pass "12c: ブランチが異なるとき、非0終了コードで終了する（${handoff_wrongbranch_exit}）"
else
  fail "12c: ブランチが異なるはずなのに exit 0 で終了した"
fi
if grep -Fq "ブランチ" <<<"$handoff_wrongbranch_output"; then
  pass "12c: ブランチの不一致がエラーメッセージに明示される"
else
  fail "12c: ブランチの不一致がエラーメッセージに明示されていない: $handoff_wrongbranch_output"
fi

echo ""
echo "--- 12d. .backlog がシンボリックリンクとして存在しないとき、失敗（非0終了コード）で終了する（AC#4） ---"
rm "$TMP_HANDOFF_REPO/.backlog"
handoff_nolink_output="$(cd "$TMP_HANDOFF_REPO" && "$CHECK_HANDOFF_SCRIPT" "$TMP_HANDOFF_REPO" "$HANDOFF_BRANCH" 2>&1)"
handoff_nolink_exit=$?
if [ "$handoff_nolink_exit" -ne 0 ]; then
  pass "12d: .backlog が無いとき、非0終了コードで終了する（${handoff_nolink_exit}）"
else
  fail "12d: .backlog が無いはずなのに exit 0 で終了した"
fi
if grep -Fq ".backlog" <<<"$handoff_nolink_output"; then
  pass "12d: .backlog の欠落がエラーメッセージに明示される"
else
  fail "12d: .backlog の欠落がエラーメッセージに明示されていない: $handoff_nolink_output"
fi

echo ""
echo "--- 12e. .backlog が壊れたシンボリックリンクのとき、失敗（非0終了コード）で終了する（AC#4） ---"
ln -s "$TMP_HANDOFF_REPO/no-such-target" "$TMP_HANDOFF_REPO/.backlog"
handoff_brokenlink_output="$(cd "$TMP_HANDOFF_REPO" && "$CHECK_HANDOFF_SCRIPT" "$TMP_HANDOFF_REPO" "$HANDOFF_BRANCH" 2>&1)"
handoff_brokenlink_exit=$?
if [ "$handoff_brokenlink_exit" -ne 0 ]; then
  pass "12e: .backlog が壊れたシンボリックリンクのとき、非0終了コードで終了する（${handoff_brokenlink_exit}）"
else
  fail "12e: .backlog が壊れたシンボリックリンクのはずなのに exit 0 で終了した"
fi
if grep -Fq ".backlog" <<<"$handoff_brokenlink_output"; then
  pass "12e: .backlog の壊れたリンクがエラーメッセージに明示される"
else
  fail "12e: .backlog の壊れたリンクがエラーメッセージに明示されていない: $handoff_brokenlink_output"
fi
rm -f "$TMP_HANDOFF_REPO/.backlog"
ln -s "$TMP_HANDOFF_REPO" "$TMP_HANDOFF_REPO/.backlog"

echo ""
echo "--- 12f. .backlog がシンボリックリンクではなく実体のディレクトリのとき、失敗（非0終了コード）で終了する（AC#4） ---"
rm "$TMP_HANDOFF_REPO/.backlog"
mkdir "$TMP_HANDOFF_REPO/.backlog"
handoff_realdir_output="$(cd "$TMP_HANDOFF_REPO" && "$CHECK_HANDOFF_SCRIPT" "$TMP_HANDOFF_REPO" "$HANDOFF_BRANCH" 2>&1)"
handoff_realdir_exit=$?
if [ "$handoff_realdir_exit" -ne 0 ]; then
  pass "12f: .backlog が実体のディレクトリのとき、非0終了コードで終了する（${handoff_realdir_exit}）"
else
  fail "12f: .backlog が実体のディレクトリのはずなのに exit 0 で終了した"
fi
if grep -Fq ".backlog" <<<"$handoff_realdir_output"; then
  pass "12f: .backlog が実体のディレクトリであることがエラーメッセージに明示される"
else
  fail "12f: .backlog が実体のディレクトリであることがエラーメッセージに明示されていない: $handoff_realdir_output"
fi
rm -rf "$TMP_HANDOFF_REPO/.backlog"
ln -s "$TMP_HANDOFF_REPO" "$TMP_HANDOFF_REPO/.backlog"

echo ""
echo "--- 12g. 引数不足のとき、使い方を示して失敗（非0終了コード）で終了する ---"
if "$CHECK_HANDOFF_SCRIPT" >/dev/null 2>&1; then
  fail "12g: 引数無しで check-handoff を実行してもエラーにならない"
else
  pass "12g: 引数無しで check-handoff を実行するとエラーになる"
fi

if "$CHECK_HANDOFF_SCRIPT" "relative/path" "$HANDOFF_BRANCH" >/dev/null 2>&1; then
  fail "12g: 期待する作業ディレクトリに相対パスを渡してもエラーにならない"
else
  pass "12g: 期待する作業ディレクトリに相対パスを渡すとエラーになる"
fi

finish_tests
