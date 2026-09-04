# trim_and_unquote() の唯一の定義。実行されず、必ず source される前提のため
# シバンは付けない。
#
# YAML の配列要素から前後の空白と、それを囲む引用符（シングル/ダブルのどちらも。
# 両端が対になっている場合のみ）を取り除く。bin/setup-improvement-loop の
# parse_statuses_block と check-forbidden-allowed-paths の parse_path_list が
# 共有する。シングルクォートも剥がすことは仕様である（片方だけを剥がす実装だと
# config.yml の statuses をシングルクォートで書いたときに無音で壊れる）。
#
# sed 等の外部コマンドは使わず、純粋な bash 展開のみで行う。
#
# 引数: $1 = 配列要素の生文字列。標準出力: 空白と引用符を取り除いた結果。
trim_and_unquote() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  if [ "${#s}" -ge 2 ]; then
    case "$s" in
      \"*\") s="${s:1:${#s}-2}" ;;
      \'*\') s="${s:1:${#s}-2}" ;;
    esac
  fi
  printf '%s' "$s"
}
