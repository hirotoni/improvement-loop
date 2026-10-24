#!/usr/bin/env bash
# 起票系スキルが共有する 2 つの正本（claude-code/skills/improvement-scout/backlog-plain.md と
# completed-tasks-lookup.md）を、導入先の配置から字面のまま辿れるかのテスト。
#
# 導入先には claude-code/skills/ が無く、スキルはディレクトリごとに .claude/skills/<スキル名> の
# シンボリックリンクとして置かれる（bin/setup-improvement-loop）。単一リポジトリ経路では
# claude-code/skills/ 配下が、--workspace 経路では claude-code/workspace-skills/ 配下だけが配られる。
# Markdown の相対リンクや、パスを字面で正規化するツールはディレクトリのシンボリックリンクを
# 辿らないので、claude-code/skills/ 直下や claude-code/ 直下を指す `../` は導入先では存在しない
# パスになる。そこで導入先と同じ配置を経路ごとに一時ディレクトリに作り、各 SKILL.md のリンクを
# .claude/skills/<スキル名>/ 起点で `../` を字面で畳んで解決し、正本と同じ内容のファイルに届くかを見る。
# 考え方は tests/test_status_table_reference.sh（状態遷移表の正本）と同じである。
# 文言は照合しない。認識するのはインライン形式 [text](path) のリンクだけである。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

CANONICAL_RELS=(
  "claude-code/skills/improvement-scout/backlog-plain.md"
  "claude-code/skills/improvement-scout/completed-tasks-lookup.md"
)

# 2 つの正本を参照するスキル。<経路>:<スキル名> の形で書く。
# repo は単一リポジトリ経路（claude-code/skills/）、workspace は --workspace 経路（claude-code/workspace-skills/）。
REFERRING_SKILLS=(
  repo:improvement-add
  repo:improvement-scout
  repo:improvement-scout-major
  workspace:workspace-scout-major
)

echo "=== 1. 正本の存在 ==="

for canonical_rel in "${CANONICAL_RELS[@]}"; do
  if [ -f "$REPO_ROOT/$canonical_rel" ]; then
    pass "$canonical_rel が存在する"
  else
    fail "$canonical_rel が存在しない"
  fi
done

echo ""
echo "=== 2. 導入先の配置で各 SKILL.md から正本へ届く ==="

# $1=配布元のスキル群のディレクトリ, $2=導入先のルート。導入先と同じ .claude/skills/<スキル名>
# 配置を作る。
place_install_layout() {
  local source_dir="$1" root="$2" skill_dir
  mkdir -p "$root/.claude/skills"
  for skill_dir in "$source_dir"/*/; do
    ln -s "$source_dir/$(basename "$skill_dir")" "$root/.claude/skills/$(basename "$skill_dir")"
  done
}

REPO_INSTALL_ROOT="$(mktemp -d)"
register_tmp_cleanup "$REPO_INSTALL_ROOT"
place_install_layout "$SOURCE_SKILLS_DIR" "$REPO_INSTALL_ROOT"
WORKSPACE_INSTALL_ROOT="$(mktemp -d)"
register_tmp_cleanup "$WORKSPACE_INSTALL_ROOT"
place_install_layout "$SOURCE_WORKSPACE_SKILLS_DIR" "$WORKSPACE_INSTALL_ROOT"

# $1=導入先のルート, $2=スキル名, $3=正本のリポジトリ相対パス。SKILL.md 中の正本のファイル名を
# 指すリンクがすべて、導入先の配置で `../` の字面の解決だけで正本と同じ内容のファイルへ届くことを
# 確かめる。リンクが 1 つも無ければ FAIL。
check_shared_doc_link() {
  local root="$1" skill="$2" canonical_rel="$3"
  local file="$root/.claude/skills/$skill/SKILL.md"
  local canonical_file="$REPO_ROOT/$canonical_rel" canonical_base target base rest
  local found=0 broken=()
  canonical_base="$(basename "$canonical_rel")"
  if [ ! -f "$file" ]; then
    fail "$skill/SKILL.md が導入先の配置（.claude/skills/${skill}）に存在しない"
    return
  fi
  while IFS= read -r target; do
    target="${target#](}"
    target="${target%)}"
    target="${target%%#*}"
    [ "$(basename "$target")" = "$canonical_base" ] || continue
    found=1
    base="$root/.claude/skills/$skill"
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
    if [ ! -f "$canonical_file" ] || [ ! -f "$base/$rest" ] || ! cmp -s "$base/$rest" "$canonical_file"; then
      broken+=("$target")
    fi
  done < <(grep -oE '\]\([^)]*\)' "$file")
  if [ "$found" -eq 0 ]; then
    fail "$skill/SKILL.md に ${canonical_base} への Markdown リンクが無い"
  elif [ "${#broken[@]}" -gt 0 ]; then
    fail "$skill/SKILL.md の ${canonical_base} へのリンクが導入先の配置（.claude/skills/${skill}）で正本に届かない（${broken[*]}）"
  else
    pass "$skill/SKILL.md の ${canonical_base} へのリンクが導入先の配置（.claude/skills/${skill}）でも正本に届く"
  fi
}

for entry in "${REFERRING_SKILLS[@]}"; do
  case "${entry%%:*}" in
    repo) install_root="$REPO_INSTALL_ROOT" ;;
    workspace) install_root="$WORKSPACE_INSTALL_ROOT" ;;
    *) fail "REFERRING_SKILLS の経路が不正: $entry"; continue ;;
  esac
  for canonical_rel in "${CANONICAL_RELS[@]}"; do
    check_shared_doc_link "$install_root" "${entry#*:}" "$canonical_rel"
  done
done

finish_tests
