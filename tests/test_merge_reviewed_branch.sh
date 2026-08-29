#!/usr/bin/env bash
# tests/test_merge_reviewed_branch.sh
#
# claude-skills/improvement-dispatch/scripts/merge-reviewed-branch に対する
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

echo "=== 8. claude-skills/improvement-dispatch/scripts/merge-reviewed-branch の動作確認 ==="
# improvement-dispatch 手順3（auto_merge_reviewed: true）のマージ判定を
# 切り出した claude-skills/improvement-dispatch/scripts/merge-reviewed-branch を、
# 一時 git リポジトリに対して実際に実行して検証する。前提条件未達・ff-only成功・3-way衝突無し成功・
# 3-way衝突の4パターンを、それぞれ独立した一時リポジトリで確認する
# （TASK-22 受入基準 #1-#4 に対応）。

echo ""
echo "--- 7a. 前提条件未達: メインの作業木が汚れている ---"
TMP_MERGE_DIRTY="$(mktemp -d)"
register_tmp_cleanup "$TMP_MERGE_DIRTY"

(cd "$TMP_MERGE_DIRTY" && git init -q -b main && git commit -q --allow-empty -m init)
(cd "$TMP_MERGE_DIRTY" && git branch feature-dirty-check)
echo "uncommitted" > "$TMP_MERGE_DIRTY/dirty.txt"

merge_dirty_output="$(cd "$TMP_MERGE_DIRTY" && "$MERGE_SCRIPT" feature-dirty-check 2>&1)"
merge_dirty_exit=$?
if [ "$merge_dirty_exit" -eq 1 ]; then
  pass "7a: メインの作業木が汚れている場合、終了ステータス 1 (PRECONDITION_NOT_MET) を返す"
else
  fail "7a: メインの作業木が汚れている場合の終了ステータスが 1 でない（${merge_dirty_exit}）: $merge_dirty_output"
fi
if grep -Fq "RESULT: PRECONDITION_NOT_MET" <<<"$merge_dirty_output"; then
  pass "7a: 出力に RESULT: PRECONDITION_NOT_MET が含まれる"
else
  fail "7a: 出力に RESULT: PRECONDITION_NOT_MET が含まれない: $merge_dirty_output"
fi
if [ -n "$(cd "$TMP_MERGE_DIRTY" && git status --porcelain)" ] \
  && [ "$(cd "$TMP_MERGE_DIRTY" && git rev-parse --abbrev-ref HEAD)" = "main" ]; then
  pass "7a: 前提条件未達時、git状態（未コミット変更・ブランチ）が変更されない"
else
  fail "7a: 前提条件未達のはずが、メインの作業木の git 状態が変わっている"
fi
if [ -n "$(cd "$TMP_MERGE_DIRTY" && git branch --list feature-dirty-check)" ]; then
  pass "7a: 前提条件未達（マージ未実施）のとき、作業ブランチは削除されない"
else
  fail "7a: 前提条件未達のはずが、作業ブランチが削除されている"
fi

echo ""
echo "--- 7b. ff-only マージが成功し、対応するワークツリーが片付けられる ---"
TMP_MERGE_FF="$(mktemp -d)"
# 対応するワークツリー（$TMP_MERGE_FF-wt）もここで一緒に登録する。
# アサーション後の単発 rm -rf に任せると、ワークツリー作成後・その rm
# 行より前で中断された場合にディレクトリが残ってしまうため、EXIT trap で
# 確実に片付くようここで登録しておく。
register_tmp_cleanup "$TMP_MERGE_FF" "$TMP_MERGE_FF-wt"

(cd "$TMP_MERGE_FF" && git init -q -b main && git commit -q --allow-empty -m init)
(cd "$TMP_MERGE_FF" && git worktree add -q -b feature-ff "$TMP_MERGE_FF-wt" main)
(cd "$TMP_MERGE_FF-wt" && git commit -q --allow-empty -m "feature ff work")

merge_ff_output="$(cd "$TMP_MERGE_FF" && "$MERGE_SCRIPT" feature-ff 2>&1)"
merge_ff_exit=$?
if [ "$merge_ff_exit" -eq 0 ]; then
  pass "7b: ff-only 可能なブランチのマージが終了ステータス 0 (MERGED) で成功する"
else
  fail "7b: ff-only 可能なはずのマージが失敗した（${merge_ff_exit}）: $merge_ff_output"
fi
if grep -Fq "RESULT: MERGED" <<<"$merge_ff_output"; then
  pass "7b: 出力に RESULT: MERGED が含まれる"
else
  fail "7b: 出力に RESULT: MERGED が含まれない: $merge_ff_output"
fi
if [ "$(cd "$TMP_MERGE_FF" && git log -1 --format=%s main)" = "feature ff work" ]; then
  pass "7b: main が feature-ff の内容までマージされている"
else
  fail "7b: main が feature-ff の内容までマージされていない"
fi
if [ -d "$TMP_MERGE_FF-wt" ]; then
  fail "7b: マージ完了後も対応するワークツリーが片付けられていない"
else
  pass "7b: マージ完了後、対応するワークツリーが自動で片付けられる"
fi
if [ -z "$(cd "$TMP_MERGE_FF" && git branch --list feature-ff)" ]; then
  pass "7b: マージ完了後、対応する作業ブランチが自動で削除される（AC#1）"
else
  fail "7b: マージ完了後も対応する作業ブランチが削除されていない"
fi

echo ""
echo "--- 7c. 3-way マージ（衝突無し）が成功し、対応するワークツリーが片付けられる ---"
TMP_MERGE_3WAY="$(mktemp -d)"
register_tmp_cleanup "$TMP_MERGE_3WAY" "$TMP_MERGE_3WAY-wt"

(cd "$TMP_MERGE_3WAY" && git init -q -b main)
printf 'line1\n' > "$TMP_MERGE_3WAY/f1.txt"
printf 'line2\n' > "$TMP_MERGE_3WAY/f2.txt"
(cd "$TMP_MERGE_3WAY" && git add -A && git commit -q -m init)
(cd "$TMP_MERGE_3WAY" && git branch feature-3way)
printf 'main change\n' >> "$TMP_MERGE_3WAY/f1.txt"
(cd "$TMP_MERGE_3WAY" && git add -A && git commit -q -m "main advances f1")
(cd "$TMP_MERGE_3WAY" && git worktree add -q "$TMP_MERGE_3WAY-wt" feature-3way)
printf 'feature change\n' >> "$TMP_MERGE_3WAY-wt/f2.txt"
(cd "$TMP_MERGE_3WAY-wt" && git add -A && git commit -q -m "feature-3way advances f2")

merge_3way_output="$(cd "$TMP_MERGE_3WAY" && "$MERGE_SCRIPT" feature-3way 2>&1)"
merge_3way_exit=$?
if [ "$merge_3way_exit" -eq 0 ]; then
  pass "7c: 衝突の無い 3-way マージが終了ステータス 0 (MERGED) で成功する"
else
  fail "7c: 衝突が無いはずの 3-way マージが失敗した（${merge_3way_exit}）: $merge_3way_output"
fi
if grep -Fq "RESULT: MERGED" <<<"$merge_3way_output"; then
  pass "7c: 出力に RESULT: MERGED が含まれる"
else
  fail "7c: 出力に RESULT: MERGED が含まれない: $merge_3way_output"
fi
merge_3way_parents="$(cd "$TMP_MERGE_3WAY" && git log -1 --format=%P main | wc -w | tr -d ' ')"
if [ "$merge_3way_parents" = "2" ]; then
  pass "7c: main の最新コミットが2つの親を持つマージコミットになっている"
else
  fail "7c: main の最新コミットがマージコミットになっていない（親の数: ${merge_3way_parents}）"
fi
if [ -z "$(cd "$TMP_MERGE_3WAY" && git status --porcelain)" ]; then
  pass "7c: マージ完了後、メインの作業木がクリーンである"
else
  fail "7c: マージ完了後もメインの作業木が汚れている"
fi
if [ -d "$TMP_MERGE_3WAY-wt" ]; then
  fail "7c: マージ完了後も対応するワークツリーが片付けられていない"
else
  pass "7c: マージ完了後、対応するワークツリーが自動で片付けられる"
fi
if [ -z "$(cd "$TMP_MERGE_3WAY" && git branch --list feature-3way)" ]; then
  pass "7c: マージ完了後、対応する作業ブランチが自動で削除される（AC#1）"
else
  fail "7c: マージ完了後も対応する作業ブランチが削除されていない"
fi

echo ""
echo "--- 7d. 3-way マージが衝突する場合、abort して git 状態を復元する ---"
TMP_MERGE_CONFLICT="$(mktemp -d)"
register_tmp_cleanup "$TMP_MERGE_CONFLICT" "$TMP_MERGE_CONFLICT-wt"

(cd "$TMP_MERGE_CONFLICT" && git init -q -b main)
printf 'original\n' > "$TMP_MERGE_CONFLICT/shared.txt"
(cd "$TMP_MERGE_CONFLICT" && git add -A && git commit -q -m init)
(cd "$TMP_MERGE_CONFLICT" && git branch feature-conflict)
printf 'main version\n' > "$TMP_MERGE_CONFLICT/shared.txt"
(cd "$TMP_MERGE_CONFLICT" && git add -A && git commit -q -m "main changes shared.txt")
(cd "$TMP_MERGE_CONFLICT" && git worktree add -q "$TMP_MERGE_CONFLICT-wt" feature-conflict)
printf 'feature version\n' > "$TMP_MERGE_CONFLICT-wt/shared.txt"
(cd "$TMP_MERGE_CONFLICT-wt" && git add -A && git commit -q -m "feature-conflict changes shared.txt")

merge_conflict_head_before="$(cd "$TMP_MERGE_CONFLICT" && git rev-parse HEAD)"
merge_conflict_output="$(cd "$TMP_MERGE_CONFLICT" && "$MERGE_SCRIPT" feature-conflict 2>&1)"
merge_conflict_exit=$?
merge_conflict_head_after="$(cd "$TMP_MERGE_CONFLICT" && git rev-parse HEAD)"

if [ "$merge_conflict_exit" -eq 2 ]; then
  pass "7d: 衝突する 3-way マージが終了ステータス 2 (CONFLICT) を返す"
else
  fail "7d: 衝突するはずの 3-way マージの終了ステータスが 2 でない（${merge_conflict_exit}）: $merge_conflict_output"
fi
if grep -Fq "RESULT: CONFLICT" <<<"$merge_conflict_output"; then
  pass "7d: 出力に RESULT: CONFLICT が含まれる"
else
  fail "7d: 出力に RESULT: CONFLICT が含まれない: $merge_conflict_output"
fi
if grep -Fq "shared.txt" <<<"$merge_conflict_output"; then
  pass "7d: 衝突したファイル（shared.txt）が出力に報告される"
else
  fail "7d: 衝突したファイルが出力に報告されない: $merge_conflict_output"
fi
if [ "$merge_conflict_head_before" = "$merge_conflict_head_after" ]; then
  pass "7d: 衝突後、main の HEAD がマージ前と変わっていない"
else
  fail "7d: 衝突後、main の HEAD がマージ前から変わっている"
fi
if [ -z "$(cd "$TMP_MERGE_CONFLICT" && git status --porcelain)" ]; then
  pass "7d: 衝突後、git merge --abort によりメインの作業木がクリーンな状態に戻っている"
else
  fail "7d: 衝突後もメインの作業木が汚れたままである（abort されていない）"
fi
if [ -d "$TMP_MERGE_CONFLICT-wt" ]; then
  pass "7d: マージが完了していないため、対応するワークツリーは片付けられず残る"
else
  fail "7d: マージが完了していないはずなのに、対応するワークツリーが片付けられている"
fi
if [ -n "$(cd "$TMP_MERGE_CONFLICT" && git branch --list feature-conflict)" ]; then
  pass "7d: マージが完了していない（CONFLICT）ため、作業ブランチは削除されない（AC#2）"
else
  fail "7d: マージが完了していないはずなのに、作業ブランチが削除されている"
fi

echo ""
echo "--- 7e. マージは完了するが、対応するワークツリーが汚れており片付け・ブランチ削除の両方が失敗する ---"
# ワークツリーに未コミットの変更を残しておくと、git worktree remove は --force
# しない限り失敗する。さらにそのワークツリーが存在する限り、ブランチはそこで
# 使用中のままなので git branch -d も失敗する。この状況で、マージ自体
# （RESULT/exit code）が成功のまま変わらないこと（AC#3: worktree片付けと同様の
# 扱い）と、--force/-D を使わずワークツリー・ブランチの両方が削除されずに
# 残ることを確認する。
TMP_MERGE_DIRTY_WT="$(mktemp -d)"
register_tmp_cleanup "$TMP_MERGE_DIRTY_WT" "$TMP_MERGE_DIRTY_WT-wt"

(cd "$TMP_MERGE_DIRTY_WT" && git init -q -b main && git commit -q --allow-empty -m init)
(cd "$TMP_MERGE_DIRTY_WT" && git worktree add -q -b feature-dirty-wt "$TMP_MERGE_DIRTY_WT-wt" main)
(cd "$TMP_MERGE_DIRTY_WT-wt" && git commit -q --allow-empty -m "feature dirty-wt work")
echo "uncommitted in worktree" > "$TMP_MERGE_DIRTY_WT-wt/uncommitted.txt"

merge_dirty_wt_output="$(cd "$TMP_MERGE_DIRTY_WT" && "$MERGE_SCRIPT" feature-dirty-wt 2>&1)"
merge_dirty_wt_exit=$?
if [ "$merge_dirty_wt_exit" -eq 0 ]; then
  pass "7e: ワークツリーが汚れていて片付け・ブランチ削除の両方が失敗しても、マージ自体は終了ステータス 0 (MERGED) のまま"
else
  fail "7e: ワークツリーが汚れている場合でもマージ自体は成功するはずが、終了ステータスが 0 でない（${merge_dirty_wt_exit}）: $merge_dirty_wt_output"
fi
if grep -Fq "RESULT: MERGED" <<<"$merge_dirty_wt_output"; then
  pass "7e: 出力に RESULT: MERGED が含まれる（worktree片付け・ブランチ削除の失敗は結果を変えない）"
else
  fail "7e: 出力に RESULT: MERGED が含まれない: $merge_dirty_wt_output"
fi
if [ "$(cd "$TMP_MERGE_DIRTY_WT" && git log -1 --format=%s main)" = "feature dirty-wt work" ]; then
  pass "7e: main が feature-dirty-wt の内容までマージされている"
else
  fail "7e: main が feature-dirty-wt の内容までマージされていない"
fi
if [ -d "$TMP_MERGE_DIRTY_WT-wt" ]; then
  pass "7e: ワークツリーが汚れているため --force されず、片付けられず残る"
else
  fail "7e: 汚れたワークツリーが --force で片付けられてしまっている（想定外）"
fi
if [ -n "$(cd "$TMP_MERGE_DIRTY_WT" && git branch --list feature-dirty-wt)" ]; then
  pass "7e: ワークツリーで使用中のため作業ブランチの削除に失敗し、-D されず残る（AC#3）"
else
  fail "7e: ブランチ削除が失敗するはずが、作業ブランチが削除されている（-D 相当の強制削除が疑われる）"
fi

echo ""
echo "--- 7f. マージ済み（main との差分が無い）だが片付けが未完了の状態からの再実行で片付けが再試行される（TASK-57） ---"
# 7e と同様に、まず1回目の呼び出しでワークツリーを dirty にしたまま
# マージを成功させ、片付け（worktree remove・branch -d）を失敗させる。
# その後、ワークツリーを clean な状態に戻してから同じブランチに対して
# もう一度スクリプトを呼び出す。main との差分は既に無い
# （PRECONDITION_NOT_MET）が、対応するワークツリー・ブランチの片付けが
# まだ残っているため、この2回目の呼び出しでその片付けだけが再試行され
# 成功することを確認する（AC#1）。
TMP_MERGE_RECOVER="$(mktemp -d)"
register_tmp_cleanup "$TMP_MERGE_RECOVER" "$TMP_MERGE_RECOVER-wt"

(cd "$TMP_MERGE_RECOVER" && git init -q -b main && git commit -q --allow-empty -m init)
(cd "$TMP_MERGE_RECOVER" && git worktree add -q -b feature-recover "$TMP_MERGE_RECOVER-wt" main)
(cd "$TMP_MERGE_RECOVER-wt" && git commit -q --allow-empty -m "feature recover work")
echo "uncommitted in worktree" > "$TMP_MERGE_RECOVER-wt/uncommitted.txt"

# 1回目: マージは成功するが、ワークツリーが dirty なため片付けは失敗する
# （7e と同じ状況を作るだけで、ここではアサーションしない）。
(cd "$TMP_MERGE_RECOVER" && "$MERGE_SCRIPT" feature-recover >/dev/null 2>&1)

if [ -d "$TMP_MERGE_RECOVER-wt" ] && [ -n "$(cd "$TMP_MERGE_RECOVER" && git branch --list feature-recover)" ]; then
  pass "7f: 前提として、1回目の呼び出し後もワークツリー・ブランチが片付かず残っている"
else
  fail "7f: 前提が崩れている（1回目の呼び出し後にワークツリー・ブランチが残っていない）"
fi

# ワークツリーを clean にする（人間が dirty なファイルを整理した状況を模する）。
rm -f "$TMP_MERGE_RECOVER-wt/uncommitted.txt"

merge_recover_head_before="$(cd "$TMP_MERGE_RECOVER" && git rev-parse HEAD)"
merge_recover_output="$(cd "$TMP_MERGE_RECOVER" && "$MERGE_SCRIPT" feature-recover 2>&1)"
merge_recover_exit=$?
merge_recover_head_after="$(cd "$TMP_MERGE_RECOVER" && git rev-parse HEAD)"

if [ "$merge_recover_exit" -eq 1 ]; then
  pass "7f: 2回目の呼び出し（差分無し）は終了ステータス 1 (PRECONDITION_NOT_MET) のまま変わらない（AC#2）"
else
  fail "7f: 2回目の呼び出しの終了ステータスが 1 でない（${merge_recover_exit}）: $merge_recover_output"
fi
if grep -Fq "RESULT: PRECONDITION_NOT_MET" <<<"$merge_recover_output"; then
  pass "7f: 出力に RESULT: PRECONDITION_NOT_MET が含まれる（AC#2）"
else
  fail "7f: 出力に RESULT: PRECONDITION_NOT_MET が含まれない: $merge_recover_output"
fi
if [ "$merge_recover_head_before" = "$merge_recover_head_after" ]; then
  pass "7f: 2回目の呼び出しで main の HEAD が動いていない（新規マージは発生していない）"
else
  fail "7f: 2回目の呼び出しで main の HEAD が動いている（新規マージが発生してしまっている）"
fi
if [ -d "$TMP_MERGE_RECOVER-wt" ]; then
  fail "7f: 片付けが未完了の状態から再実行しても、対応するワークツリーが片付けられない（AC#1）"
else
  pass "7f: 片付けが未完了の状態から再実行すると、対応するワークツリーの片付けが再試行され成功する（AC#1）"
fi
if [ -z "$(cd "$TMP_MERGE_RECOVER" && git branch --list feature-recover)" ]; then
  pass "7f: 片付けが未完了の状態から再実行すると、対応する作業ブランチの削除が再試行され成功する（AC#1）"
else
  fail "7f: 片付けが未完了の状態から再実行しても、対応する作業ブランチが削除されない（AC#1）"
fi

echo ""
echo "--- 7g. 片付け済みの通常の PRECONDITION_NOT_MET（対象ブランチが存在しない）は挙動が変わらない（AC#2） ---"
TMP_MERGE_NOBRANCH="$(mktemp -d)"
register_tmp_cleanup "$TMP_MERGE_NOBRANCH"

(cd "$TMP_MERGE_NOBRANCH" && git init -q -b main && git commit -q --allow-empty -m init)

merge_nobranch_output="$(cd "$TMP_MERGE_NOBRANCH" && "$MERGE_SCRIPT" feature-does-not-exist 2>&1)"
merge_nobranch_exit=$?
if [ "$merge_nobranch_exit" -eq 1 ]; then
  pass "7g: 対象ブランチが存在しない場合、終了ステータス 1 (PRECONDITION_NOT_MET) を返す（AC#2）"
else
  fail "7g: 対象ブランチが存在しない場合の終了ステータスが 1 でない（${merge_nobranch_exit}）: $merge_nobranch_output"
fi
if grep -Fq "RESULT: PRECONDITION_NOT_MET" <<<"$merge_nobranch_output"; then
  pass "7g: 出力に RESULT: PRECONDITION_NOT_MET が含まれる（AC#2）"
else
  fail "7g: 出力に RESULT: PRECONDITION_NOT_MET が含まれない: $merge_nobranch_output"
fi

echo ""
echo "--- 7h. デフォルトブランチが main 以外（master）でも ff-only マージが成功する（TASK-61 AC#1） ---"
# メインの作業木用ディレクトリは、デフォルトブランチが "master" のソース
# リポジトリを git clone して作る。git clone はローカルパスの clone でも
# refs/remotes/origin/HEAD を自動設定するため、ネットワーク無しで
# merge-reviewed-branch の symbolic-ref 経由のデフォルトブランチ判定
# （create-worktree と同じ核心ロジック）を再現できる。
TMP_MERGE_MASTER_SRC="$(mktemp -d)"
register_tmp_cleanup "$TMP_MERGE_MASTER_SRC"
(cd "$TMP_MERGE_MASTER_SRC" && git init -q -b master && git commit -q --allow-empty -m init)

TMP_MERGE_MASTER_PARENT="$(mktemp -d)"
TMP_MERGE_MASTER="$TMP_MERGE_MASTER_PARENT/clone"
register_tmp_cleanup "$TMP_MERGE_MASTER_PARENT" "$TMP_MERGE_MASTER-wt"
git clone -q "$TMP_MERGE_MASTER_SRC" "$TMP_MERGE_MASTER"

(cd "$TMP_MERGE_MASTER" && git worktree add -q -b feature-master "$TMP_MERGE_MASTER-wt" master)
(cd "$TMP_MERGE_MASTER-wt" && git commit -q --allow-empty -m "feature master work")

merge_master_output="$(cd "$TMP_MERGE_MASTER" && "$MERGE_SCRIPT" feature-master 2>&1)"
merge_master_exit=$?
if [ "$merge_master_exit" -eq 0 ]; then
  pass "7h: デフォルトブランチが master のリポジトリでも ff-only マージが終了ステータス 0 (MERGED) で成功する（AC#1）"
else
  fail "7h: デフォルトブランチが master の場合のマージが失敗した（${merge_master_exit}）: $merge_master_output"
fi
if grep -Fq "RESULT: MERGED" <<<"$merge_master_output"; then
  pass "7h: 出力に RESULT: MERGED が含まれる（AC#1）"
else
  fail "7h: 出力に RESULT: MERGED が含まれない: $merge_master_output"
fi
if [ "$(cd "$TMP_MERGE_MASTER" && git log -1 --format=%s master)" = "feature master work" ]; then
  pass "7h: master が feature-master の内容までマージされている（AC#1）"
else
  fail "7h: master が feature-master の内容までマージされていない"
fi
if [ -d "$TMP_MERGE_MASTER-wt" ]; then
  fail "7h: マージ完了後も対応するワークツリーが片付けられていない"
else
  pass "7h: マージ完了後、対応するワークツリーが自動で片付けられる"
fi
if [ -z "$(cd "$TMP_MERGE_MASTER" && git branch --list feature-master)" ]; then
  pass "7h: マージ完了後、対応する作業ブランチが自動で削除される"
else
  fail "7h: マージ完了後も対応する作業ブランチが削除されていない"
fi
if [ -z "$(cd "$TMP_MERGE_MASTER" && git branch --list main)" ]; then
  pass "7h: main ブランチは作成も参照もされない（デフォルトブランチ名の解決が固定 main に依存していない）"
else
  fail "7h: 想定外の main ブランチが作成されている（main へのハードコードが残っている疑い）"
fi

finish_tests
