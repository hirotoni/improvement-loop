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

# ---- TASK-40 AC#1: 新規ワークツリー作成時に、割り当てタスクIDと実行時刻を
# 含む占有記録（.worktree-occupancy）が作成される ----
CW_OCCUPANCY_FILE="$CW_EXPECTED_WORKTREE_DIR/.worktree-occupancy"
if [ -f "$CW_OCCUPANCY_FILE" ]; then
  pass "占有記録ファイル(.worktree-occupancy)がワークツリー直下に作成される（AC#1）"
else
  fail "占有記録ファイルが作成されていない: $CW_OCCUPANCY_FILE"
fi

if grep -Fxq "TASK_ID=$CW_TASK_ID" "$CW_OCCUPANCY_FILE" 2>/dev/null; then
  pass "占有記録に割り当てタスクIDが記録される（AC#1）"
else
  fail "占有記録に想定したTASK_IDが記録されていない: $(cat "$CW_OCCUPANCY_FILE" 2>/dev/null)"
fi

if grep -Eq '^ASSIGNED_AT_EPOCH=[0-9]+$' "$CW_OCCUPANCY_FILE" 2>/dev/null; then
  pass "占有記録に実行時刻(ASSIGNED_AT_EPOCH)が数値として記録される（AC#1）"
else
  fail "占有記録にASSIGNED_AT_EPOCHが記録されていない: $(cat "$CW_OCCUPANCY_FILE" 2>/dev/null)"
fi

if grep -Eq '^ASSIGNED_AT=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$CW_OCCUPANCY_FILE" 2>/dev/null; then
  pass "占有記録に実行時刻(ASSIGNED_AT)がISO8601形式で記録される（AC#1）"
else
  fail "占有記録にASSIGNED_AT(ISO8601)が想定形式で記録されていない: $(cat "$CW_OCCUPANCY_FILE" 2>/dev/null)"
fi

# ---- TASK-40 AC#3: 占有記録に対応するパスが .git/info/exclude に登録される ----
if grep -Fxq ".worktree-occupancy" "$TMP_CW_REPO/.git/info/exclude" 2>/dev/null; then
  pass ".git/info/exclude に .worktree-occupancy が追記されている（AC#3）"
else
  fail ".git/info/exclude に .worktree-occupancy が追記されていない（AC#3）"
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
# TASK-40 AC#2 の検証用に、2回目実行前の占有記録の ASSIGNED_AT_EPOCH を控えておく。
# epoch秒（1秒単位）の解像度で「更新された」ことを判別できるよう、1秒待つ。
CW_FIRST_EPOCH="$(grep '^ASSIGNED_AT_EPOCH=' "$CW_OCCUPANCY_FILE" 2>/dev/null | cut -d= -f2)"
sleep 1
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

# ---- TASK-40 AC#2: 既存ワークツリーの再利用時（同じ task-id での再実行）に、
# 占有記録のタイムスタンプが更新され、記録が壊れない ----
CW_SECOND_EPOCH="$(grep '^ASSIGNED_AT_EPOCH=' "$CW_OCCUPANCY_FILE" 2>/dev/null | cut -d= -f2)"
if [ -n "$CW_FIRST_EPOCH" ] && [ -n "$CW_SECOND_EPOCH" ] && [ "$CW_SECOND_EPOCH" -gt "$CW_FIRST_EPOCH" ]; then
  pass "2回目の実行（同じ task-id での再利用）で占有記録のタイムスタンプが更新される（AC#2）"
else
  fail "2回目の実行で占有記録のタイムスタンプが更新されていない: 1回目=${CW_FIRST_EPOCH:-なし}, 2回目=${CW_SECOND_EPOCH:-なし}"
fi

cw_occupancy_taskid_count="$(grep -Fxc "TASK_ID=$CW_TASK_ID" "$CW_OCCUPANCY_FILE" 2>/dev/null || true)"
cw_occupancy_line_count="$(wc -l < "$CW_OCCUPANCY_FILE" 2>/dev/null | tr -d ' ')"
if [ "$cw_occupancy_taskid_count" = "1" ] && [ "$cw_occupancy_line_count" = "3" ]; then
  pass "2回目の実行後も占有記録が壊れていない（TASK_ID行が重複せず、3行のまま）（AC#2）"
else
  fail "2回目の実行後、占有記録が壊れている（TASK_ID行: ${cw_occupancy_taskid_count}件, 総行数: ${cw_occupancy_line_count}）:
$(cat "$CW_OCCUPANCY_FILE" 2>/dev/null)"
fi

# ---- TASK-55 回帰: リポジトリのパスに半角スペースを含む場合でも、
# 同一 task-id での2回目の実行が冪等に成功する ----
# git worktree list --porcelain のパース（既存ワークツリーの割り当てブランチ
# 検出）が awk のデフォルトフィールド分割（$2）に頼っていると、パスに
# 半角スペースを含む場合に2語目以降が切り捨てられ、2回目の実行が
# 「ワークツリーが既に別の内容で存在する」エラー（exit 1）に誤って落ちる
# （TASK-55）。リポジトリ名自体に半角スペースを含む構成で再現する。
TMP_CW_SPACE_PARENT="$(mktemp -d)"
TMP_CW_SPACE_PARENT="$(cd "$TMP_CW_SPACE_PARENT" && pwd -P)"
TMP_CW_SPACE_REPO="$TMP_CW_SPACE_PARENT/il space repo"
mkdir -p "$TMP_CW_SPACE_REPO"
register_tmp_cleanup "$TMP_CW_SPACE_PARENT"

(cd "$TMP_CW_SPACE_REPO" && git init -q -b main && git commit -q --allow-empty -m init)

CW_SPACE_TASK_ID="task-66-space-path-idempotency"
CW_SPACE_EXPECTED_WORKTREE_DIR="$TMP_CW_SPACE_REPO/.worktree/$(basename "$TMP_CW_SPACE_REPO")/$CW_SPACE_TASK_ID"
CW_SPACE_EXPECTED_BRANCH="improvement/$CW_SPACE_TASK_ID"

cw_space_output1="$(cd "$TMP_CW_SPACE_REPO" && "$CREATE_WORKTREE_SCRIPT" "$CW_SPACE_TASK_ID" 2>&1)"
cw_space_exit1=$?
if [ "$cw_space_exit1" -eq 0 ]; then
  pass "パスに半角スペースを含むリポジトリでの1回目の claude-skills/improvement-dispatch/scripts/create-worktree 実行が成功する（exit 0）（TASK-55 回帰）"
else
  fail "パスに半角スペースを含むリポジトリでの1回目の実行が失敗した（exit ${cw_space_exit1}）（TASK-55 回帰）:
$cw_space_output1"
fi

if [ -d "$CW_SPACE_EXPECTED_WORKTREE_DIR" ]; then
  pass "パスに半角スペースを含むリポジトリで想定パスにワークツリーが作成される（TASK-55 回帰）"
else
  fail "パスに半角スペースを含むリポジトリで想定パスにワークツリーが作成されていない: $CW_SPACE_EXPECTED_WORKTREE_DIR（TASK-55 回帰）"
fi

cw_space_output2="$(cd "$TMP_CW_SPACE_REPO" && "$CREATE_WORKTREE_SCRIPT" "$CW_SPACE_TASK_ID" 2>&1)"
cw_space_exit2=$?
if [ "$cw_space_exit2" -eq 0 ]; then
  pass "パスに半角スペースを含むリポジトリで同一 task-id の2回目の実行が成功する（exit 0、AC#1）"
else
  fail "パスに半角スペースを含むリポジトリで2回目の実行が失敗した（exit ${cw_space_exit2}、AC#1）:
$cw_space_output2"
fi

if printf '%s\n' "$cw_space_output2" | grep -Fxq "WORKTREE_DIR=$CW_SPACE_EXPECTED_WORKTREE_DIR" && \
   printf '%s\n' "$cw_space_output2" | grep -Fxq "BRANCH=$CW_SPACE_EXPECTED_BRANCH"; then
  pass "パスに半角スペースを含むリポジトリで2回目の実行でも既存のワークツリー/ブランチが再利用される（AC#1）"
else
  fail "パスに半角スペースを含むリポジトリで2回目の実行時に WORKTREE_DIR/BRANCH の出力が変わった（AC#1）:
$cw_space_output2"
fi

cw_space_worktree_count="$(git -C "$TMP_CW_SPACE_REPO" worktree list --porcelain | grep -Fxc "worktree $CW_SPACE_EXPECTED_WORKTREE_DIR")"
if [ "$cw_space_worktree_count" = "1" ]; then
  pass "パスに半角スペースを含むリポジトリで2回目の実行後もワークツリーが重複登録されていない（AC#1）"
else
  fail "パスに半角スペースを含むリポジトリで2回目の実行後、ワークツリーが重複登録されている（${cw_space_worktree_count} 件）（AC#1）"
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

# ---- TASK-40: ディレクトリ消失からの復旧経路でも占有記録が作り直される ----
if [ -f "$CW_OCCUPANCY_FILE" ] && grep -Fxq "TASK_ID=$CW_TASK_ID" "$CW_OCCUPANCY_FILE" 2>/dev/null; then
  pass "ディレクトリ消失からの復旧後も占有記録が作り直される"
else
  fail "ディレクトリ消失からの復旧後、占有記録が再作成されていない: $CW_OCCUPANCY_FILE"
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
echo "=== 9b. BASE_REF 解決失敗時（リモート未設定・デフォルトブランチが main 以外）の動作確認（TASK-38） ==="
# リモートが設定されておらず、かつローカルのデフォルトブランチが "main" 以外の
# リポジトリでは、140-145行目のフォールバックにより BASE_REF="main" になるが、
# その "main" ブランチは実在しない。この場合に生の git エラー（"fatal:" 等）で
# 異常終了するのではなく、err() 形式の診断メッセージを出して明示的な exit code
# （1）で終了することを確認する。main フォールバック自体（リモート未設定/
# フェッチ失敗時に main を使うこと）は変更しないため、BASE_REF="main" になる
# こと自体は妨げない。

TMP_CW_NOMAIN_REPO="$(mktemp -d)"
TMP_CW_NOMAIN_REPO="$(cd "$TMP_CW_NOMAIN_REPO" && pwd -P)"
register_tmp_cleanup "$TMP_CW_NOMAIN_REPO"

(cd "$TMP_CW_NOMAIN_REPO" && git init -q -b master && git commit -q --allow-empty -m init)

CW_NOMAIN_TASK_ID="task-99-no-main-branch"

cw_nomain_output="$(cd "$TMP_CW_NOMAIN_REPO" && "$CREATE_WORKTREE_SCRIPT" "$CW_NOMAIN_TASK_ID" 2>&1)"
cw_nomain_exit=$?

if [ "$cw_nomain_exit" -eq 1 ]; then
  pass "デフォルトブランチが main 以外でリモート未設定の場合、明示的な exit code（1）で終了する"
else
  fail "デフォルトブランチが main 以外でリモート未設定の場合の exit code が想定と異なる（期待: 1, 実際: ${cw_nomain_exit}):
$cw_nomain_output"
fi

if printf '%s\n' "$cw_nomain_output" | grep -Fq "エラー: "; then
  pass "err() 形式の診断メッセージ（\"エラー: \" プレフィックス）が標準エラーに出る"
else
  fail "err() 形式の診断メッセージが出力されていない:
$cw_nomain_output"
fi

if printf '%s\n' "$cw_nomain_output" | grep -Fiq "fatal:"; then
  fail "生の git エラー（\"fatal:\"）がそのまま出力されている:
$cw_nomain_output"
else
  pass "生の git エラー（\"fatal:\"）が出力されていない"
fi

if [ ! -d "$TMP_CW_NOMAIN_REPO/.worktree/$(basename "$TMP_CW_NOMAIN_REPO")/$CW_NOMAIN_TASK_ID" ]; then
  pass "ワークツリー作成に失敗した場合、想定パスにディレクトリが作られない"
else
  fail "ワークツリー作成に失敗したはずなのに、想定パスにディレクトリが作られている"
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
