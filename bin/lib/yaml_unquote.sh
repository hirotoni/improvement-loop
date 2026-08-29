# bin/lib/yaml_unquote.sh
#
# trim_and_unquote() の唯一の定義（TASK-62）。
#
# 「YAML のインライン配列（key: ["a", "b"]）/ 複数行リスト（key: の次行以降
# "  - \"a\"" 形式）の各要素から、前後の空白と、それを囲む引用符
# （シングル/ダブル、両端が対になっている場合のみ）を取り除く」という同じ
# 引用符除去ロジックが、bin/setup-improvement-loop の parse_statuses_block と
# claude-skills/improvement-dispatch/scripts/check-forbidden-allowed-paths の
# parse_path_list に、それぞれ独立実装として存在していた。前者はダブル
# クォートしか剥がさない不具合（TASK-62 の報告内容）があり、
# .backlog/config.yml の statuses をシングルクォートで書くと無音で壊れて
# いた。このファイルはその重複実装を1箇所に集約したものであり、以後は
# 両方の呼び出し元がここを source して使う。
#
# sed 等の外部コマンドを使わず、純粋な bash 展開のみで行う（呼び出し元の
# 実行環境に余分な依存を増やさないため）。
#
# このファイル自体は実行されず、必ず source される前提のためシバンは
# 付けない（bin/lib/resolve_path.sh と同じ慣例）。
#
# 引数: $1 = 配列要素の生文字列（前後に空白・引用符を含みうる）。
# 標準出力: 前後の空白と引用符を取り除いた結果。
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
