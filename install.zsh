#!/usr/bin/env zsh
# shellcheck shell=bash
# improvement-loop の `bin/setup-improvement-loop` を $HOME/.local/bin へ
# シンボリックリンクし、パスから使えるようにする。
# 既に正しいリンク先を指していれば何もしない。別の実体があればエラーで停止する。
#
# 注意: これは zsh 専用である。shellcheck は zsh を直接サポートしない（SC1071）ため
# 上の shell=bash ディレクティブで bash として解析させている。zsh 固有の構文
# （${0:A:h}、print 組み込み等）による誤検知が出うる点に留意すること。

set -euo pipefail

log() {
  print -r -- "$*"
}

err() {
  print -r -- "エラー: $*" >&2
}

# ---- リポジトリのルートを、このファイル自身の場所から解決する ----
# zsh 組み込みの ${0:A:h} が symlink 解決込みの絶対パスを返すので、
# bin/setup-improvement-loop のようなブートストラップ処理は要らない。
SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR}"
SOURCE_BIN="$REPO_ROOT/bin/setup-improvement-loop"

# ここでは REPO_ROOT が既に確定しているため、bin/setup-improvement-loop と違って
# 循環参照の制約が無く、resolve_path() の唯一の定義をそのまま source できる。
# shellcheck source=bin/lib/resolve_path.sh
source "$REPO_ROOT/bin/lib/resolve_path.sh"

if [ ! -f "$SOURCE_BIN" ]; then
  err "配布元スクリプトが見つからない: $SOURCE_BIN"
  exit 1
fi
if [ ! -x "$SOURCE_BIN" ]; then
  err "配布元スクリプトに実行権限が無い: $SOURCE_BIN"
  exit 1
fi

LOCAL_BIN="$HOME/.local/bin"
DEST="$LOCAL_BIN/setup-improvement-loop"

mkdir -p "$LOCAL_BIN"

if [ -L "$DEST" ]; then
  # リンク切れの場合 resolve_path が非ゼロ終了しうる。set -e で落とさず
  # 「別のリンク先」として扱う。
  resolved_existing="$(resolve_path "$DEST" 2>/dev/null)" || resolved_existing=""
  resolved_src="$(resolve_path "$SOURCE_BIN")"
  if [ "$resolved_existing" = "$resolved_src" ]; then
    log "[skip] $DEST は既に正しいリンク先を指している。"
  else
    err "$DEST は既に別のリンク先を指すシンボリックリンクである: $(readlink "$DEST")"
    err "手動で確認・削除してから再実行すること。"
    exit 1
  fi
elif [ -e "$DEST" ]; then
  err "$DEST にはシンボリックリンクではない実体が既に存在する。"
  err "手動で確認・削除してから再実行すること。"
  exit 1
else
  ln -s "$SOURCE_BIN" "$DEST"
  log "[new]  $DEST -> $SOURCE_BIN"
fi

# ---- PATH の確認（rc ファイルは書き換えない） ----
case ":$PATH:" in
  *":$LOCAL_BIN:"*)
    log "[ok]   $LOCAL_BIN は PATH に含まれている。"
    ;;
  *)
    log "[warn] $LOCAL_BIN が PATH に含まれていない。"
    log "       シェルの起動ファイル（例: ~/.zshrc）に次を追加すること:"
    log "         export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac

log ""
log "完了。setup-improvement-loop を対象リポジトリで実行してセットアップすること。"
log "  例: setup-improvement-loop /path/to/your/repo"
