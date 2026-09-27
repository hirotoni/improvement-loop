#!/usr/bin/env bash
# claude-code/skills/improvement-dispatch/scripts/merge-reviewed-branch に対するテスト。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 1. claude-code/skills/improvement-dispatch/scripts/merge-reviewed-branch の動作確認 ==="
# 一時 git リポジトリに対して実際に実行し、前提条件未達・ff-only 成功・3-way 衝突無し成功・
# 3-way 衝突・片付けの失敗と再試行などの各ケースを、それぞれ独立した一時リポジトリで確認する。

# ---- 共通の検査（各ケースの結果を表のように並べて書くためのヘルパー） ----
# 引数: <リポジトリ> <ブランチ>。merge-reviewed-branch を実行し、RUN_OUT/RUN_EXIT に結果を入れる。
merge_run() {
  run_in "$1" "$MERGE_SCRIPT" "$2"
}
# 引数: <リポジトリ> <ブランチ>。ブランチが残っていればその名前を、無ければ何も出さない。
branch_name() {
  git -C "$1" branch --list "$2" | tr -d ' *+'
}
# 引数: <ラベル接頭辞> <期待終了コード> <RESULT 行の値>
merge_expect_result() {
  local label="$1" code="$2" result="$3"
  assert "$label: 終了ステータス ${code} (${result}) を返す" run_result "$code"
  assert "$label: 出力に RESULT: ${result} が含まれる" has_text "$RUN_OUT" "RESULT: ${result}"
}
# 引数: <ラベル接頭辞> <リポジトリ> <ブランチ> <デフォルトブランチ> <期待する最新コミットの件名>
# マージ完了後: デフォルトブランチが作業ブランチの内容まで進み、ワークツリーと作業ブランチが片付く。
merge_expect_merged_and_cleaned() {
  local label="$1" repo="$2" branch="$3" default="$4" subject="$5"
  assert "$label: ${default} が ${branch} の内容までマージされている" \
    [ "$(git -C "$repo" log -1 --format=%s "$default")" = "$subject" ]
  assert "$label: マージ完了後、対応するワークツリーが自動で片付けられる" [ ! -d "$repo-wt" ]
  assert "$label: マージ完了後、対応する作業ブランチが自動で削除される（AC#1）" [ -z "$(branch_name "$repo" "$branch")" ]
}

# 引数: <ディレクトリ> [<デフォルトブランチ名>]。空コミット1つのリポジトリを作る。
merge_init_repo() {
  (cd "$1" && git init -q -b "${2:-main}" && git commit -q --allow-empty -m init)
}
# 引数: <リポジトリ> <ブランチ> <コミットの件名>。現在のブランチから <リポジトリ>-wt に
# ワークツリーを作り、空コミットを1つ積む。
merge_add_worktree_with_commit() {
  git -C "$1" worktree add -q -b "$2" "$1-wt" "$(git -C "$1" symbolic-ref --short HEAD)"
  git -C "$1-wt" commit -q --allow-empty -m "$3"
}

echo ""
echo "--- 1a. 前提条件未達: メインの作業木が汚れている ---"
TMP_MERGE_DIRTY="$(mktemp -d)"
register_tmp_cleanup "$TMP_MERGE_DIRTY"
# feature ブランチには main との差分を持たせる。差分が無いと dirty 判定を外しても
# 「差分無し」分岐で同じ PRECONDITION_NOT_MET になり、dirty 分岐を通ったか区別できない。
merge_init_repo "$TMP_MERGE_DIRTY"
(cd "$TMP_MERGE_DIRTY" && git switch -q -c feature-dirty-check \
  && git commit -q --allow-empty -m "feature dirty-check work" && git switch -q main)
merge_dirty_main_before="$(git -C "$TMP_MERGE_DIRTY" rev-parse main)"
assert "1a: 前状態として feature-dirty-check が main との差分（1コミット）を持つ" \
  [ "$(git -C "$TMP_MERGE_DIRTY" rev-list --count main..feature-dirty-check)" -eq 1 ]
echo "uncommitted" > "$TMP_MERGE_DIRTY/dirty.txt"

merge_run "$TMP_MERGE_DIRTY" feature-dirty-check
merge_expect_result "1a: メインの作業木が汚れている場合" 1 PRECONDITION_NOT_MET
assert "1a: dirty 判定の分岐（メインの作業木が汚れている）を通る" has_text "$RUN_OUT" "メインの作業木が汚れている"
assert_not "1a: 「差分無し」の分岐は通らない" has_text "$RUN_OUT" "との差分が無い"
assert "1a: 前提条件未達時、main は feature-dirty-check の内容まで進まない" \
  [ "$(git -C "$TMP_MERGE_DIRTY" rev-parse main)" = "$merge_dirty_main_before" ]
# 未コミット変更（dirty.txt の1行）と現在のブランチ（main）をまとめて比べる。
merge_dirty_state="$(git -C "$TMP_MERGE_DIRTY" status --porcelain | wc -l | tr -d ' ') $(git -C "$TMP_MERGE_DIRTY" rev-parse --abbrev-ref HEAD)"
assert "1a: 前提条件未達時、git状態（未コミット変更・ブランチ）が変更されない" [ "$merge_dirty_state" = "1 main" ]
assert "1a: 前提条件未達（マージ未実施）のとき、作業ブランチは削除されない" [ -n "$(branch_name "$TMP_MERGE_DIRTY" feature-dirty-check)" ]

echo ""
echo "--- 1b. ff-only マージが成功し、対応するワークツリーが片付けられる ---"
TMP_MERGE_FF="$(mktemp -d)"
# 対応するワークツリーもここで一緒に登録する。アサーション後の単発 rm -rf に任せると、
# 作成後・その rm 行より前で中断された場合にディレクトリが残るためである。
register_tmp_cleanup "$TMP_MERGE_FF" "$TMP_MERGE_FF-wt"
merge_init_repo "$TMP_MERGE_FF"
merge_add_worktree_with_commit "$TMP_MERGE_FF" feature-ff "feature ff work"

merge_run "$TMP_MERGE_FF" feature-ff
merge_expect_result "1b: ff-only 可能なブランチのマージが" 0 MERGED
merge_expect_merged_and_cleaned "1b" "$TMP_MERGE_FF" feature-ff main "feature ff work"

echo ""
echo "--- 1c. 3-way マージ（衝突無し）が成功し、対応するワークツリーが片付けられる ---"
TMP_MERGE_3WAY="$(mktemp -d)"
register_tmp_cleanup "$TMP_MERGE_3WAY" "$TMP_MERGE_3WAY-wt"
(cd "$TMP_MERGE_3WAY" && git init -q -b main)
printf 'line1\n' > "$TMP_MERGE_3WAY/f1.txt"
printf 'line2\n' > "$TMP_MERGE_3WAY/f2.txt"
(cd "$TMP_MERGE_3WAY" && git add -A && git commit -q -m init && git branch feature-3way)
printf 'main change\n' >> "$TMP_MERGE_3WAY/f1.txt"
(cd "$TMP_MERGE_3WAY" && git add -A && git commit -q -m "main advances f1" \
  && git worktree add -q "$TMP_MERGE_3WAY-wt" feature-3way)
printf 'feature change\n' >> "$TMP_MERGE_3WAY-wt/f2.txt"
(cd "$TMP_MERGE_3WAY-wt" && git add -A && git commit -q -m "feature-3way advances f2")

merge_run "$TMP_MERGE_3WAY" feature-3way
merge_expect_result "1c: 衝突の無い 3-way マージが" 0 MERGED
assert "1c: main の最新コミットが2つの親を持つマージコミットになっている" \
  [ "$(git -C "$TMP_MERGE_3WAY" log -1 --format=%P main | wc -w | tr -d ' ')" = "2" ]
assert "1c: マージ完了後、メインの作業木がクリーンである" [ -z "$(git -C "$TMP_MERGE_3WAY" status --porcelain)" ]
assert "1c: マージ完了後、対応するワークツリーが自動で片付けられる" [ ! -d "$TMP_MERGE_3WAY-wt" ]
assert "1c: マージ完了後、対応する作業ブランチが自動で削除される（AC#1）" [ -z "$(branch_name "$TMP_MERGE_3WAY" feature-3way)" ]

echo ""
echo "--- 1d. 3-way マージが衝突する場合、abort して git 状態を復元する ---"
TMP_MERGE_CONFLICT="$(mktemp -d)"
register_tmp_cleanup "$TMP_MERGE_CONFLICT" "$TMP_MERGE_CONFLICT-wt"
(cd "$TMP_MERGE_CONFLICT" && git init -q -b main)
printf 'original\n' > "$TMP_MERGE_CONFLICT/shared.txt"
(cd "$TMP_MERGE_CONFLICT" && git add -A && git commit -q -m init && git branch feature-conflict)
printf 'main version\n' > "$TMP_MERGE_CONFLICT/shared.txt"
(cd "$TMP_MERGE_CONFLICT" && git add -A && git commit -q -m "main changes shared.txt" \
  && git worktree add -q "$TMP_MERGE_CONFLICT-wt" feature-conflict)
printf 'feature version\n' > "$TMP_MERGE_CONFLICT-wt/shared.txt"
(cd "$TMP_MERGE_CONFLICT-wt" && git add -A && git commit -q -m "feature-conflict changes shared.txt")

merge_conflict_head_before="$(git -C "$TMP_MERGE_CONFLICT" rev-parse HEAD)"
merge_run "$TMP_MERGE_CONFLICT" feature-conflict
merge_expect_result "1d: 衝突する 3-way マージが" 2 CONFLICT
assert "1d: 衝突したファイル（shared.txt）が出力に報告される" has_text "$RUN_OUT" "shared.txt"
assert "1d: 衝突後、main の HEAD がマージ前と変わっていない" \
  [ "$(git -C "$TMP_MERGE_CONFLICT" rev-parse HEAD)" = "$merge_conflict_head_before" ]
assert "1d: 衝突後、git merge --abort によりメインの作業木がクリーンな状態に戻っている" \
  [ -z "$(git -C "$TMP_MERGE_CONFLICT" status --porcelain)" ]
assert "1d: マージが完了していないため、対応するワークツリーは片付けられず残る" [ -d "$TMP_MERGE_CONFLICT-wt" ]
assert "1d: マージが完了していない（CONFLICT）ため、作業ブランチは削除されない（AC#2）" \
  [ -n "$(branch_name "$TMP_MERGE_CONFLICT" feature-conflict)" ]

echo ""
echo "--- 1e. マージは完了するが、対応するワークツリーが汚れており片付け・ブランチ削除の両方が失敗する ---"
# ワークツリーに未コミットの変更があると git worktree remove は --force しない限り失敗し、
# そのワークツリーがある限りブランチも使用中なので git branch -d も失敗する。この状況で
# マージ自体（RESULT/exit code）は成功のまま変わらず、--force/-D を使わずに両方が
# 残ることを確認する。
TMP_MERGE_DIRTY_WT="$(mktemp -d)"
register_tmp_cleanup "$TMP_MERGE_DIRTY_WT" "$TMP_MERGE_DIRTY_WT-wt"
merge_init_repo "$TMP_MERGE_DIRTY_WT"
merge_add_worktree_with_commit "$TMP_MERGE_DIRTY_WT" feature-dirty-wt "feature dirty-wt work"
echo "uncommitted in worktree" > "$TMP_MERGE_DIRTY_WT-wt/uncommitted.txt"

merge_run "$TMP_MERGE_DIRTY_WT" feature-dirty-wt
merge_expect_result "1e: ワークツリーが汚れていて片付け・ブランチ削除の両方が失敗しても、マージ自体は" 0 MERGED
assert "1e: main が feature-dirty-wt の内容までマージされている" \
  [ "$(git -C "$TMP_MERGE_DIRTY_WT" log -1 --format=%s main)" = "feature dirty-wt work" ]
assert "1e: ワークツリーが汚れているため --force されず、片付けられず残る" [ -d "$TMP_MERGE_DIRTY_WT-wt" ]
assert "1e: ワークツリーで使用中のため作業ブランチの削除に失敗し、-D されず残る（AC#3）" \
  [ -n "$(branch_name "$TMP_MERGE_DIRTY_WT" feature-dirty-wt)" ]

echo ""
echo "--- 1f. マージ済み（main との差分が無い）だが片付けが未完了の状態からの再実行で片付けが再試行される（TASK-57） ---"
# 1e と同様に1回目でワークツリーを dirty にしたままマージを成功させ、片付けを失敗させる。
# その後 clean に戻して同じブランチにもう一度呼び出す。main との差分は既に無い
# （PRECONDITION_NOT_MET）が、片付けが残っているのでそれだけが再試行され成功する。
TMP_MERGE_RECOVER="$(mktemp -d)"
register_tmp_cleanup "$TMP_MERGE_RECOVER" "$TMP_MERGE_RECOVER-wt"
merge_init_repo "$TMP_MERGE_RECOVER"
merge_add_worktree_with_commit "$TMP_MERGE_RECOVER" feature-recover "feature recover work"
echo "uncommitted in worktree" > "$TMP_MERGE_RECOVER-wt/uncommitted.txt"

# 1回目: マージは成功するが、ワークツリーが dirty なため片付けは失敗する。
merge_run "$TMP_MERGE_RECOVER" feature-recover
merge_recover_left="$([ -d "$TMP_MERGE_RECOVER-wt" ] && echo wt) $(branch_name "$TMP_MERGE_RECOVER" feature-recover)"
assert "1f: 前提として、1回目の呼び出し後もワークツリー・ブランチが片付かず残っている" [ "$merge_recover_left" = "wt feature-recover" ]

# ワークツリーを clean にする（人間が dirty なファイルを整理した状況を模する）。
rm -f "$TMP_MERGE_RECOVER-wt/uncommitted.txt"
merge_recover_head_before="$(git -C "$TMP_MERGE_RECOVER" rev-parse HEAD)"
merge_run "$TMP_MERGE_RECOVER" feature-recover
merge_expect_result "1f: 2回目の呼び出し（差分無し）は（AC#2）" 1 PRECONDITION_NOT_MET
assert "1f: 2回目の呼び出しで main の HEAD が動いていない（新規マージは発生していない）" \
  [ "$(git -C "$TMP_MERGE_RECOVER" rev-parse HEAD)" = "$merge_recover_head_before" ]
assert "1f: 片付けが未完了の状態から再実行すると、対応するワークツリーの片付けが再試行され成功する（AC#1）" \
  [ ! -d "$TMP_MERGE_RECOVER-wt" ]
assert "1f: 片付けが未完了の状態から再実行すると、対応する作業ブランチの削除が再試行され成功する（AC#1）" \
  [ -z "$(branch_name "$TMP_MERGE_RECOVER" feature-recover)" ]

echo ""
echo "--- 1g. 片付け済みの通常の PRECONDITION_NOT_MET（対象ブランチが存在しない）は挙動が変わらない（AC#2） ---"
TMP_MERGE_NOBRANCH="$(mktemp -d)"
register_tmp_cleanup "$TMP_MERGE_NOBRANCH"
merge_init_repo "$TMP_MERGE_NOBRANCH"
merge_run "$TMP_MERGE_NOBRANCH" feature-does-not-exist
merge_expect_result "1g: 対象ブランチが存在しない場合（AC#2）" 1 PRECONDITION_NOT_MET

echo ""
echo "--- 1h. デフォルトブランチが main 以外（master）でも ff-only マージが成功する（TASK-61 AC#1） ---"
# デフォルトブランチが "master" のソースリポジトリを git clone して作る。clone は
# ローカルパスでも refs/remotes/origin/HEAD を自動設定するので、ネットワーク無しで
# symbolic-ref 経由のデフォルトブランチ判定を再現できる。
TMP_MERGE_MASTER_SRC="$(mktemp -d)"
register_tmp_cleanup "$TMP_MERGE_MASTER_SRC"
merge_init_repo "$TMP_MERGE_MASTER_SRC" master
TMP_MERGE_MASTER_PARENT="$(mktemp -d)"
TMP_MERGE_MASTER="$TMP_MERGE_MASTER_PARENT/clone"
register_tmp_cleanup "$TMP_MERGE_MASTER_PARENT" "$TMP_MERGE_MASTER-wt"
git clone -q "$TMP_MERGE_MASTER_SRC" "$TMP_MERGE_MASTER"
merge_add_worktree_with_commit "$TMP_MERGE_MASTER" feature-master "feature master work"

merge_run "$TMP_MERGE_MASTER" feature-master
merge_expect_result "1h: デフォルトブランチが master のリポジトリでも ff-only マージが（AC#1）" 0 MERGED
merge_expect_merged_and_cleaned "1h" "$TMP_MERGE_MASTER" feature-master master "feature master work"
assert "1h: main ブランチは作成も参照もされない（デフォルトブランチ名の解決が固定 main に依存していない）" \
  [ -z "$(branch_name "$TMP_MERGE_MASTER" main)" ]

finish_tests
