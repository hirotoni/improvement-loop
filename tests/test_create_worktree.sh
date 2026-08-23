#!/usr/bin/env bash
# tests/test_create_worktree.sh
#
# claude-skills/improvement-dispatch/scripts/create-worktree に対するテスト
# （既定の worktree_base_dir・カスタム worktree_base_dir の両方）。単体で
# 実行すると、このファイルの検証だけが走る。tests/run.sh から全体実行の
# 一部としても呼ばれる。
#
# 依存は bash/zsh・git・backlog のみ。いずれか欠けていれば、その旨を
# 報告してスキップする（テスト対象の不具合として失敗にはしない）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 9. claude-skills/improvement-dispatch/scripts/create-worktree の動作確認 ==="
# claude-skills/improvement-dispatch/SKILL.md 手順5から切り出したワークツリー
# 作成スクリプトを、実際に一時 git リポジトリに対して実行して検証する。
# git init の既定ブランチ名は環境（init.defaultBranch）によって異なりうるため、
# main を明示して作成し、claude-skills/improvement-dispatch/scripts/create-worktree 内のデフォルトブランチ判定
# （フェッチ不可時に main へフォールバック）と整合させる。

TMP_CW_REPO="$(mktemp -d)"
# macOS では mktemp -d が返すパス（/var/...）がシンボリックリンクであり、
# claude-skills/improvement-dispatch/scripts/create-worktree 内部の pwd -P による正規化後（/private/var/...）と
# 文字列比較が一致しない。ここでも同じ正規化をしておく。
TMP_CW_REPO="$(cd "$TMP_CW_REPO" && pwd -P)"
register_tmp_cleanup "$TMP_CW_REPO"

(cd "$TMP_CW_REPO" && git init -q -b main && git commit -q --allow-empty -m init)

CW_TASK_ID="task-77-worktree-check"
CW_EXPECTED_WORKTREE_DIR="$TMP_CW_REPO/.worktree/$(basename "$TMP_CW_REPO")/$CW_TASK_ID"
CW_EXPECTED_BRANCH="improvement/$CW_TASK_ID"

cw_output1="$(cd "$TMP_CW_REPO" && "$CREATE_WORKTREE_SCRIPT" "$CW_TASK_ID" 2>&1)"
cw_exit1=$?
if [ "$cw_exit1" -eq 0 ]; then
  pass "1回目の claude-skills/improvement-dispatch/scripts/create-worktree 実行が成功する（exit 0）"
else
  fail "1回目の claude-skills/improvement-dispatch/scripts/create-worktree 実行が失敗した（exit ${cw_exit1}）:
$cw_output1"
fi

if printf '%s\n' "$cw_output1" | grep -Fxq "WORKTREE_DIR=$CW_EXPECTED_WORKTREE_DIR"; then
  pass "既定の worktree_base_dir（リポジトリルート配下の .worktree/、リポジトリ名で名前空間分け）配下に想定通りのパスが出力される"
else
  fail "WORKTREE_DIR の出力が想定と異なる。期待: WORKTREE_DIR=$CW_EXPECTED_WORKTREE_DIR, 実際の出力:
$cw_output1"
fi

if printf '%s\n' "$cw_output1" | grep -Fxq "BRANCH=$CW_EXPECTED_BRANCH"; then
  pass "BRANCH が想定通り出力される（${CW_EXPECTED_BRANCH}）"
else
  fail "BRANCH の出力が想定と異なる。期待: BRANCH=$CW_EXPECTED_BRANCH, 実際の出力:
$cw_output1"
fi

if [ -d "$CW_EXPECTED_WORKTREE_DIR" ]; then
  pass "想定したパスにワークツリーディレクトリが実在する"
else
  fail "想定したパスにワークツリーディレクトリが存在しない: $CW_EXPECTED_WORKTREE_DIR"
fi

if git -C "$TMP_CW_REPO" worktree list --porcelain | grep -Fxq "worktree $CW_EXPECTED_WORKTREE_DIR"; then
  pass "git worktree list にワークツリーが登録されている"
else
  fail "git worktree list にワークツリーが登録されていない"
fi

if grep -Fxq ".backlog" "$TMP_CW_REPO/.git/info/exclude" 2>/dev/null; then
  pass ".git/info/exclude に .backlog が追記されている"
else
  fail ".git/info/exclude に .backlog が追記されていない"
fi

# ---- AC#2: 既定の worktree_base_dir（リポジトリルート配下の .worktree/）は
# リポジトリ内を指すため、.git/info/exclude に .worktree が自動追記され、
# git status に汚れとして現れないこと ----
if grep -Fxq ".worktree" "$TMP_CW_REPO/.git/info/exclude" 2>/dev/null; then
  pass "既定の worktree_base_dir（リポジトリルート配下の .worktree/）が .git/info/exclude に追記されている"
else
  fail "既定の worktree_base_dir（.worktree）が .git/info/exclude に追記されていない"
fi

if [ -z "$(git -C "$TMP_CW_REPO" status --porcelain)" ]; then
  pass "既定パスにワークツリーを作成しても、元のリポジトリの git status が汚れない"
else
  fail "既定パスにワークツリーを作成すると、元のリポジトリの git status が汚れる:
$(git -C "$TMP_CW_REPO" status --porcelain)"
fi

# ---- 冪等性（AC#3）: 同じ task-id で2回目を実行しても、エラーにならず
# 既存のワークツリー/ブランチを再利用する ----
cw_output2="$(cd "$TMP_CW_REPO" && "$CREATE_WORKTREE_SCRIPT" "$CW_TASK_ID" 2>&1)"
cw_exit2=$?
if [ "$cw_exit2" -eq 0 ]; then
  pass "2回目の claude-skills/improvement-dispatch/scripts/create-worktree 実行（同じ task-id）が成功する（exit 0、冪等性）"
else
  fail "2回目の claude-skills/improvement-dispatch/scripts/create-worktree 実行が失敗した（exit ${cw_exit2}）:
$cw_output2"
fi

if printf '%s\n' "$cw_output2" | grep -Fxq "WORKTREE_DIR=$CW_EXPECTED_WORKTREE_DIR" && \
   printf '%s\n' "$cw_output2" | grep -Fxq "BRANCH=$CW_EXPECTED_BRANCH"; then
  pass "2回目の実行でも同じ WORKTREE_DIR/BRANCH が出力される（既存のワークツリー/ブランチを再利用）"
else
  fail "2回目の実行で WORKTREE_DIR/BRANCH の出力が変わった:
$cw_output2"
fi

cw_worktree_count="$(git -C "$TMP_CW_REPO" worktree list --porcelain | grep -Fxc "worktree $CW_EXPECTED_WORKTREE_DIR")"
if [ "$cw_worktree_count" = "1" ]; then
  pass "2回目の実行後もワークツリーが重複登録されていない"
else
  fail "2回目の実行後、ワークツリーが重複登録されている（${cw_worktree_count} 件）"
fi

cw_exclude_count="$(grep -Fxc ".backlog" "$TMP_CW_REPO/.git/info/exclude" 2>/dev/null || true)"
if [ "$cw_exclude_count" = "1" ]; then
  pass "2回目の実行後も .git/info/exclude の .backlog 行が重複していない"
else
  fail "2回目の実行後、.git/info/exclude の .backlog 行が重複している（${cw_exclude_count} 件）"
fi

# ---- 復旧シナリオ: ワークツリーのディレクトリだけ消え、ブランチは残っている
# 場合、新規作成せず既存ブランチを割り当てて再作成する ----
rm -rf "$CW_EXPECTED_WORKTREE_DIR"
cw_output3="$(cd "$TMP_CW_REPO" && "$CREATE_WORKTREE_SCRIPT" "$CW_TASK_ID" 2>&1)"
cw_exit3=$?
if [ "$cw_exit3" -eq 0 ] && [ -d "$CW_EXPECTED_WORKTREE_DIR" ]; then
  pass "ワークツリーのディレクトリのみ消えた状態からの再実行が成功し、既存ブランチで再作成される"
else
  fail "ワークツリーのディレクトリのみ消えた状態からの再実行が失敗した（exit ${cw_exit3}）:
$cw_output3"
fi

cw_branch_count="$(git -C "$TMP_CW_REPO" branch --list "$CW_EXPECTED_BRANCH" | wc -l | tr -d ' ')"
if [ "$cw_branch_count" = "1" ]; then
  pass "復旧後もブランチ $CW_EXPECTED_BRANCH が重複作成されていない"
else
  fail "復旧後、ブランチ $CW_EXPECTED_BRANCH が重複している（${cw_branch_count} 件）"
fi

# ---- 引数の妥当性検証 ----
if "$CREATE_WORKTREE_SCRIPT" >/dev/null 2>&1; then
  fail "引数無しで claude-skills/improvement-dispatch/scripts/create-worktree を実行してもエラーにならない"
else
  pass "引数無しで claude-skills/improvement-dispatch/scripts/create-worktree を実行するとエラーになる"
fi

if "$CREATE_WORKTREE_SCRIPT" "Invalid_Task_ID!" >/dev/null 2>&1; then
  fail "不正な形式の task-id を渡してもエラーにならない"
else
  pass "不正な形式の task-id を渡すとエラーになる"
fi

echo ""
echo "=== 10. claude-skills/improvement-dispatch/scripts/create-worktree の worktree_base_dir カスタム設定での動作確認 ==="
# TASK-13 で導入された improvement_loop.worktree_base_dir の判定ロジック
# （リポジトリ内相対パスの解決・.git/info/exclude への追記）が、
# claude-skills/improvement-dispatch/scripts/create-worktree へ切り出した後も維持されていることを確認する。

TMP_CW_BASEDIR_REPO="$(mktemp -d)"
register_tmp_cleanup "$TMP_CW_BASEDIR_REPO"

(cd "$TMP_CW_BASEDIR_REPO" && git init -q -b main && git commit -q --allow-empty -m init)
mkdir -p "$TMP_CW_BASEDIR_REPO/.backlog"
cat > "$TMP_CW_BASEDIR_REPO/.backlog/config.my.yml" <<'YAML'
improvement_loop:
  worktree_base_dir: ".worktree-custom"
YAML

CW_BASEDIR_TASK_ID="task-88-custom-basedir"
CW_BASEDIR_EXPECTED_DIR="$TMP_CW_BASEDIR_REPO/.worktree-custom/$(basename "$TMP_CW_BASEDIR_REPO")/$CW_BASEDIR_TASK_ID"

cw_basedir_output="$(cd "$TMP_CW_BASEDIR_REPO" && "$CREATE_WORKTREE_SCRIPT" "$CW_BASEDIR_TASK_ID" 2>&1)"
cw_basedir_exit=$?
if [ "$cw_basedir_exit" -eq 0 ]; then
  pass "worktree_base_dir をリポジトリ内の相対パスに設定した状態での実行が成功する（exit 0）"
else
  fail "worktree_base_dir をリポジトリ内の相対パスに設定した状態での実行が失敗した（exit ${cw_basedir_exit}）:
$cw_basedir_output"
fi

if [ -d "$CW_BASEDIR_EXPECTED_DIR" ]; then
  pass "worktree_base_dir で指定したリポジトリ内相対パス配下にワークツリーが作成される"
else
  fail "worktree_base_dir で指定したパス配下にワークツリーが作成されていない: $CW_BASEDIR_EXPECTED_DIR"
fi

if grep -Fxq ".worktree-custom" "$TMP_CW_BASEDIR_REPO/.git/info/exclude" 2>/dev/null; then
  pass "リポジトリ内を指す worktree_base_dir が .git/info/exclude に追記される"
else
  fail "worktree_base_dir（.worktree-custom）が .git/info/exclude に追記されていない"
fi

finish_tests
