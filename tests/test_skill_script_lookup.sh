#!/usr/bin/env bash
# claude-code/skills/improvement-work/SKILL.md に埋め込まれた「スクリプト実体パスの
# 2候補探索」ブロック 5 つが、対象スクリプト名を除いて同一であることを検証する。
# 対象は手順1の check-handoff、手順5・7の touch-occupancy、手順8の
# check-forbidden-allowed-paths と backlog-config-snapshot である。
#
# この探索処理は意図的に重複して書かれている（共通化しない判断とその理由は
# improvement-work/SKILL.md 手順8の該当箇条書きにある）。重複を残す以上、1 ブロック
# だけが変更されて手順ごとに挙動が食い違う事故が起こりうる。これはその検出である。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

WORK_SKILL_FILE="$SOURCE_SKILLS_DIR/improvement-work/SKILL.md"

# 探索ブロックの対象スクリプト。手順5と手順7は同じ touch-occupancy を探す。
EXPECTED_LOOKUP_SCRIPTS="backlog-config-snapshot
check-forbidden-allowed-paths
check-handoff
touch-occupancy
touch-occupancy"
EXPECTED_LOOKUP_BLOCK_COUNT=5

# 探索ブロックの範囲の決め方:
#   目印 = 行頭の空白を除いて `for candidate in \` だけの行
#   範囲 = 目印の直前 2 行（`<変数名>=""` と `MAIN_WORKTREE_ROOT=`）から、
#          目印と同じインデントの最初の `done` まで
# 手順5・7 は箇条書きの中の bash ブロックなのでインデントが付く。直前 2 行の並びは、
# 手順5・7 と手順8後半（backlog-config-snapshot）で手順1 とは逆である。インデントは目印の行の分だけ全行から除き、直前 2 行は
# MAIN_WORKTREE_ROOT= を先に並べ替えて、書き方の差ではなく探索の中身を比べる。
# 対応する done が無いブロックは `===BROKEN===` として出力する。
extract_lookup_blocks() {
  awk '
    function dedent(s, indent) {
      if (substr(s, 1, length(indent)) == indent) { return substr(s, length(indent) + 1) }
      return s
    }
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (line[i] !~ /^[ ]*for candidate in \\$/) { continue }
        indent = line[i]
        sub(/for candidate in \\$/, "", indent)
        end = 0
        for (j = i + 1; j <= NR; j++) {
          if (line[j] == indent "done") { end = j; break }
        }
        if (end == 0 || i < 3) { print "===BROKEN==="; continue }
        print "===BLOCK==="
        h1 = dedent(line[i - 2], indent)
        h2 = dedent(line[i - 1], indent)
        if (h2 ~ /^MAIN_WORKTREE_ROOT=/) { print h2; print h1 } else { print h1; print h2 }
        for (j = i; j <= end; j++) { print dedent(line[j], indent) }
      }
    }
  ' "$1"
}

# ブロックから対象スクリプト固有の要素（変数名・スキル名・スクリプト名）を機械的に
# 消し、構造だけを残す。変数名はハードコードせず、ループ内の `<変数名>="$candidate"`
# の行から読み取る。
normalize_lookup_block() {
  local block="$1"
  local var_name
  var_name="$(printf '%s\n' "$block" | sed -n -E 's/^[ ]*([A-Za-z_][A-Za-z0-9_]*)="[$]candidate"$/\1/p' | head -1)"
  if [ -z "$var_name" ]; then
    printf '%s\n' "$block"
    return
  fi
  # 変数名は英数字と _ だけなのでそのまま正規表現として使ってよい。
  # `claude-code/skills/...` と `.claude/skills/...` は別の文字列なので置換が食い合わない。
  printf '%s\n' "$block" \
    | sed -E "s#${var_name}#SCRIPT_VAR#g" \
    | sed -E 's#claude-code/skills/[^/"]+/scripts/[^/"]+#claude-code/skills/SKILL_NAME/scripts/SCRIPT_NAME#g' \
    | sed -E 's#\.claude/skills/[^/"]+/scripts/[^/"]+#.claude/skills/SKILL_NAME/scripts/SCRIPT_NAME#g'
}

# lookup_block_problems <SKILL.md のパス>
# 探索ブロックの検査で見つかった問題を標準出力に書く。問題が無ければ何も書かない。
# 実物の SKILL.md の検査と、下の変異テスト（壊した複製で問題が検出されること）の
# 両方で同じ判定を使うために関数にしている。
lookup_block_problems() {
  local file="$1"
  local blocks_raw raw_count broken_count found_scripts
  local blocks=()
  local current="" started=0 line i normalized_first normalized_i

  raw_count="$(grep -cE '^[ ]*for candidate in' "$file")"
  blocks_raw="$(extract_lookup_blocks "$file")"
  broken_count="$(grep -c '^===BROKEN===$' <<<"$blocks_raw")"

  while IFS= read -r line; do
    if [ "$line" = "===BLOCK===" ] || [ "$line" = "===BROKEN===" ]; then
      if [ "$started" -eq 1 ]; then
        blocks+=("$current")
      fi
      started=0
      [ "$line" = "===BLOCK===" ] && started=1
      current=""
      continue
    fi
    [ "$started" -eq 1 ] && current+="$line"$'\n'
  done <<<"$blocks_raw"
  if [ "$started" -eq 1 ]; then
    blocks+=("$current")
  fi

  # 書式が変わって目印に当たらなくなったブロックは、`for candidate in` の出現数と
  # 抽出数の差として現れる。
  if [ "$broken_count" -gt 0 ] || [ "${#blocks[@]}" -ne "$raw_count" ]; then
    echo "\`for candidate in\` が ${raw_count} か所あるが、探索ブロックとして抽出できたのは ${#blocks[@]} 個（対応する done が見つからないもの ${broken_count} 個）。書式が変わって抽出できなくなった可能性がある"
  fi
  if [ "${#blocks[@]}" -ne "$EXPECTED_LOOKUP_BLOCK_COUNT" ]; then
    echo "探索ブロックが ${EXPECTED_LOOKUP_BLOCK_COUNT} 個でない（${#blocks[@]} 個）。どれかが消えたか、書式が変わって抽出できなくなった可能性がある"
    return
  fi

  # 抽出対象を取り違えていないことの確認。
  found_scripts="$(printf '%s\n' "${blocks[@]}" \
    | sed -n -E 's#.*claude-code/skills/[^/"]+/scripts/([^/"]+).*#\1#p' | sort)"
  if [ "$found_scripts" != "$EXPECTED_LOOKUP_SCRIPTS" ]; then
    echo "探索ブロックの対象スクリプトが想定と異なる:"
    diff <(printf '%s\n' "$EXPECTED_LOOKUP_SCRIPTS") <(printf '%s\n' "$found_scripts")
  fi

  # 1 ブロックの 2 候補が同じスキル・同じスクリプトを指していること。下の正規化は
  # 候補ごとに名前を伏せるので、ここで見ておかないと食い違いを見逃す。
  for ((i = 0; i < ${#blocks[@]}; i++)); do
    if [ "$(printf '%s' "${blocks[$i]}" | sed -n -E 's#.*/skills/([^/"]+/scripts/[^/"]+)".*#\1#p' | sort -u | wc -l | tr -d ' ')" -ne 1 ]; then
      echo "$((i + 1)) 番目の探索ブロックの 2 つの候補が、別のスキルまたは別のスクリプトを指している"
    fi
  done

  normalized_first="$(normalize_lookup_block "${blocks[0]}")"
  for ((i = 1; i < ${#blocks[@]}; i++)); do
    normalized_i="$(normalize_lookup_block "${blocks[$i]}")"
    if [ "$normalized_i" != "$normalized_first" ]; then
      echo "$((i + 1)) 番目の探索ブロックが 1 番目（手順1）と食い違っている（1 ブロックだけ変更された可能性がある。探索順を変えるなら全ブロックを同時に直すこと）:"
      diff <(printf '%s\n' "$normalized_first") <(printf '%s\n' "$normalized_i")
    fi
  done
}

# mutate_skill_file <出力先> <awk プログラム>: SKILL.md の複製に変異を加えて書き出す。
# awk には変数 target（何番目の探索ブロックを壊すか）を -v で渡す。
MUTATION_DIR="$(mktemp -d)"
register_tmp_cleanup "$MUTATION_DIR"
MUTATION_SEQ=0

# k 番目の探索ブロックだけ、2 つの候補の順序を入れ替える。
# shellcheck disable=SC2016  # awk のプログラムなので $ は awk が解釈する
swap_candidates_awk='
  { line[NR] = $0 }
  END {
    n = 0
    for (i = 1; i <= NR; i++) {
      if (line[i] ~ /for candidate in \\$/ && ++n == target) {
        a = line[i + 1]; b = line[i + 2]
        match(a, /"[^"]*"/); qa = substr(a, RSTART, RLENGTH)
        match(b, /"[^"]*"/); qb = substr(b, RSTART, RLENGTH)
        sa = index(a, qa); sb = index(b, qb)
        line[i + 1] = substr(a, 1, sa - 1) qb substr(a, sa + length(qa))
        line[i + 2] = substr(b, 1, sb - 1) qa substr(b, sb + length(qb))
      }
    }
    for (i = 1; i <= NR; i++) { print line[i] }
  }
'

# k 番目の探索ブロックの `for candidate in` から対応する done までを消す。
# shellcheck disable=SC2016  # awk のプログラムなので $ は awk が解釈する
delete_block_awk='
  /for candidate in \\$/ && ++n == target { skipping = 1; indent = $0; sub(/for candidate in \\$/, "", indent) }
  skipping { if ($0 == indent "done") { skipping = 0 } ; next }
  { print }
'

# k 番目の探索ブロックの候補を 1 行に詰め、行継続の `\` を無くす。
# shellcheck disable=SC2016  # awk のプログラムなので $ は awk が解釈する
join_candidates_awk='
  { line[NR] = $0 }
  END {
    n = 0
    for (i = 1; i <= NR; i++) {
      if (line[i] ~ /for candidate in \\$/ && ++n == target) {
        a = line[i + 1]; b = line[i + 2]
        sub(/ \\$/, "", line[i]); sub(/^ */, "", a); sub(/ \\$/, "", a); sub(/^ */, "", b)
        print line[i] " " a " " b
        i += 2
        continue
      }
      print line[i]
    }
  }
'

# k 番目の探索ブロックの done のインデントを変え、対応する done を見つけられなくする。
# shellcheck disable=SC2016  # awk のプログラムなので $ は awk が解釈する
reindent_done_awk='
  /for candidate in \\$/ && ++n == target { inblock = 1; indent = $0; sub(/for candidate in \\$/, "", indent) }
  inblock && $0 == indent "done" { print indent "   done"; inblock = 0; next }
  { print }
'

# k 番目の探索ブロックの 2 つ目の候補だけ、別のスクリプトを指すように変える。
# shellcheck disable=SC2016  # awk のプログラムなので $ は awk が解釈する
mismatch_candidate_awk='
  { line[NR] = $0 }
  END {
    n = 0
    for (i = 1; i <= NR; i++) {
      if (line[i] ~ /for candidate in \\$/ && ++n == target) {
        sub(/\/scripts\/[^\/"]+"/, "/scripts/other-script\"", line[i + 2])
      }
    }
    for (i = 1; i <= NR; i++) { print line[i] }
  }
'

# expect_mutation_detected <ラベル> <awk プログラム> <target>
expect_mutation_detected() {
  local label="$1" program="$2" target="$3"
  local mutated
  local problems
  MUTATION_SEQ=$((MUTATION_SEQ + 1))
  mutated="$MUTATION_DIR/SKILL.md.$MUTATION_SEQ"
  awk -v target="$target" "$program" "$WORK_SKILL_FILE" >"$mutated"
  if cmp -s "$mutated" "$WORK_SKILL_FILE"; then
    fail "$label: 変異が加わらなかった（変異テストの前提が崩れている）"
    return
  fi
  problems="$(lookup_block_problems "$mutated")"
  if [ -n "$problems" ]; then
    pass "$label"
  else
    fail "$label: 変異を加えた SKILL.md で問題が検出されなかった"
  fi
}

echo "=== 1. improvement-work/SKILL.md のスクリプト2候補探索ブロックの一致 ==="

if [ ! -f "$WORK_SKILL_FILE" ]; then
  fail "claude-code/skills/improvement-work/SKILL.md が存在しない"
  finish_tests
fi

echo ""
echo "--- 1a. 5 つの探索ブロックを抽出でき、対象スクリプト名を除いて同一である ---"
problems="$(lookup_block_problems "$WORK_SKILL_FILE")"
if [ -z "$problems" ]; then
  pass "improvement-work/SKILL.md の 5 つの探索ブロックが、対象スクリプト名を除いて同一である"
else
  fail "improvement-work/SKILL.md の探索ブロックに問題がある:
$problems"
  # 実物が既に食い違っていると、下の変異で一致に戻ることがあり、原因を取り違えた
  # FAIL が増えるだけなので、変異テストは行わない。
  finish_tests
fi

echo ""
echo "--- 1b. どれか 1 ブロックだけ候補の順序を入れ替えると検出される ---"
for k in 1 2 3 4 5; do
  expect_mutation_detected "${k} 番目の探索ブロックだけ候補の順序を入れ替えると検出される" "$swap_candidates_awk" "$k"
done

echo ""
echo "--- 1c. 探索ブロックが消えたり書式が変わったりすると検出される ---"
for k in 1 5; do
  expect_mutation_detected "${k} 番目の探索ブロックを消すと検出される" "$delete_block_awk" "$k"
done
expect_mutation_detected "探索ブロックの候補を 1 行に詰めて抽出できなくすると検出される" "$join_candidates_awk" 2
expect_mutation_detected "探索ブロックの done のインデントを変えて範囲を決められなくすると検出される" "$reindent_done_awk" 3
expect_mutation_detected "探索ブロックの 2 つの候補が別のスクリプトを指すと検出される" "$mismatch_candidate_awk" 4

finish_tests
