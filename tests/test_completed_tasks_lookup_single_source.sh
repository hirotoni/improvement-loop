#!/usr/bin/env bash
# 完了・アーカイブ済みタスクの照合手順の正本（claude-code/skills/completed-tasks-lookup.md）と、
# それを参照する起票系スキルの SKILL.md に対するテスト。
#
# backlog CLI の task list / search / view は .backlog/tasks/ しか見ないため、正本の走査手順は
# 散文ではなく実際に動く grep でなければ意味が無い。ここでは正本から bash ブロックを抜き出して
# 使い捨ての .backlog/ 構造に対して実行し、completed / archive 配下が実際に照合と集計に
# 乗ることを確かめる。あわせて、参照側の各スキルから正本へのリンクが実際に解決できることを確かめる。
# 参照側の文言は照合しない（言い換えで落ちず、食い違いも捕まえられないため）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

CANONICAL_REL="claude-code/skills/completed-tasks-lookup.md"
CANONICAL_FILE="$REPO_ROOT/$CANONICAL_REL"

# 正本を参照する側のファイル（リポジトリルートからの相対パス）。
REFERRING_FILES=(
  "claude-code/skills/improvement-scout/SKILL.md"
  "claude-code/skills/improvement-add/SKILL.md"
  "claude-code/skills/improvement-scout-major/SKILL.md"
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

if [ ! -f "$CANONICAL_FILE" ]; then
  fail "$CANONICAL_REL が存在しない"
  finish_tests
fi
pass "$CANONICAL_REL が存在する"

echo ""
echo "=== 2. 各スキルから正本へのリンク ==="

for rel in "${REFERRING_FILES[@]}"; do
  if [ ! -f "$REPO_ROOT/$rel" ]; then
    fail "$rel が存在しない"
    continue
  fi
  check_canonical_links "$rel"
done

# 観点集計が CLI 単独の数え方に戻っていないこと。
SCOUT_SKILL="$REPO_ROOT/claude-code/skills/improvement-scout/SKILL.md"
if grep -Fq -- "--labels \"viewpoint:" "$SCOUT_SKILL"; then
  fail "improvement-scout/SKILL.md が backlog task list --labels で観点を数えている（完了・アーカイブ済みが件数から落ちる）"
else
  pass "improvement-scout/SKILL.md が観点集計を正本に委ねている"
fi

echo ""
echo "=== 3. 正本のコマンドが completed / archive を実際に拾うこと ==="

# 正本の N 番目の ```bash ブロックの中身を取り出す。
extract_bash_block() {
  awk -v want="$2" '
    /^[[:space:]]*```bash[[:space:]]*$/ { if (!inb) { inb = 1; num++; next } }
    /^[[:space:]]*```[[:space:]]*$/     { if (inb)  { inb = 0; next } }
    inb && num == want { print }
  ' "$1"
}

PRELUDE_BLOCK="$(extract_bash_block "$CANONICAL_FILE" 1)"
KEYWORD_BLOCK="$(extract_bash_block "$CANONICAL_FILE" 2)"
PATH_BLOCK="$(extract_bash_block "$CANONICAL_FILE" 3)"
TALLY_BLOCK="$(extract_bash_block "$CANONICAL_FILE" 4)"

blocks_ok=1
for pair in "前置き:$PRELUDE_BLOCK" "キーワード照合:$KEYWORD_BLOCK" "パス照合:$PATH_BLOCK" "観点集計:$TALLY_BLOCK"; do
  if [ -z "$(printf '%s' "${pair#*:}" | tr -d '[:space:]')" ]; then
    fail "$CANONICAL_REL から「${pair%%:*}」の bash ブロックを取り出せない（ブロックの順序か本数が変わっている）"
    blocks_ok=0
  fi
done
if [ "$blocks_ok" -eq 1 ]; then
  pass "$CANONICAL_REL から4つの bash ブロック（前置き・キーワード照合・パス照合・観点集計）を取り出せた"
fi

if [ "$blocks_ok" -eq 1 ]; then
  FIXTURE_DIR="$(mktemp -d)"
  register_tmp_cleanup "$FIXTURE_DIR"

  mkdir -p "$FIXTURE_DIR/.backlog/tasks" \
           "$FIXTURE_DIR/.backlog/completed" \
           "$FIXTURE_DIR/.backlog/archive/tasks" \
           "$FIXTURE_DIR/.claude/skills/improvement-scout"

  # 観点リストは見出しから読まれるので、実物と同じ形で2観点だけ置く。
  cat > "$FIXTURE_DIR/.claude/skills/improvement-scout/viewpoints.md" <<'FIXTURE_EOF'
## alpha-viewpoint
## beta-viewpoint
## gamma-viewpoint
FIXTURE_EOF

  # tasks/ 配下（CLI からも見える）に1件。
  cat > "$FIXTURE_DIR/.backlog/tasks/task-1 - open.md" <<'FIXTURE_EOF'
---
id: TASK-1
labels:
  - 'viewpoint:alpha-viewpoint'
modified_files:
  - src/target.txt
---
FIXTURE_EOF

  # completed/ 配下（CLI から見えない）に1件。照合で拾えなければならない本命。
  cat > "$FIXTURE_DIR/.backlog/completed/task-2 - done.md" <<'FIXTURE_EOF'
---
id: TASK-2
labels:
  - 'viewpoint:alpha-viewpoint'
modified_files:
  - src/target.txt
---
一意キーワード_ズィグラト について直した。
FIXTURE_EOF

  # archive/tasks/ 配下（CLI から見えない）に1件。
  cat > "$FIXTURE_DIR/.backlog/archive/tasks/task-3 - archived.md" <<'FIXTURE_EOF'
---
id: TASK-3
labels:
  - 'viewpoint:alpha-viewpoint'
---
FIXTURE_EOF

  # おとり。ラベルにもフロントマターの modified_files にも入れず、本文にだけ
  # 同じ文字列を書く。行を固定していない緩い grep だとこれを数えてしまう。
  cat > "$FIXTURE_DIR/.backlog/completed/task-4 - decoy.md" <<'FIXTURE_EOF'
---
id: TASK-4
labels: []
---
検証: bash src/target.txt を実行した。viewpoint:alpha-viewpoint の話ではない。
FIXTURE_EOF

  # task_prefix をカスタマイズしたリポジトリの1件。ファイル名も ID も task/TASK- にならない。
  # この観点はこのファイルにしか付いていないので、集計がタスク ID の接頭辞に依存していれば
  # gamma-viewpoint が 0 になって落ちる（TASK-54 と同型の退行の検知）。
  cat > "$FIXTURE_DIR/.backlog/completed/issue-5 - custom prefix.md" <<'FIXTURE_EOF'
---
id: ISSUE-5
labels:
  - 'viewpoint:gamma-viewpoint'
---
FIXTURE_EOF

  run_recipe() {
    local body="$1"
    local script="$FIXTURE_DIR/_recipe.sh"
    printf '%s\n%s\n' "$PRELUDE_BLOCK" "$body" > "$script"
    (cd "$FIXTURE_DIR" && bash "$script" 2>&1)
  }

  # 3a. キーワード照合が completed 配下を拾うこと。
  keyword_body="$(printf '%s\n' "$KEYWORD_BLOCK" | sed 's|<キーワード>|一意キーワード_ズィグラト|')"
  keyword_out="$(run_recipe "$keyword_body")"
  if printf '%s\n' "$keyword_out" | grep -Fq "completed/task-2 - done.md"; then
    pass "キーワード照合が .backlog/completed/ のタスクを拾う"
  else
    fail "キーワード照合が .backlog/completed/ のタスクを拾えない（出力: ${keyword_out}）"
  fi

  # 3b. パス照合が completed 配下の modified_files を拾い、本文だけの言及は拾わないこと。
  path_body="$(printf '%s\n' "$PATH_BLOCK" | sed 's|<対象パス>|src/target.txt|')"
  path_out="$(run_recipe "$path_body")"
  if printf '%s\n' "$path_out" | grep -Fq "completed/task-2 - done.md"; then
    pass "パス照合が .backlog/completed/ の modified_files を拾う"
  else
    fail "パス照合が .backlog/completed/ の modified_files を拾えない（出力: ${path_out}）"
  fi
  if printf '%s\n' "$path_out" | grep -Fq "completed/task-4 - decoy.md"; then
    fail "パス照合が本文中の言及だけのタスクまで拾っている（--modified-file 相当にならない。出力: ${path_out}）"
  else
    pass "パス照合が本文中の言及だけのタスクを拾わない"
  fi

  # 3c. 観点集計が tasks + completed + archive の実数を返すこと。
  tally_out="$(run_recipe "$TALLY_BLOCK")"
  alpha_count="$(printf '%s\n' "$tally_out" | awk -F'\t' '$1 == "alpha-viewpoint" { print $2 }')"
  beta_count="$(printf '%s\n' "$tally_out" | awk -F'\t' '$1 == "beta-viewpoint" { print $2 }')"
  if [ "$alpha_count" = "3" ]; then
    pass "観点集計が tasks(1) + completed(1) + archive(1) = 3 を返す（tasks だけなら1にとどまる）"
  else
    fail "観点集計が実数を返さない（alpha-viewpoint に 3 を期待したが '$alpha_count'。出力: ${tally_out}）"
  fi
  if [ "$beta_count" = "0" ]; then
    pass "起票実績の無い観点は 0 を返す"
  else
    fail "起票実績の無い観点が 0 にならない（beta-viewpoint に 0 を期待したが '$beta_count'。出力: ${tally_out}）"
  fi
  gamma_count="$(printf '%s\n' "$tally_out" | awk -F'\t' '$1 == "gamma-viewpoint" { print $2 }')"
  if [ "$gamma_count" = "1" ]; then
    pass "観点集計がタスク ID の接頭辞に依存しない（ID が ISSUE-5 のタスクも数える）"
  else
    fail "観点集計がタスク ID の接頭辞に依存している（gamma-viewpoint に 1 を期待したが '$gamma_count'。出力: ${tally_out}）"
  fi
fi

finish_tests
