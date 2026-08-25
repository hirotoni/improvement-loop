# bin/lib/list_opted_in_repos.sh
#
# list_opted_in_repos() の唯一の定義。ワークスペースディレクトリ（複数の git
# リポジトリを直下（深さ1）にクローンしたディレクトリ）配下から、指定した
# スキルに opt-in 済みのリポジトリを列挙する共有ロジック。
# bin/lib/resolve_path.sh と同じ配置パターン（このファイル自体は実行されず、
# 必ず source される前提。関数を1つ提供するだけの薄いファイル）を踏襲する。
#
# opt-in 判定は「新規マーカーファイルを持たない」設計（Decision 4）のため、
# 対象リポジトリ直下の `.claude/skills/<skill_marker_name>` が実在解決する
# シンボリックリンクであることだけを見る。これは `bin/setup-improvement-loop`
# （--workspace 無し）が各リポジトリに配置するシンボリックリンクと同じもので、
# 例えば workspace-dispatch は "improvement-dispatch" を、workspace-scout は
# "improvement-scout" を渡す。
#
# シンボリックリンクの解決には bin/lib/resolve_path.sh の resolve_path() を
# 再利用する（同じ解決ロジックを重複実装しない）。このファイルは常に
# bin/lib/resolve_path.sh と同じディレクトリに置かれている前提で、自分自身の
# 場所からそれを source する。
LIST_OPTED_IN_REPOS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve_path.sh
source "$LIST_OPTED_IN_REPOS_LIB_DIR/resolve_path.sh"

# list_opted_in_repos: ワークスペースディレクトリ配下の直下（深さ1）の
# サブディレクトリのうち、次の3条件すべてを満たすものの絶対パスを、
# 1行1件・ソート済みで標準出力に書く。
#   (a) ディレクトリであること
#   (b) git リポジトリであること（`git -C "$dir" rev-parse --is-inside-work-tree` が成功する）
#   (c) `.claude/skills/<skill_marker_name>` が実在解決するシンボリックリンクとして存在すること
# 該当が0件でも正常終了する（何も出力しない）。
#
# 引数:
#   $1 = workspace_dir      ワークスペースディレクトリの絶対または相対パス
#   $2 = skill_marker_name  opt-in 判定に使うスキル名（例: "improvement-dispatch"）
list_opted_in_repos() {
  # set -u 下で source される呼び出し元（list-target-repos 等）から引数無しで
  # 呼ばれても「unbound variable」でシェルごと落とさず、後続の空チェックで
  # 通常のエラー終了（return 1）に倒すため、${1:-}/${2:-} で防御的に受ける。
  local workspace_dir="${1:-}"
  local skill_marker_name="${2:-}"

  if [ -z "$workspace_dir" ] || [ -z "$skill_marker_name" ]; then
    return 1
  fi
  if [ ! -d "$workspace_dir" ]; then
    return 0
  fi

  # nullglob を一時的に有効化し、直下のサブディレクトリが1つも無い場合に
  # グロブパターン文字列そのものが1件として展開されるのを防ぐ。呼び出し元の
  # シェルオプションを変えないよう、元の状態を保存してから復元する。
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
    # resolve_path（realpath 相当）はリンク切れ（リンク先が存在しない）の
    # 場合に非ゼロで終了する。set -e で呼び出し元を落とさないよう if で受ける。
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
