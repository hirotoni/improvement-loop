#!/usr/bin/env bash
# backlog CLI の `--plain` の適用範囲の正本（claude-code/skills/backlog-plain.md）と、
# それを参照する SKILL.md 群に対するテスト。
#
# この知識は以前4つの SKILL.md に独立して複製されており、4箇所が同じ誤りを抱えたまま
# 片方だけ直る事故が起きていた。正本を1つにした後も「説明を親切に書き足す」形で複製が
# 再発しうるため、それを機械的に検知する回帰テストとして置く。

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

echo "=== 1. --plain 適用範囲の正本の内容 ==="

if [ ! -f "$CANONICAL_FILE" ]; then
  fail "$CANONICAL_REL が存在しない"
else
  pass "$CANONICAL_REL が存在する"

  # 正本が「付けるコマンド」「付けないコマンド」の両方を列挙していることを確認する。
  # 片方だけになると、参照側は正本を読んでも判断できない。
  PLAIN_REQUIRED_COMMANDS=(
    "backlog task list"
    "backlog task view"
    "backlog search"
    "backlog milestone list"
  )
  PLAIN_REJECTED_COMMANDS=(
    "backlog config get"
    "backlog config list"
    "backlog instructions"
  )
  missing_commands=()
  for cmd in "${PLAIN_REQUIRED_COMMANDS[@]}" "${PLAIN_REJECTED_COMMANDS[@]}"; do
    if ! grep -Fq "$cmd" "$CANONICAL_FILE"; then
      missing_commands+=("$cmd")
    fi
  done
  if [ "${#missing_commands[@]}" -eq 0 ]; then
    pass "$CANONICAL_REL が --plain を付けるコマンドと付けないコマンドの両方を列挙している"
  else
    fail "$CANONICAL_REL に列挙が欠けているコマンドがある（${missing_commands[*]}）"
  fi

  if grep -Fq "Input schema" "$CANONICAL_FILE"; then
    pass "$CANONICAL_REL が表に無いコマンドの判断方法（--help の Input schema）を書いている"
  else
    fail "$CANONICAL_REL に表に無いコマンドの判断方法（--help の Input schema）が無い"
  fi
fi

echo ""
echo "=== 2. 正本以外に独立した説明が無いこと ==="

# 独立した説明の再発を検知するマーカー。--plain の適用範囲を自前で説明しようとすると、
# 「付けると失敗する側の根拠（エラーメッセージ）」か「表に無いコマンドの判断方法」の
# どちらかをほぼ必ず書くことになるので、この2つを目印に使う。`--plain` 自体は
# コマンド例として各所に正しく現れるため目印にならない。
DUPLICATION_MARKERS=(
  "unknown option '--plain'"
  "Input schema"
)
duplicated_files=()
while IFS= read -r found_file; do
  [ -n "$found_file" ] && duplicated_files+=("$found_file")
done < <(
  for marker in "${DUPLICATION_MARKERS[@]}"; do
    grep -rlF "$marker" "$SOURCE_SKILLS_DIR" "$SOURCE_WORKSPACE_SKILLS_DIR" 2>/dev/null
  done | sort -u | grep -Fxv "$CANONICAL_FILE"
)
if [ "${#duplicated_files[@]}" -eq 0 ]; then
  pass "claude-code/ 配下で --plain の適用範囲を説明しているのは $CANONICAL_REL だけである"
else
  fail "$CANONICAL_REL 以外に --plain の適用範囲の説明が複製されている（正本へ寄せること）: ${duplicated_files[*]}"
fi

echo ""
echo "=== 3. 各スキルからの正本参照 ==="

for rel in "${REFERRING_FILES[@]}"; do
  file="$REPO_ROOT/$rel"
  if [ ! -f "$file" ]; then
    fail "$rel が存在しない"
    continue
  fi

  # リポジトリ相対パス表記と、配布先の .claude/skills/<スキル名> シンボリックリンクから
  # 実体を解決したときに通る相対リンクの両方があることを確認する。導入先には
  # claude-code/skills/ が存在しないため、相対リンクが無いと正本に到達できない。
  case "$rel" in
    claude-code/workspace-skills/*) expected_link="(../../skills/backlog-plain.md)" ;;
    *) expected_link="(../backlog-plain.md)" ;;
  esac

  if ! grep -Fq "$CANONICAL_REL" "$file"; then
    fail "$rel が $CANONICAL_REL をリポジトリ相対パスで参照していない"
  elif ! grep -Fq "$expected_link" "$file"; then
    fail "$rel の正本への相対リンクが $expected_link になっていない（配布先では実体をこの相対パスで解決する）"
  else
    pass "$rel が正本 $CANONICAL_REL を参照している"
  fi
done

finish_tests
