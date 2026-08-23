# bin/lib/resolve_path.sh
#
# resolve_path() の唯一の定義。bin/setup-improvement-loop（bash）と
# install.zsh（zsh）の両方から source される共有ロジックである
# （TASK-18: 同一のフォールバック判定が2箇所に独立して存在していた重複を解消）。
#
# realpath があればそれを使う。無い環境向けのフォールバックも用意する
# （シンボリックリンクの多段解決はしないが、対象は最終的に絶対パスの実体に
# 還元される）。
#
# bash・zsh のどちらから source されても安全に動くよう、bash 固有の配列や
# zsh 固有の組み込み（print 等）は使わず、POSIX 互換の printf のみで出力する。
# local はどちらのシェルでも利用できる。このファイル自体は実行されず、必ず
# source される前提のためシバンは付けない。
#
# 例外: bin/setup-improvement-loop 冒頭のブートストラップ処理（自分自身の
# スクリプトパスの解決）だけは、このファイルを source できない構造的な制約が
# あるため、同じロジックのコピーを1箇所だけ残している。理由は同スクリプトの
# 該当コメントを参照。
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
