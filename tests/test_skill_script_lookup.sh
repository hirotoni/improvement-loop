#!/usr/bin/env bash
# claude-code/skills/improvement-work/SKILL.md の手順1（check-handoff の解決）と
# 手順8（check-forbidden-allowed-paths の解決）に埋め込まれた「スクリプト実体パスの
# 2候補探索」ブロックが、対象スクリプト名を除いて同一であることを検証する。
#
# この探索処理は意図的に重複して書かれている（共通化しない判断とその理由は
# improvement-work/SKILL.md 手順8の該当箇条書きにある）。重複を残す以上、片方だけが
# 変更されて手順1と手順8で挙動が食い違う事故が起こりうる。これはその検出である。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 15. improvement-work/SKILL.md のスクリプト2候補探索ブロックの一致 ==="

WORK_SKILL_FILE="$SOURCE_SKILLS_DIR/improvement-work/SKILL.md"

# 探索ブロックの範囲の決め方:
#   開始 = `<変数名>=""` だけの行で、次の行が `MAIN_WORKTREE_ROOT=` で始まるもの
#   終了 = 開始以降で最初に現れる行頭 `done`（候補ループの閉じ）
# 目印を MAIN_WORKTREE_ROOT の代入に置いたのは、これが2候補探索に固有の処理であり、
# SKILL.md 内の他の bash ブロックには現れないためである。
extract_lookup_blocks() {
  awk '
    { line[NR] = $0 }
    END {
      for (i = 2; i <= NR; i++) {
        if (line[i] ~ /^MAIN_WORKTREE_ROOT=/ && line[i - 1] ~ /^[A-Za-z_][A-Za-z0-9_]*=""$/) {
          end = 0
          for (j = i; j <= NR; j++) {
            if (line[j] ~ /^done$/) { end = j; break }
          }
          if (end == 0) { continue }
          print "===BLOCK==="
          for (j = i - 1; j <= end; j++) { print line[j] }
        }
      }
    }
  ' "$1"
}

# ブロックから対象スクリプト固有の要素（変数名・スキル名・スクリプト名）を機械的に
# 消し、構造だけを残す。変数名はハードコードせずブロック先頭の初期化行から読み取る。
normalize_lookup_block() {
  local block="$1"
  local var_name
  var_name="$(printf '%s\n' "$block" | sed -n -E '1s/^([A-Za-z_][A-Za-z0-9_]*)=""$/\1/p')"
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

if [ ! -f "$WORK_SKILL_FILE" ]; then
  fail "claude-code/skills/improvement-work/SKILL.md が存在しない"
  finish_tests
fi

blocks_raw="$(extract_lookup_blocks "$WORK_SKILL_FILE")"

BLOCKS=()
current=""
started=0
while IFS= read -r line; do
  if [ "$line" = "===BLOCK===" ]; then
    if [ "$started" -eq 1 ]; then
      BLOCKS+=("$current")
    fi
    started=1
    current=""
    continue
  fi
  [ "$started" -eq 1 ] && current+="$line"$'\n'
done <<<"$blocks_raw"
if [ "$started" -eq 1 ]; then
  BLOCKS+=("$current")
fi

echo ""
echo "--- 15a. 探索ブロックがちょうど2つ抽出できる ---"
if [ "${#BLOCKS[@]}" -eq 2 ]; then
  pass "improvement-work/SKILL.md から2候補探索ブロックを2つ抽出できた（手順1と手順8）"
else
  fail "improvement-work/SKILL.md から抽出できた2候補探索ブロックが2つでない（${#BLOCKS[@]}個）。手順1・手順8のどちらかが消えたか、書式が変わって抽出できなくなった可能性がある"
  finish_tests
fi

echo ""
echo "--- 15b. 2つのブロックが手順1・手順8のものである ---"
# 抽出対象を取り違えていないことの確認。手順1は check-handoff、手順8は
# check-forbidden-allowed-paths を探すブロックであり、この2つ以外は無い。
found_scripts="$(printf '%s\n' "${BLOCKS[@]}" \
  | sed -n -E 's#.*claude-code/skills/[^/"]+/scripts/([^/"]+).*#\1#p' | sort -u)"
expected_scripts="$(printf '%s\n' "check-forbidden-allowed-paths" "check-handoff" | sort -u)"
if [ "$found_scripts" = "$expected_scripts" ]; then
  pass "抽出した2ブロックの対象スクリプトが check-handoff と check-forbidden-allowed-paths である"
else
  fail "抽出した2ブロックの対象スクリプトが想定と異なる:
$(diff <(printf '%s\n' "$expected_scripts") <(printf '%s\n' "$found_scripts"))"
fi

echo ""
echo "--- 15c. 2つのブロックが対象スクリプト名を除いて同一である ---"
normalized_1="$(normalize_lookup_block "${BLOCKS[0]}")"
normalized_2="$(normalize_lookup_block "${BLOCKS[1]}")"
if [ "$normalized_1" = "$normalized_2" ]; then
  pass "手順1と手順8の2候補探索ブロックが、対象スクリプト名を除いて同一である"
else
  fail "improvement-work/SKILL.md の手順1と手順8の2候補探索ブロックが食い違っている（片方だけ変更された可能性がある。探索順を変えるなら両方を同時に直すこと）:
$(diff <(printf '%s\n' "$normalized_1") <(printf '%s\n' "$normalized_2"))"
fi

finish_tests
