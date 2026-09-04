# worktree_porcelain_pairs() の唯一の定義。実行されず、必ず source される前提の
# ためシバンは付けない。
#
# 標準入力に `git worktree list --porcelain` の出力を受け取り、worktree エントリ
# 1件につき "<path><TAB><branch>" の1行を標準出力に出す。
#   - <path> は "worktree " 行の残り全体。半角スペースを含みうるので awk の
#     デフォルトのフィールド分割（$2）では切り捨てられてしまう。ここで行の残り
#     全体を1つのパスとして復元し、呼び出し元がその復元を意識せずに済むようにする。
#   - <branch> は対応する "branch " 行があれば refs/heads/ を除いた短縮名、
#     無ければ空文字（detached HEAD 等）。
#
# 呼び出し例（パスからブランチを引く / ブランチからパスを引く）:
#   ... | worktree_porcelain_pairs | awk -F'\t' -v d="$dir" '$1 == d { print $2; exit }'
#   ... | worktree_porcelain_pairs | awk -F'\t' -v b="$branch" '$2 == b { print $1 }'
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
