#!/usr/bin/env bash
# claude-code/skills/improvement-dispatch/scripts/create-worktree に対するテスト
# （既定の worktree_base_dir・カスタム worktree_base_dir の両方）。
#
# 占有記録（.worktree-occupancy）の書式（3行・ISO8601・epoch）は bin/lib/occupancy.sh が
# 決め、tests/test_touch_occupancy.sh で検査する。ここでは create-worktree が正しい
# TASK_ID で書くこと、再利用・復旧の経路で書き直すことだけを確かめる。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

# ---- フィクスチャとアサーションのヘルパー ----
# cw_new_repo <変数名> [<デフォルトブランチ名>] [<親ディレクトリ内の名前>]
#   空コミット1つの一時リポジトリを作り、正規化した絶対パスを変数に入れる。
#   macOS の mktemp -d はシンボリックリンク経由のパスを返し、create-worktree 内部の
#   pwd -P による正規化後と一致しないため、ここで同じ正規化をしておく。
#   3番目の引数を渡すと、一時ディレクトリの中にその名前のリポジトリを作る。
#   $(...) の中で作ると register_tmp_cleanup の登録がサブシェルごと消えるので、
#   結果は printf -v で呼び出し側の変数に入れる。
cw_new_repo() {
  local var="$1" branch="${2:-main}" name="${3:-}" dir
  dir="$(mktemp -d)"
  dir="$(cd "$dir" && pwd -P)"
  register_tmp_cleanup "$dir"
  if [ -n "$name" ]; then
    dir="$dir/$name"
    mkdir -p "$dir"
  fi
  (cd "$dir" && git init -q -b "$branch" && git commit -q --allow-empty -m init)
  printf -v "$var" '%s' "$dir"
}

# cw_worktree_dir <リポジトリ> <task-id>: 既定の worktree_base_dir での想定パスを出す。
cw_worktree_dir() {
  printf '%s/.worktree/%s/%s\n' "$1" "$(basename "$1")" "$2"
}

# cw_run <リポジトリ> <引数...>: 標準出力と標準エラーを RUN_OUT に取る。
cw_run() {
  local repo="$1"
  shift
  run_in "$repo" "$CREATE_WORKTREE_SCRIPT" "$@"
}

# cw_run_stdout <リポジトリ> <引数...>: 標準出力だけを RUN_OUT に取る。行位置で出力契約を
# 確かめる節で使う。git worktree add が標準エラーに出す進捗が混ざると判定できないためである。
cw_run_stdout() {
  local repo="$1"
  shift
  RUN_OUT="$(cd "$repo" && "$CREATE_WORKTREE_SCRIPT" "$@" 2>/dev/null)"
  RUN_EXIT=$?
  ASSERT_DETAIL="exit ${RUN_EXIT}:
$RUN_OUT"
}

echo "=== 9. claude-code/skills/improvement-dispatch/scripts/create-worktree の動作確認 ==="
# 一時 git リポジトリに対して実際に実行して検証する。git init の既定ブランチ名は
# init.defaultBranch によって異なりうるため main を明示して作成し、create-worktree の
# デフォルトブランチ判定（フェッチ不可時に main へフォールバック）と整合させる。

cw_new_repo TMP_CW_REPO
CW_TASK_ID="task-77-worktree-check"
CW_EXPECTED_WORKTREE_DIR="$(cw_worktree_dir "$TMP_CW_REPO" "$CW_TASK_ID")"
CW_EXPECTED_BRANCH="improvement/$CW_TASK_ID"
CW_EXCLUDE_FILE="$TMP_CW_REPO/.git/info/exclude"
CW_OCCUPANCY_FILE="$CW_EXPECTED_WORKTREE_DIR/.worktree-occupancy"

cw_run "$TMP_CW_REPO" "$CW_TASK_ID"
assert "1回目の create-worktree 実行が成功する（exit 0）" run_result 0
assert "既定の worktree_base_dir（リポジトリルート配下の .worktree/、リポジトリ名で名前空間分け）配下に想定通りのパスが出力される" \
  has_line "$RUN_OUT" "WORKTREE_DIR=$CW_EXPECTED_WORKTREE_DIR"
assert "BRANCH が想定通り出力される（${CW_EXPECTED_BRANCH}）" has_line "$RUN_OUT" "BRANCH=$CW_EXPECTED_BRANCH"
assert "想定したパスにワークツリーディレクトリが実在する" [ -d "$CW_EXPECTED_WORKTREE_DIR" ]
assert "git worktree list にワークツリーが登録されている" \
  has_line "$(git -C "$TMP_CW_REPO" worktree list --porcelain)" "worktree $CW_EXPECTED_WORKTREE_DIR"
assert ".git/info/exclude に .backlog が追記されている" grep -Fxq ".backlog" "$CW_EXCLUDE_FILE"

# ---- 新規ワークツリー作成時に、割り当てタスクIDを含む占有記録が作成される ----
assert "占有記録ファイル(.worktree-occupancy)がワークツリー直下に作成される（AC#1）" [ -f "$CW_OCCUPANCY_FILE" ]
assert "占有記録に割り当てタスクIDが記録される（AC#1）" grep -Fxq "TASK_ID=$CW_TASK_ID" "$CW_OCCUPANCY_FILE"
assert ".git/info/exclude に .worktree-occupancy が追記されている（AC#3）" grep -Fxq ".worktree-occupancy" "$CW_EXCLUDE_FILE"

# ---- 既定の worktree_base_dir はリポジトリ内を指すため .git/info/exclude に
# .worktree が自動追記され、git status に汚れとして現れないこと ----
assert "既定の worktree_base_dir（リポジトリルート配下の .worktree/）が .git/info/exclude に追記されている" \
  grep -Fxq ".worktree" "$CW_EXCLUDE_FILE"
assert "既定パスにワークツリーを作成しても、元のリポジトリの git status が汚れない" \
  [ -z "$(git -C "$TMP_CW_REPO" status --porcelain)" ]

# ---- 冪等性: 同じ task-id で2回目を実行しても、エラーにならず既存の
# ワークツリー/ブランチを再利用し、占有記録を書き直す ----
# sleep で時刻を進める代わりに、古い時刻の占有記録を先に書いておく。
CW_OLD_EPOCH=1
printf 'TASK_ID=%s\nASSIGNED_AT=1970-01-01T00:00:01Z\nASSIGNED_AT_EPOCH=%s\n' "$CW_TASK_ID" "$CW_OLD_EPOCH" > "$CW_OCCUPANCY_FILE"
cw_run "$TMP_CW_REPO" "$CW_TASK_ID"
assert "2回目の create-worktree 実行（同じ task-id）が成功する（exit 0、冪等性）" run_result 0
assert "2回目の実行でも同じ WORKTREE_DIR/BRANCH が出力される（既存のワークツリー/ブランチを再利用）" \
  run_result 0 "WORKTREE_DIR=$CW_EXPECTED_WORKTREE_DIR" "BRANCH=$CW_EXPECTED_BRANCH"
assert "2回目の実行後も .git/info/exclude の .backlog 行が重複していない" \
  [ "$(grep -Fxc ".backlog" "$CW_EXCLUDE_FILE")" = "1" ]
CW_SECOND_EPOCH="$(grep '^ASSIGNED_AT_EPOCH=' "$CW_OCCUPANCY_FILE" 2>/dev/null | cut -d= -f2)"
ASSERT_DETAIL="事前に書いた epoch=${CW_OLD_EPOCH}, 実行後=${CW_SECOND_EPOCH:-なし}"
assert "2回目の実行（同じ task-id での再利用）で占有記録のタイムスタンプが更新される（AC#2）" \
  [ "${CW_SECOND_EPOCH:-0}" -gt "$CW_OLD_EPOCH" ]

# ---- リポジトリのパスに半角スペースを含む場合でも、同一 task-id での
# 2回目の実行が冪等に成功する ----
# porcelain 出力のパースが awk のデフォルトフィールド分割に頼っていると、パスに
# 半角スペースを含む場合に2語目以降が切り捨てられ、2回目の実行が「既に別の内容で
# 存在する」エラーに誤って落ちる。その回帰テストである。
cw_new_repo TMP_CW_SPACE_REPO main "il space repo"
CW_SPACE_TASK_ID="task-66-space-path-idempotency"
CW_SPACE_EXPECTED_WORKTREE_DIR="$(cw_worktree_dir "$TMP_CW_SPACE_REPO" "$CW_SPACE_TASK_ID")"

cw_run "$TMP_CW_SPACE_REPO" "$CW_SPACE_TASK_ID"
assert "パスに半角スペースを含むリポジトリでの1回目の create-worktree 実行が成功する（exit 0）（TASK-55 回帰）" run_result 0
assert "パスに半角スペースを含むリポジトリで想定パスにワークツリーが作成される（TASK-55 回帰）" [ -d "$CW_SPACE_EXPECTED_WORKTREE_DIR" ]
cw_run "$TMP_CW_SPACE_REPO" "$CW_SPACE_TASK_ID"
assert "パスに半角スペースを含むリポジトリで同一 task-id の2回目の実行が成功する（exit 0、AC#1）" run_result 0
assert "パスに半角スペースを含むリポジトリで2回目の実行でも既存のワークツリー/ブランチが再利用される（AC#1）" \
  run_result 0 "WORKTREE_DIR=$CW_SPACE_EXPECTED_WORKTREE_DIR" "BRANCH=improvement/$CW_SPACE_TASK_ID"
assert "パスに半角スペースを含むリポジトリで2回目の実行後もワークツリーが重複登録されていない（AC#1）" \
  [ "$(git -C "$TMP_CW_SPACE_REPO" worktree list --porcelain | grep -Fxc "worktree $CW_SPACE_EXPECTED_WORKTREE_DIR")" = "1" ]

# ---- 復旧シナリオ: ワークツリーのディレクトリだけ消え、ブランチは残っている
# 場合、新規作成せず既存ブランチを割り当てて再作成し、占有記録も作り直す ----
rm -rf "$CW_EXPECTED_WORKTREE_DIR"
cw_run "$TMP_CW_REPO" "$CW_TASK_ID"
assert "ワークツリーのディレクトリのみ消えた状態からの再実行が成功し、既存ブランチで再作成される" \
  [ "$RUN_EXIT $([ -d "$CW_EXPECTED_WORKTREE_DIR" ] && echo dir)" = "0 dir" ]
assert "ディレクトリ消失からの復旧後も占有記録が作り直される" grep -Fxq "TASK_ID=$CW_TASK_ID" "$CW_OCCUPANCY_FILE"

# ---- 引数の妥当性検証 ----
# 検証が壊れると create-worktree はカレントディレクトリのリポジトリに worktree と
# ブランチを作るため、専用の一時リポジトリ内で実行する（テストを実行した本体
# リポジトリを汚さない）。終了コードの非ゼロだけでは別の理由の失敗と区別できない
# ので、検証固有のメッセージと、worktree・ブランチが増えていないことも確かめる。
cw_new_repo TMP_CW_ARGS_REPO

cw_args_refs_snapshot() {
  git -C "$TMP_CW_ARGS_REPO" worktree list --porcelain
  git -C "$TMP_CW_ARGS_REPO" branch --list
}

# 引数: <ケース名> <期待する標準エラーの部分文字列> [create-worktree に渡す引数...]
check_cw_rejects_args() {
  local label="$1" expected_msg="$2" before after
  shift 2
  before="$(cw_args_refs_snapshot)"
  # エラーが標準エラーに出ることまで確かめるため、標準エラーだけを取る。
  RUN_OUT="$(cd "$TMP_CW_ARGS_REPO" && "$CREATE_WORKTREE_SCRIPT" "$@" 2>&1 >/dev/null)"
  RUN_EXIT=$?
  ASSERT_DETAIL="exit ${RUN_EXIT}, 標準エラー:
$RUN_OUT"
  assert "${label}で create-worktree を実行すると、引数の検証でエラーになる（標準エラーに エラー: ${expected_msg}）" \
    run_result_text nz "エラー: $expected_msg"
  after="$(cw_args_refs_snapshot)"
  ASSERT_DETAIL="実行前:
$before
実行後:
$after"
  assert "${label}で create-worktree を実行しても、worktree とブランチが作られない" [ "$before" = "$after" ]
}

check_cw_rejects_args "引数無し" "使い方: "
check_cw_rejects_args "不正な形式の task-id（Invalid_Task_ID!）" "task-id の形式が不正: " "Invalid_Task_ID!"

echo ""
echo "=== 9b. BASE_REF 起因の worktree add 失敗（リモート未設定・デフォルトブランチが main 以外）の動作確認（TASK-38） ==="
# リモート未設定かつローカルのデフォルトブランチが "main" 以外のリポジトリでは、
# フォールバックにより BASE_REF="main" になるが、その "main" は実在しない。この場合に
# 生の git エラーで異常終了せず、err() 形式の診断と明示的な exit code（1）で終わることを
# 確認する。main フォールバック自体は変更しないので BASE_REF="main" になること自体は妨げない。
cw_new_repo TMP_CW_NOMAIN_REPO master
CW_NOMAIN_TASK_ID="task-99-no-main-branch"
cw_run "$TMP_CW_NOMAIN_REPO" "$CW_NOMAIN_TASK_ID"
assert "デフォルトブランチが main 以外でリモート未設定の場合、明示的な exit code（1）で終了する" run_result 1
assert "err() 形式の診断メッセージ（\"エラー: \" プレフィックス）が標準エラーに出る" has_text "$RUN_OUT" "エラー: "
assert_not "生の git エラー（\"fatal:\"）が出力されていない" grep -Fiq "fatal:" <<<"$RUN_OUT"
assert "ワークツリー作成に失敗した場合、想定パスにディレクトリが作られない" \
  [ ! -d "$(cw_worktree_dir "$TMP_CW_NOMAIN_REPO" "$CW_NOMAIN_TASK_ID")" ]

echo ""
echo "=== 9b-2. BASE_REF 以外の理由による worktree add 失敗の動作確認（TASK-87） ==="
# 9b と対になるセクション。BASE_REF（ここでは実在する main）は解決できるのに worktree add が
# 失敗するケースでは、9b と同じ「BASE_REF の解決に失敗した」という断定ではなく、git 自身が
# 出した実際の失敗理由が利用者に届く必要がある。
#
# 再現手段: 冪等性ガードは `[ -d "$WORKTREE_DIR" ]` で既存ディレクトリだけを見るので、
# 同じパスに通常ファイルを置くとガードをすり抜けて新規作成分岐に落ち、git が
# "already exists" で失敗する。
cw_new_repo TMP_CW_COLLIDE_REPO
CW_COLLIDE_TASK_ID="task-87-worktree-path-collision"
CW_COLLIDE_WORKTREE_DIR="$(cw_worktree_dir "$TMP_CW_COLLIDE_REPO" "$CW_COLLIDE_TASK_ID")"
mkdir -p "$(dirname "$CW_COLLIDE_WORKTREE_DIR")"
: > "$CW_COLLIDE_WORKTREE_DIR"
cw_run "$TMP_CW_COLLIDE_REPO" "$CW_COLLIDE_TASK_ID"
assert "BASE_REF 以外の理由で worktree add が失敗した場合も、明示的な exit code（1）で終了する（AC#1 の扱いを保つ）" run_result 1
assert "BASE_REF 以外の失敗でも err() 形式の診断メッセージが出る" has_text "$RUN_OUT" "エラー: "
assert "git 自身が出した実際の失敗理由（\"already exists\"）が出力に残る（AC#2）" has_text "$RUN_OUT" "already exists"
assert_not "BASE_REF 起因と断定する診断（9b 用のメッセージ）が出ていない（AC#3: 2つの失敗を区別している）" \
  has_text "$RUN_OUT" "の解決に失敗し"

echo ""
echo "=== 9c. git コマンドが PATH に無い環境での動作確認（TASK-58） ==="
# create-worktree の REPO_ROOT="$(git rev-parse --show-toplevel)" が保護されていないと、
# git が PATH に無い環境で生の "command not found"（exit 127）になり、err() 経由の診断も
# 定義済みの終了コードも出ない。git を含まない最小 PATH で実行し、err() 形式の診断と
# 終了コード 1 で終わることを確認する。
#
# この git 呼び出しは引数検証の直後・他の外部コマンドを使う処理より前にあるため、
# PATH には何も置かない空のディレクトリで十分再現できる。bash 自体はフルパスで直接
# 起動するため PATH 解決に依存しない。
cw_new_repo TMP_CW_NOGIT_REPO
CW_EMPTY_PATH_DIR="$(mktemp -d)"
register_tmp_cleanup "$CW_EMPTY_PATH_DIR"
CW_NOGIT_TASK_ID="task-58-no-git-in-path"
run_in "$TMP_CW_NOGIT_REPO" env PATH="$CW_EMPTY_PATH_DIR" "$(command -v bash)" "$CREATE_WORKTREE_SCRIPT" "$CW_NOGIT_TASK_ID"
assert "git が PATH に無い場合、定義済みの終了コード（1）で終了する（生の command not found なら 127）（AC#1）" run_result 1
assert "git が PATH に無い場合、err() 形式の診断メッセージ（\"エラー: \" プレフィックス）が出る（AC#1）" has_text "$RUN_OUT" "エラー: "
assert_not "生の \"command not found\" がそのまま出力されていない（err() 経由のメッセージに包まれている）" \
  grep -Eq '^[^エ]*command not found' <<<"$RUN_OUT"
assert "git が PATH に無い場合、想定パスにワークツリーディレクトリが作られない" \
  [ ! -d "$(cw_worktree_dir "$TMP_CW_NOGIT_REPO" "$CW_NOGIT_TASK_ID")" ]

echo ""
echo "=== 9d. 起点（BASE_REF）の決定と鮮度検査（TASK-75） ==="
# 9/9b/9c の一時リポジトリはリモート未設定なので `git fetch origin` が必ず失敗し、
# origin 起点の経路が一度も実行されない。ここでは疑似 origin（同じ一時ディレクトリ内の
# bare リポジトリ）を持つリポジトリを組み立て、auto_merge_reviewed の値とローカル/origin の
# 包含関係の組み合わせごとに、起点の選択と STALE_BASE の検知を確認する。
#
# ここでの `git push` は疑似 origin へのフィクスチャの組み立てであり、create-worktree 自身が
# push しないという制約とは別物である。
#
# このセクションの実行結果は cw_run_stdout で標準出力だけを取る。RESULT が1行目である・
# WORKTREE_DIR/BRANCH が最後の2行であるという出力契約を行位置で検証するためである。

# 疑似 origin を持つ一時リポジトリを作り、そのローカル側の絶対パスを変数に入れる。
#   $1 = 変数名
#   $2 = ローカルリポジトリのディレクトリ名
#   $3 = config.my.yml に書く auto_merge_reviewed の値
#        （空文字ならキー自体を書かない＝既定値の経路を通す）
cw_make_remote_repo() {
  local var="$1" dir_name="$2" amr="$3" parent
  parent="$(mktemp -d)"
  parent="$(cd "$parent" && pwd -P)"
  register_tmp_cleanup "$parent"
  git init -q --bare -b main "$parent/origin.git"
  git init -q -b main "$parent/$dir_name"
  (
    cd "$parent/$dir_name" || exit 1
    git remote add origin "$parent/origin.git"
    mkdir -p .backlog
    if [ -n "$amr" ]; then
      printf 'improvement_loop:\n  auto_merge_reviewed: %s\n' "$amr" > .backlog/config.my.yml
    else
      printf 'improvement_loop:\n  worktree_base_dir: ""\n' > .backlog/config.my.yml
    fi
    echo "v1" > file.txt
    git add file.txt
    git commit -qm "A: 初期"
    git push -q origin main
    git remote set-head origin main
  ) >/dev/null 2>&1
  printf -v "$var" '%s' "$parent/$dir_name"
}

# ローカルのデフォルトブランチを動かさずに origin/main だけを1コミット進める
# （別クローン経由で push し、元のリポジトリで fetch する）。
cw_advance_origin() {
  local repo="$1"
  local clone="${repo}.remote-clone"
  rm -rf "$clone"
  git clone -q "$repo/../origin.git" "$clone" >/dev/null 2>&1
  (
    cd "$clone" || exit 1
    echo "リモート側の更新" > remote.txt
    git add remote.txt
    git commit -qm "R: origin 側だけの更新"
    git push -q origin main
  ) >/dev/null 2>&1
  rm -rf "$clone"
  (cd "$repo" && git fetch -q origin) >/dev/null 2>&1
}

# ローカルの main に file.txt を書き換えるコミットを1つ積む（push しない）。
# 引数: <リポジトリ> <file.txt の内容> <コミットの件名>
cw_local_commit() {
  (
    cd "$1" || exit 1
    echo "$2" > file.txt
    git add file.txt
    git commit -qm "$3"
  ) >/dev/null 2>&1
}

# ---- auto_merge_reviewed: true でローカルが先行している場合、
# ローカルのデフォルトブランチを起点にする ----
cw_make_remote_repo CW_AHEAD_REPO local-ahead true
cw_local_commit "$CW_AHEAD_REPO" "v2-先行タスクの成果" "B: 先行タスクの成果（push しない）"
CW_AHEAD_TASK_ID="task-75-local-ahead"
CW_AHEAD_WORKTREE="$(cw_worktree_dir "$CW_AHEAD_REPO" "$CW_AHEAD_TASK_ID")"
cw_run_stdout "$CW_AHEAD_REPO" "$CW_AHEAD_TASK_ID"
assert "auto_merge_reviewed: true でローカルが先行している場合、起点がローカルの main になる（AC#1）" \
  has_line "$RUN_OUT" "BASE_REF=main"
assert "ローカルの main にしか無い先行タスクの成果がワークツリーに入っている（AC#1）" \
  [ "$(cat "$CW_AHEAD_WORKTREE/file.txt" 2>/dev/null)" = "v2-先行タスクの成果" ]
assert "起点が保証できている場合は1行目に RESULT: OK を出す（AC#2）" first_line_is "RESULT: OK"
assert "診断行を追加しても、標準出力の最後の2行が WORKTREE_DIR/BRANCH である契約が保たれている" \
  last_lines_are "WORKTREE_DIR=$CW_AHEAD_WORKTREE" "BRANCH=improvement/$CW_AHEAD_TASK_ID"

# ---- 既存ブランチを再利用する経路（再引き渡し）で、そのブランチが
# 起点の先端を含まない場合に STALE_BASE として検知する ----
cw_local_commit "$CW_AHEAD_REPO" "v3-別の先行タスクの成果" "D: 別の先行タスクの成果"
cw_run_stdout "$CW_AHEAD_REPO" "$CW_AHEAD_TASK_ID"
assert "既存ブランチの再利用で起点の先端を含まない場合、RESULT: STALE_BASE を出す（AC#2）" first_line_is "RESULT: STALE_BASE"
assert "STALE_BASE の理由と、含まれていないコミット数を出力する（AC#2）" \
  run_result 0 "STALE_REASON=reused_branch_behind_base" "MISSING_COMMITS=main:1"
assert "STALE_BASE でも終了ステータスは 0 のまま（引き渡しを機械的に止めず、判断は dispatch に委ねる）" run_result 0

# ---- auto_merge_reviewed: true でも、ローカルが origin より古い場合は
# origin/<デフォルトブランチ> から分岐する ----
cw_make_remote_repo CW_BEHIND_REPO local-behind true
cw_advance_origin "$CW_BEHIND_REPO"
CW_BEHIND_TASK_ID="task-75-local-behind"
cw_run_stdout "$CW_BEHIND_REPO" "$CW_BEHIND_TASK_ID"
assert "ローカルが origin より古い場合、auto_merge_reviewed: true でも origin/main を起点にする（AC#3）" \
  has_line "$RUN_OUT" "BASE_REF=origin/main"
assert "origin にしか無い最新コミットがワークツリーに入っている（AC#3）" \
  [ -f "$(cw_worktree_dir "$CW_BEHIND_REPO" "$CW_BEHIND_TASK_ID")/remote.txt" ]

# ---- ローカルと origin が分岐している場合、どちらを起点にしても
# 片方のコミットが欠けるため STALE_BASE として検知する ----
cw_make_remote_repo CW_DIVERGED_REPO local-diverged true
cw_advance_origin "$CW_DIVERGED_REPO"
cw_local_commit "$CW_DIVERGED_REPO" "v2-ローカル側だけの変更" "L: ローカル側だけの変更"
cw_run_stdout "$CW_DIVERGED_REPO" task-75-diverged
assert "ローカルと origin が分岐している場合、RESULT: STALE_BASE と分岐の理由を出す（AC#2）" \
  run_result 0 "RESULT: STALE_BASE" "STALE_REASON=diverged_default_branch"
assert "分岐時に RESULT: STALE_BASE を1行目に出す（AC#2）" first_line_is "RESULT: STALE_BASE"
assert "分岐時に、起点へ含められなかった側のコミット数を出力する（AC#2）" has_line "$RUN_OUT" "MISSING_COMMITS=origin/main:1"

# ---- auto_merge_reviewed: false（PR 運用）では、ローカルが先行していても
# origin/<デフォルトブランチ> 起点のままである ----
cw_make_remote_repo CW_PR_REPO pr-mode false
cw_local_commit "$CW_PR_REPO" "v2-未 push のローカルコミット" "B: 未 push のローカルコミット"
CW_PR_TASK_ID="task-75-pr-mode"
cw_run_stdout "$CW_PR_REPO" "$CW_PR_TASK_ID"
assert "auto_merge_reviewed: false ではローカルが先行していても origin/main 起点のまま（AC#4）" \
  has_line "$RUN_OUT" "BASE_REF=origin/main"
assert "auto_merge_reviewed: false では未 push のローカルコミットがワークツリーに混ざらない（AC#4）" \
  [ "$(cat "$(cw_worktree_dir "$CW_PR_REPO" "$CW_PR_TASK_ID")/file.txt" 2>/dev/null)" = "v1" ]
assert "auto_merge_reviewed: false ではローカルの先行を STALE 扱いしない（AC#4）" first_line_is "RESULT: OK"

# ---- auto_merge_reviewed のキー自体が無い場合（既定値 false）も、
# false を明示した場合と同じ挙動になる ----
cw_make_remote_repo CW_DEFAULT_REPO default-mode ""
cw_local_commit "$CW_DEFAULT_REPO" "v2-未 push のローカルコミット" "B: 未 push のローカルコミット"
cw_run_stdout "$CW_DEFAULT_REPO" task-75-default-mode
assert "auto_merge_reviewed のキーが無い場合も既定（false）として origin/main 起点になる（AC#4）" \
  has_line "$RUN_OUT" "BASE_REF=origin/main"

# ---- リモート未設定（9/9b/9c と同じ構成）でも RESULT 行が出ることの確認 ----
cw_new_repo TMP_CW_NOREMOTE_REPO
cw_run_stdout "$TMP_CW_NOREMOTE_REPO" task-75-no-remote
assert "リモート未設定のリポジトリでも main 起点で RESULT: OK を出す（既存経路の維持）" \
  run_result 0 "RESULT: OK" "BASE_REF=main"
assert "リモート未設定のリポジトリでも RESULT: OK を1行目に出す" first_line_is "RESULT: OK"

# ---- 本体に .backlog がある場合、ワークツリー内の .backlog は本体の .backlog を
# 指すシンボリックリンクになる（TASK-104。readlink はシンボリックリンクでなければ何も出さない）。リンクが無いとワークツリー内の
# improvement-work が backlog CLI でタスクを読み書きできない。上の「ローカルが先行
# している場合」で新規ブランチとして作ったワークツリーを使う（既存ブランチを割り当てる
# 経路は下の branch_behind_default_branch の検証で確かめる） ----
ASSERT_DETAIL="$(ls -ld "$CW_AHEAD_WORKTREE/.backlog" 2>&1)"
assert "ワークツリー内の .backlog が本体の .backlog を指すシンボリックリンクになっている" \
  [ "$(readlink "$CW_AHEAD_WORKTREE/.backlog")" = "$CW_AHEAD_REPO/.backlog" ]
assert "ワークツリー内の .backlog 越しに本体の config.my.yml が読める" \
  cmp -s "$CW_AHEAD_WORKTREE/.backlog/config.my.yml" "$CW_AHEAD_REPO/.backlog/config.my.yml"

# ---- auto_merge_reviewed: true で、再利用した作業ブランチが採用しなかった側の
# 候補（ここでは origin/main）も含まない場合に branch_behind_default_branch を出す
# （TASK-104）。候補どうしは包含関係にあるため、この理由はブランチが起点も含まない
# ときにだけ reused_branch_behind_base と同時に出る ----
cw_make_remote_repo CW_BRANCH_BEHIND_REPO branch-behind true
CW_BRANCH_BEHIND_TASK_ID="task-104-branch-behind"
git -C "$CW_BRANCH_BEHIND_REPO" branch "improvement/$CW_BRANCH_BEHIND_TASK_ID"
cw_local_commit "$CW_BRANCH_BEHIND_REPO" "v2-push 済みの成果" "B: push 済みの成果"
git -C "$CW_BRANCH_BEHIND_REPO" push -q origin main >/dev/null 2>&1
cw_local_commit "$CW_BRANCH_BEHIND_REPO" "v3-未 push の成果" "C: 未 push の成果"
cw_run_stdout "$CW_BRANCH_BEHIND_REPO" "$CW_BRANCH_BEHIND_TASK_ID"
assert "再利用した作業ブランチがローカルの main を含まない場合、reused_branch_behind_base と欠けたコミット数を出す" \
  run_result 0 "RESULT: STALE_BASE" "BASE_REF=main" "STALE_REASON=reused_branch_behind_base" "MISSING_COMMITS=main:2"
assert "再利用した作業ブランチの STALE_BASE を1行目に出す" first_line_is "RESULT: STALE_BASE"
assert "作業ブランチが採用しなかった側のデフォルトブランチ（origin/main）より遅れている場合、STALE_REASON=branch_behind_default_branch と欠けたコミット数を出す" \
  run_result 0 "STALE_REASON=branch_behind_default_branch" "MISSING_COMMITS=origin/main:1"
CW_BRANCH_BEHIND_WORKTREE="$(cw_worktree_dir "$CW_BRANCH_BEHIND_REPO" "$CW_BRANCH_BEHIND_TASK_ID")"
ASSERT_DETAIL="$(ls -ld "$CW_BRANCH_BEHIND_WORKTREE/.backlog" 2>&1)"
assert "既存ブランチを割り当てて作ったワークツリーでも、.backlog が本体の .backlog を指すシンボリックリンクになっている" \
  [ "$(readlink "$CW_BRANCH_BEHIND_WORKTREE/.backlog")" = "$CW_BRANCH_BEHIND_REPO/.backlog" ]

echo ""
echo "=== 10. claude-code/skills/improvement-dispatch/scripts/create-worktree の worktree_base_dir カスタム設定での動作確認 ==="
# worktree_base_dir の判定ロジック（リポジトリ内相対パスの解決・.git/info/exclude への
# 追記）を確認する。

# cw_write_base_dir <リポジトリ> <worktree_base_dir の値>: config.my.yml を書く。
cw_write_base_dir() {
  mkdir -p "$1/.backlog"
  printf 'improvement_loop:\n  worktree_base_dir: "%s"\n' "$2" > "$1/.backlog/config.my.yml"
}

cw_new_repo TMP_CW_BASEDIR_REPO
cw_write_base_dir "$TMP_CW_BASEDIR_REPO" ".worktree-custom"
CW_BASEDIR_TASK_ID="task-88-custom-basedir"
cw_run "$TMP_CW_BASEDIR_REPO" "$CW_BASEDIR_TASK_ID"
assert "worktree_base_dir をリポジトリ内の相対パスに設定した状態での実行が成功する（exit 0）" run_result 0
assert "worktree_base_dir で指定したリポジトリ内相対パス配下にワークツリーが作成される" \
  [ -d "$TMP_CW_BASEDIR_REPO/.worktree-custom/$(basename "$TMP_CW_BASEDIR_REPO")/$CW_BASEDIR_TASK_ID" ]
assert "リポジトリ内を指す worktree_base_dir が .git/info/exclude に追記される" \
  grep -Fxq ".worktree-custom" "$TMP_CW_BASEDIR_REPO/.git/info/exclude"

echo ""
echo "=== 10b. 失効した worktree_base_dir 除外行の検知（TASK-79） ==="
# .git/info/exclude への追記は追記専用なので、worktree_base_dir を変更すると古い値の
# 除外行が残り続ける。create-worktree はマーカーコメント1行で管理対象を記録し、失効を
# 検知して報告する（削除・書き換えはしない）。その検知と、共有物である
# .git/info/exclude の既存行を一切壊さないことを確認する。
cw_new_repo TMP_CW_STALE_REPO
cw_write_base_dir "$TMP_CW_STALE_REPO" ""

# ユーザーが手で書いた行と、他ツール由来の見出し付き行群を先に入れておく。
# 受入基準 #2（これらが変更・削除されないこと）の対象である。
CW_STALE_EXCLUDE_FILE="$TMP_CW_STALE_REPO/.git/info/exclude"
cat >> "$CW_STALE_EXCLUDE_FILE" <<'EXCLUDE'
# interview-dev-loop plan docs
docs/plans/
# claude-code-runtime
**/.claude/scheduled_tasks.lock
my-own-scratch/
EXCLUDE
cp "$CW_STALE_EXCLUDE_FILE" "$TMP_CW_STALE_REPO/exclude.pristine"

# ---- 初回実行: 管理対象の除外行をマーカーコメントとして記録する ----
cw_run_stdout "$TMP_CW_STALE_REPO" task-79-first
cw_stale_out1="$RUN_OUT"
ASSERT_DETAIL="$(cat "$CW_STALE_EXCLUDE_FILE")"
assert "初回実行で管理対象の除外行がマーカーコメントとして .git/info/exclude に記録される" \
  grep -Fxq "# improvement-loop worktree_base_dir added=yes path=.worktree" "$CW_STALE_EXCLUDE_FILE"
assert_not "worktree_base_dir を変更していない初回実行では STALE_EXCLUDE を出力しない" \
  grep -q '^STALE_EXCLUDE=' <<<"$cw_stale_out1"
# bin/setup-improvement-loop の append_git_exclude_lines() は
# grep -Fxq "# improvement-loop"（完全一致）で見出しの有無を判定する。
# マーカー行がその見出しとして誤検知されると、setup 側が見出しを書かなくなる。
assert_not "マーカー行は bin/setup-improvement-loop の見出しコメント '# improvement-loop' とは完全一致しない" \
  grep -Fxq "# improvement-loop" "$CW_STALE_EXCLUDE_FILE"

# ---- worktree_base_dir を変えていない再実行では .git/info/exclude も
#      標準出力も変化しない ----
cp "$CW_STALE_EXCLUDE_FILE" "$TMP_CW_STALE_REPO/exclude.after1"
cw_run_stdout "$TMP_CW_STALE_REPO" task-79-first
assert "worktree_base_dir を変えない再実行では .git/info/exclude が1バイトも変わらない（AC#3）" \
  cmp -s "$TMP_CW_STALE_REPO/exclude.after1" "$CW_STALE_EXCLUDE_FILE"
assert "worktree_base_dir を変えない再実行では標準出力が従来と同じである（AC#3）" [ "$cw_stale_out1" = "$RUN_OUT" ]

# ---- worktree_base_dir を変更した再実行: 失効を検知して報告する ----
cw_write_base_dir "$TMP_CW_STALE_REPO" "tmp-wt"
cw_stale_err_file="$TMP_CW_STALE_REPO/stderr.txt"
RUN_OUT="$(cd "$TMP_CW_STALE_REPO" && "$CREATE_WORKTREE_SCRIPT" task-79-second 2>"$cw_stale_err_file")"
RUN_EXIT=$?
ASSERT_DETAIL="exit ${RUN_EXIT}:
$RUN_OUT
標準エラー:
$(cat "$cw_stale_err_file")"
assert "失効した除外行を検知しても create-worktree は 0 で終了する（引き渡しを止めない）" run_result 0
assert "worktree_base_dir を変更すると、失効した除外行が STALE_EXCLUDE として出力される（AC#1）" \
  has_line "$RUN_OUT" "STALE_EXCLUDE=.worktree:added_by_improvement_loop"
assert "失効した除外行について、標準エラーに人間向けの警告が出る（AC#1）" \
  [ "$(grep '警告' "$cw_stale_err_file" | grep -c '\.worktree')" -ge 1 ]
assert "STALE_EXCLUDE は RESULT: の値を変えない（引き渡しの判断に載せない）" first_line_is "RESULT: OK"
# 末尾2行の値そのものは STALE_EXCLUDE の無い経路で検証済みなので、ここでは
# STALE_EXCLUDE 行が WORKTREE_DIR/BRANCH の2行の直前（末尾から3行目）に出ることを確かめる。
assert "STALE_EXCLUDE 行は WORKTREE_DIR/BRANCH の2行の直前（末尾から3行目）に出る（末尾2行の契約を崩さない）" \
  last_lines_are "STALE_EXCLUDE=.worktree:added_by_improvement_loop" \
    "WORKTREE_DIR=$TMP_CW_STALE_REPO/tmp-wt/$(basename "$TMP_CW_STALE_REPO")/task-79-second" \
    "BRANCH=improvement/task-79-second"

# ---- 既存行が変更・削除されないこと ----
# 起点との差分が追加行だけであることを確認する。削除・書き換えがあれば diff に "<" 行が出る。
ASSERT_DETAIL="$(diff "$TMP_CW_STALE_REPO/exclude.pristine" "$CW_STALE_EXCLUDE_FILE")"
assert_not "ユーザーが書いた行と他ツール由来の行群は変更も削除もされない（追加のみ。AC#2）" \
  grep -q '^< ' <<<"$ASSERT_DETAIL"
# マーカー行は improvement-loop 自身のものなので、現在の値へ更新される。
# 一方で古い除外行 .worktree は残したままである（削除しない）。
ASSERT_DETAIL="$(cat "$CW_STALE_EXCLUDE_FILE")"
assert "マーカー行は増殖せず、現在の worktree_base_dir の値へ更新される" \
  [ "$(grep -E '^# improvement-loop worktree_base_dir added=(yes|no) path=' "$CW_STALE_EXCLUDE_FILE")" \
    = "# improvement-loop worktree_base_dir added=yes path=tmp-wt" ]
assert "失効した除外行そのものは削除されない（報告のみ。AC#2）" grep -Fxq ".worktree" "$CW_STALE_EXCLUDE_FILE"

# ---- worktree_base_dir をリポジトリ外の絶対パスへ移した場合も検知する ----
TMP_CW_STALE_OUTSIDE="$(mktemp -d)"
TMP_CW_STALE_OUTSIDE="$(cd "$TMP_CW_STALE_OUTSIDE" && pwd -P)"
register_tmp_cleanup "$TMP_CW_STALE_OUTSIDE"
cw_write_base_dir "$TMP_CW_STALE_REPO" "$TMP_CW_STALE_OUTSIDE"
cw_run_stdout "$TMP_CW_STALE_REPO" task-79-outside
assert "worktree_base_dir をリポジトリ外の絶対パスへ移した場合も、失効した除外行を検知する（AC#1）" \
  has_line "$RUN_OUT" "STALE_EXCLUDE=tmp-wt:added_by_improvement_loop"

# ---- ユーザーが先に書いていた行は preexisting として報告する ----
# improvement-loop が追記したのではない行は、削除してよいと言い切れない。
# STALE_EXCLUDE の由来欄でその区別を利用者に伝える。
cw_new_repo TMP_CW_PREEXIST_REPO
cw_write_base_dir "$TMP_CW_PREEXIST_REPO" ""
# improvement-loop が触る前に、ユーザーが自分で .worktree を除外している状態。
echo ".worktree" >> "$TMP_CW_PREEXIST_REPO/.git/info/exclude"
cw_run_stdout "$TMP_CW_PREEXIST_REPO" task-79-pre-first
ASSERT_DETAIL="$(cat "$TMP_CW_PREEXIST_REPO/.git/info/exclude")"
assert "improvement-loop が追記していない既存行は added=no として記録される" \
  grep -Fxq "# improvement-loop worktree_base_dir added=no path=.worktree" "$TMP_CW_PREEXIST_REPO/.git/info/exclude"
cw_write_base_dir "$TMP_CW_PREEXIST_REPO" "tmp-wt"
cw_run_stdout "$TMP_CW_PREEXIST_REPO" task-79-pre-second
assert "improvement-loop が追記していない失効行は preexisting として報告される（所有者を断定しない。AC#2）" \
  has_line "$RUN_OUT" "STALE_EXCLUDE=.worktree:preexisting"

finish_tests
