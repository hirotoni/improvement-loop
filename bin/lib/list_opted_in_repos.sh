# list_opted_in_repos() の唯一の定義。実行されず、必ず source される前提のため
# シバンは付けない。
#
# opt-in 判定に専用のマーカーファイルは持たない。対象リポジトリ直下の
# `.claude/skills/<skill_marker_name>`（bin/setup-improvement-loop が配置する
# シンボリックリンク）が実在解決することだけを見る。
#
# resolve_path.sh とは常に同じディレクトリに置かれている前提で、自分の場所から source する。
LIST_OPTED_IN_REPOS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve_path.sh
source "$LIST_OPTED_IN_REPOS_LIB_DIR/resolve_path.sh"

# ワークスペースディレクトリの直下（深さ1）のサブディレクトリのうち、
# (a) ディレクトリで (b) git リポジトリで (c) `.claude/skills/<skill_marker_name>` が
# 実在解決するシンボリックリンクとして存在する、の3条件を満たすものの絶対パスを、
# 1行1件・ソート済みで標準出力に書く。0件でも正常終了する。
#
# $1 = ワークスペースディレクトリ、$2 = スキル名（例: "improvement-dispatch"）。
list_opted_in_repos() {
  # set -u の呼び出し元から引数無しで呼ばれても unbound variable でシェルごと
  # 落とさず、下の空チェックで return 1 に倒すため ${1:-}/${2:-} で受ける。
  local workspace_dir="${1:-}"
  local skill_marker_name="${2:-}"

  if [ -z "$workspace_dir" ] || [ -z "$skill_marker_name" ]; then
    return 1
  fi
  if [ ! -d "$workspace_dir" ]; then
    return 0
  fi

  # サブディレクトリが1つも無いときにグロブパターン文字列そのものが1件として
  # 展開されるのを防ぐ。呼び出し元のシェルオプションは変えずに戻す。
  local had_nullglob=0
  case "$(shopt -p nullglob 2>/dev/null)" in
    *"-s nullglob"*) had_nullglob=1 ;;
  esac
  shopt -s nullglob
  local -a candidates=("$workspace_dir"/*/)
  if [ "$had_nullglob" -eq 0 ]; then
    shopt -u nullglob
  fi

  local -a results=()
  local dir
  for dir in ${candidates[@]+"${candidates[@]}"}; do
    [ -d "$dir" ] || continue

    local repo_root
    repo_root="$(cd "$dir" && pwd)"

    if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      continue
    fi

    local marker_path="$repo_root/.claude/skills/$skill_marker_name"
    if [ ! -L "$marker_path" ]; then
      continue
    fi
    # resolve_path はリンク切れで非ゼロ終了する。set -e の呼び出し元を落とさないよう if で受ける。
    if ! resolve_path "$marker_path" >/dev/null 2>&1; then
      continue
    fi

    results+=("$repo_root")
  done

  if [ "${#results[@]}" -eq 0 ]; then
    return 0
  fi
  printf '%s\n' "${results[@]}" | sort
}
