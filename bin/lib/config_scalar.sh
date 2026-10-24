# .backlog/config.my.yml の improvement_loop 配下の値の読み方の唯一の定義。実行されず、
# 必ず source される前提のためシバンは付けない。
#
# 次の 2 か所が使う。読み方を変えるときはここだけを変える。
# - create-worktree: worktree_base_dir と、起点の決め方を変える auto_merge_reviewed を読む。
# - check-remote-config-mismatch: リモートの有無と食い違う auto_merge_reviewed を検知する。
# 2 つが別々に読むと、auto_merge_reviewed の真偽の解釈がずれたとき、食い違いの警告と
# create-worktree の起点の決め方が矛盾する。

# read_config_scalar <config ファイル> <キー>
#   単一行のスカラー値を標準出力に出す。ファイルが無い、またはキーが無い場合は何も出さない
#   （＝既定値扱い）。キーは字下げを問わず最初に現れた行を使い、improvement_loop の外かどうかは
#   見ない。行末コメントと前後の引用符は取り除く。配列は扱わない（配列が要る
#   check-forbidden-allowed-paths は独自の parse_path_list を持つ）。
read_config_scalar() {
  local config_file="$1" key="$2" config_line
  if [ ! -f "$config_file" ]; then
    return 0
  fi
  config_line="$(grep -m1 -E "^[[:space:]]*${key}:" "$config_file" || true)"
  if [ -z "$config_line" ]; then
    return 0
  fi
  printf '%s\n' "$config_line" | sed -E \
    -e "s/^[[:space:]]*${key}:[[:space:]]*//" \
    -e 's/[[:space:]]+#.*$//' \
    -e 's/[[:space:]]+$//' \
    -e 's/^"(.*)"$/\1/' \
    -e "s/^'(.*)'\$/\\1/"
}

# auto_merge_reviewed_enabled <config ファイル>
#   auto_merge_reviewed が true（true/True/TRUE）なら真を返す。それ以外の値・キー無し・
#   ファイル無しは既定の false として偽を返す。
auto_merge_reviewed_enabled() {
  case "$(read_config_scalar "$1" auto_merge_reviewed)" in
    true|True|TRUE) return 0 ;;
    *) return 1 ;;
  esac
}
