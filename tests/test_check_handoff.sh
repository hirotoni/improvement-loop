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

# 12d/12e/12f は .backlog の3分岐を区別する。判定失敗は exit 2（使い方エラーの exit 1 と
# 区別する）で、出力には該当分岐の固有文言だけが含まれ、他の2分岐の文言は含まれない。
HANDOFF_MSG_MISSING=".backlog が存在しない"
HANDOFF_MSG_NOT_LINK=".backlog がシンボリックリンクではない"
HANDOFF_MSG_BROKEN="リンク先が有効なディレクトリではない"

# 引数: <テストID> <出力> <終了コード> <期待する固有文言> <含まれてはならない文言>...
assert_handoff_backlog_branch() {
  local id="$1" output="$2" exit_code="$3" expected="$4"
  shift 4
  if [ "$exit_code" -eq 2 ]; then
    pass "${id}: 判定失敗の終了コード 2 で終了する"
  else
    fail "${id}: 終了コードが 2 でない（${exit_code}）: $output"
  fi
  if grep -Fq "$expected" <<<"$output"; then
    pass "${id}: 分岐固有の文言「${expected}」が出力される"
  else
    fail "${id}: 分岐固有の文言「${expected}」が出力されない: $output"
  fi
  local other
  for other in "$@"; do
    if grep -Fq "$other" <<<"$output"; then
      fail "${id}: 別の分岐の文言「${other}」が出力されている: $output"
    else
      pass "${id}: 別の分岐の文言「${other}」は出力されない"
    fi
  done
  local error_lines
  error_lines="$(grep -c '^エラー: ' <<<"$output")"
  if [ "$error_lines" -eq 1 ]; then
    pass "${id}: エラーは .backlog の1件だけである（作業ディレクトリ・ブランチの不一致は出ない）"
  else
    fail "${id}: エラー行が1件でない（${error_lines}件）: $output"
  fi
}

echo ""
echo "--- 12d. .backlog がシンボリックリンクとして存在しないとき、exit 2 で「存在しない」分岐を通る（AC#4） ---"
rm "$TMP_HANDOFF_REPO/.backlog"
handoff_nolink_output="$(cd "$TMP_HANDOFF_REPO" && "$CHECK_HANDOFF_SCRIPT" "$TMP_HANDOFF_REPO" "$HANDOFF_BRANCH" 2>&1)"
handoff_nolink_exit=$?
assert_handoff_backlog_branch "12d" "$handoff_nolink_output" "$handoff_nolink_exit" \
  "$HANDOFF_MSG_MISSING" "$HANDOFF_MSG_NOT_LINK" "$HANDOFF_MSG_BROKEN"

echo ""
echo "--- 12e. .backlog が壊れたシンボリックリンクのとき、exit 2 で「壊れたリンク」分岐を通る（AC#4） ---"
ln -s "$TMP_HANDOFF_REPO/no-such-target" "$TMP_HANDOFF_REPO/.backlog"
handoff_brokenlink_output="$(cd "$TMP_HANDOFF_REPO" && "$CHECK_HANDOFF_SCRIPT" "$TMP_HANDOFF_REPO" "$HANDOFF_BRANCH" 2>&1)"
handoff_brokenlink_exit=$?
assert_handoff_backlog_branch "12e" "$handoff_brokenlink_output" "$handoff_brokenlink_exit" \
  "$HANDOFF_MSG_BROKEN" "$HANDOFF_MSG_MISSING" "$HANDOFF_MSG_NOT_LINK"
rm -f "$TMP_HANDOFF_REPO/.backlog"
ln -s "$TMP_HANDOFF_REPO" "$TMP_HANDOFF_REPO/.backlog"

echo ""
echo "--- 12f. .backlog がシンボリックリンクではなく実体のディレクトリのとき、exit 2 で「シンボリックリンクではない」分岐を通る（AC#4） ---"
rm "$TMP_HANDOFF_REPO/.backlog"
mkdir "$TMP_HANDOFF_REPO/.backlog"
handoff_realdir_output="$(cd "$TMP_HANDOFF_REPO" && "$CHECK_HANDOFF_SCRIPT" "$TMP_HANDOFF_REPO" "$HANDOFF_BRANCH" 2>&1)"
handoff_realdir_exit=$?
assert_handoff_backlog_branch "12f" "$handoff_realdir_output" "$handoff_realdir_exit" \
  "$HANDOFF_MSG_NOT_LINK" "$HANDOFF_MSG_MISSING" "$HANDOFF_MSG_BROKEN"
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
