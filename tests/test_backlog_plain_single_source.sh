#!/usr/bin/env bash
# backlog CLI の `--plain` の適用範囲の正本（claude-code/skills/backlog-plain.md）と、
# それを参照する SKILL.md 群に対するテスト。
#
# この知識は以前4つの SKILL.md に独立して複製されており、4箇所が同じ誤りを抱えたまま
# 片方だけ直る事故が起きていた。ここでは正本が存在し、参照側の各スキルから正本への
# リンクが実際に解決できることだけを確かめる。正本や参照側の文言は照合しない
# （言い換えで落ちる一方、説明の食い違いや目印を避けた複製は捕まえられないため）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

CANONICAL_REL="claude-code/skills/backlog-plain.md"
CANONICAL_FILE="$REPO_ROOT/$CANONICAL_REL"

# 正本を参照する側のファイル（リポジトリルートからの相対パス）。
REFERRING_FILES=(
  "claude-code/skills/improvement-scout/SKILL.md"
  "claude-code/skills/improvement-add/SKILL.md"
  "claude-code/skills/improvement-scout-major/SKILL.md"
  "claude-code/workspace-skills/workspace-scout-major/SKILL.md"
)

# 参照ファイル中の Markdown リンクのうち、正本のファイル名を指すものを参照ファイルの
# ディレクトリ起点で解決し、すべて正本の実体に届くことを確認する。配布先では
# .claude/skills/<スキル名> シンボリックリンクから実体を解決するので、実体のディレクトリ
# 起点での解決がそのまま配布先での解決になる。リンクの文言や周りの説明は見ない。
# 認識するのはインライン形式 [text](path) のリンクだけである（タイトル付き・参照形式は拾わず FAIL になる）。
check_canonical_links() {
  local rel="$1"
  local file="$REPO_ROOT/$rel"
  local canonical_base canonical_real target link_dir resolved
  local found=0 broken=()
  canonical_base="$(basename "$CANONICAL_FILE")"
  canonical_real=""
  if [ -f "$CANONICAL_FILE" ]; then
    canonical_real="$(cd "$(dirname "$CANONICAL_FILE")" && pwd -P)/$canonical_base"
  fi
  while IFS= read -r target; do
    target="${target#](}"
    target="${target%)}"
    target="${target%%#*}"
    [ "$(basename "$target")" = "$canonical_base" ] || continue
    found=1
    link_dir="$(dirname "$file")/$(dirname "$target")"
    resolved=""
    if [ -d "$link_dir" ]; then
      resolved="$(cd "$link_dir" && pwd -P)/$(basename "$target")"
    fi
    if [ -z "$canonical_real" ] || [ ! -f "$resolved" ] || [ "$resolved" != "$canonical_real" ]; then
      broken+=("$target")
    fi
  done < <(grep -oE '\]\([^)]*\)' "$file")
  if [ "$found" -eq 0 ]; then
    fail "$rel に正本 ${canonical_base} への Markdown リンクが無い"
  elif [ "${#broken[@]}" -gt 0 ]; then
    fail "$rel の正本へのリンクが $CANONICAL_REL に解決できない（${broken[*]}）"
  else
    pass "$rel の正本へのリンクがすべて $CANONICAL_REL に解決できる"
  fi
}

echo "=== 1. 正本の存在 ==="

if [ -f "$CANONICAL_FILE" ]; then
  pass "$CANONICAL_REL が存在する"
else
  fail "$CANONICAL_REL が存在しない"
fi

echo ""
echo "=== 2. 各スキルから正本へのリンク ==="

for rel in "${REFERRING_FILES[@]}"; do
  if [ ! -f "$REPO_ROOT/$rel" ]; then
    fail "$rel が存在しない"
    continue
  fi
  check_canonical_links "$rel"
done

finish_tests
