#!/usr/bin/env bash
# 状態遷移表の正本（claude-code/skills/improvement-dispatch/status-table.md）と、それを
# 冒頭で参照する 5 つの SKILL.md に対するテスト。
#
# 導入先には claude-code/skills/ が無く、スキルはディレクトリごとに .claude/skills/<スキル名> の
# シンボリックリンクとして置かれる（bin/setup-improvement-loop）。Markdown の相対リンクや、パスを
# 字面で正規化するツールはシンボリックリンクを辿らないので、`../status-table.md` のように
# claude-code/skills/ 直下を指す参照は導入先では存在しない .claude/skills/status-table.md になる。
# そこで導入先と同じ配置を一時ディレクトリに作り、各 SKILL.md のリンクを
# .claude/skills/<スキル名>/ 起点で `../` を字面で畳んで解決し、正本と同じ内容のファイルに届くかを見る。
# 文言は照合しない。認識するのはインライン形式 [text](path) のリンクだけである。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

CANONICAL_REL="claude-code/skills/improvement-dispatch/status-table.md"
CANONICAL_FILE="$REPO_ROOT/$CANONICAL_REL"

# 状態遷移表の正本を参照するスキル。
REFERRING_SKILLS=(
  improvement-dispatch
  improvement-work
  improvement-scout
  improvement-scout-major
  improvement-add
)

echo "=== 1. 正本の存在 ==="

if [ -f "$CANONICAL_FILE" ]; then
  pass "$CANONICAL_REL が存在する"
else
  fail "$CANONICAL_REL が存在しない"
fi

echo ""
echo "=== 2. 導入先の配置で各 SKILL.md から正本へ届く ==="

INSTALL_ROOT="$(mktemp -d)"
register_tmp_cleanup "$INSTALL_ROOT"
mkdir -p "$INSTALL_ROOT/.claude/skills"
for skill_dir in "$SOURCE_SKILLS_DIR"/*/; do
  skill_name="$(basename "$skill_dir")"
  ln -s "$SOURCE_SKILLS_DIR/$skill_name" "$INSTALL_ROOT/.claude/skills/$skill_name"
done

# $1=スキル名。SKILL.md 中の status-table.md を指すリンクがすべて、導入先の配置で
# 物理解決なしに正本と同じ内容のファイルへ届くことを確かめる。リンクが 1 つも無ければ FAIL。
check_status_table_link() {
  local skill="$1" file="$SOURCE_SKILLS_DIR/$1/SKILL.md" target base rest
  local found=0 broken=()
  if [ ! -f "$file" ]; then
    fail "$skill/SKILL.md が存在しない"
    return
  fi
  while IFS= read -r target; do
    target="${target#](}"
    target="${target%)}"
    target="${target%%#*}"
    [ "$(basename "$target")" = "status-table.md" ] || continue
    found=1
    base="$INSTALL_ROOT/.claude/skills/$skill"
    rest="$target"
    while [ "${rest#./}" != "$rest" ] || [ "${rest#../}" != "$rest" ]; do
      if [ "${rest#./}" != "$rest" ]; then
        rest="${rest#./}"
      else
        base="$(dirname "$base")"
        rest="${rest#../}"
      fi
    done
    case "$rest" in
      # 途中に ../ が残る形や絶対パスは、字面の解決を正しく模擬できないので届かないものとみなす。
      /* | */../* | */./*) broken+=("$target"); continue ;;
    esac
    if [ ! -f "$CANONICAL_FILE" ] || [ ! -f "$base/$rest" ] || ! cmp -s "$base/$rest" "$CANONICAL_FILE"; then
      broken+=("$target")
    fi
  done < <(grep -oE '\]\([^)]*\)' "$file")
  if [ "$found" -eq 0 ]; then
    fail "$skill/SKILL.md に status-table.md への Markdown リンクが無い"
  elif [ "${#broken[@]}" -gt 0 ]; then
    fail "$skill/SKILL.md の status-table.md へのリンクが導入先の配置（.claude/skills/${skill}）で正本に届かない（${broken[*]}）"
  else
    pass "$skill/SKILL.md の status-table.md へのリンクが導入先の配置（.claude/skills/${skill}）でも正本に届く"
  fi
}

for skill in "${REFERRING_SKILLS[@]}"; do
  check_status_table_link "$skill"
done

finish_tests
