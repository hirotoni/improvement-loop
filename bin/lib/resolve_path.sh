# resolve_path() の唯一の定義。実行されず、必ず source される前提のためシバンは
# 付けない。realpath があればそれを使い、無ければフォールバックする
# （多段のシンボリックリンク解決はしないが、絶対パスの実体には還元される）。
#
# bin/setup-improvement-loop（bash）と install.zsh（zsh）の両方から source される。
# どちらのシェルでも動くよう bash 固有の配列や zsh 固有の print は使わず printf のみ。
#
# 例外: bin/setup-improvement-loop 冒頭のブートストラップだけは、このファイルを
# source できない構造的な制約があるため同じロジックのコピーを1箇所だけ残している
# （理由は同スクリプトの該当コメント）。
resolve_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
  elif readlink -f "$1" >/dev/null 2>&1; then
    readlink -f "$1"
  else
    local dir base
    dir="$(cd "$(dirname "$1")" && pwd -P)"
    base="$(basename "$1")"
    printf '%s/%s\n' "$dir" "$base"
  fi
}
