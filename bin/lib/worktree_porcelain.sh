# bin/lib/worktree_porcelain.sh
#
# worktree_porcelain_pairs() の唯一の定義（TASK-64）。
#
# `git worktree list --porcelain` の出力から worktree/branch の対応を復元する
# 処理が、次の2箇所に独立した awk 実装として存在していた。
#   - claude-code/skills/improvement-dispatch/scripts/create-worktree
#     （WORKTREE_DIR → 割り当てブランチを求める）
#   - claude-code/skills/improvement-dispatch/scripts/merge-reviewed-branch
#     （branch → 対応する worktree のパスを求める）
# どちらも porcelain の "worktree " 行はパスに半角スペースを含みうるため
# awk のデフォルトフィールド分割（$2）ではスペース以降が切り捨てられる
# 問題への対処として `substr($0, index($0, $2))` で行の残り全体を1つの
# パスとして復元する、同じパターンを持っていた（TASK-55: create-worktree
# 側だけがこの対処を欠いていたために半角スペースを含むパスで冪等性バグを
# 起こした経緯がある）。このファイルはその重複実装を1箇所に集約し、
# 以後は両方の呼び出し元がここを source して使う。
#
# このファイル自体は実行されず、必ず source される前提のためシバンは
# 付けない（bin/lib/resolve_path.sh と同じ慣例）。
#
# worktree_porcelain_pairs: 標準入力に `git worktree list --porcelain` の
# 出力を受け取り、worktree エントリ1件につき1行、
# "<path><TAB><branch>" 形式（TSV）で標準出力に出す。
#   - <path> は "worktree " 行の残り全体（半角スペースを含みうる）。
#   - <branch> は対応する "branch " 行があれば refs/heads/ を除いた短縮名、
#     無ければ空文字（detached HEAD 等）。
# 呼び出し元は awk -F'\t' で単純にフィルタするだけでよく、パス復元の
# ロジック自体を意識する必要が無い。
#
# 呼び出し例（パスからブランチを引く。create-worktree の用途）:
#   git worktree list --porcelain | worktree_porcelain_pairs | \
#     awk -F'\t' -v d="$WORKTREE_DIR" '$1 == d { print $2; exit }'
#
# 呼び出し例（ブランチからパスを引く。merge-reviewed-branch の用途）:
#   git -C "$repo_root" worktree list --porcelain | worktree_porcelain_pairs | \
#     awk -F'\t' -v b="$branch" '$2 == b { print $1 }'
worktree_porcelain_pairs() {
  awk '
    function emit() {
      if (has_path) {
        printf "%s\t%s\n", path, branch
      }
    }
    /^worktree / {
      emit()
      path = substr($0, index($0, $2))
      branch = ""
      has_path = 1
      next
    }
    /^branch / {
      branch = $2
      sub("^refs/heads/", "", branch)
      next
    }
    END { emit() }
  '
}
