#!/usr/bin/env bash
# improvement-loop の依存ゼロの最小テストランナー。依存は bash・git・backlog のみで、
# いずれか欠けていれば各テストファイルがその旨を報告してスキップする
# （テスト対象の不具合として失敗にはしない）。スキップされたファイルも総合サマリーの
# SKIP に計上される。ただし検証が1件も実行されなかった run 自体は FAIL とする
# （後述の「検証が1件も実行されなかった場合の検査」を参照）。
# 任意依存の shellcheck は、無くてもテストは走るが静的検査だけが失われる。未導入なら
# 総合サマリーの直後に警告を出す（後述）。
#
# tests/ 直下の test_*.sh をすべて（登録作業なしに）サブプロセスとして実行し、
# 標準出力をそのまま表示しつつ、各ファイル末尾のサマリー行
# （"PASS: x, FAIL: y, SKIP: z"）を合算して全体を報告する。サマリー行を出さずに
# 終わったファイルは、結果を集計できないので終了ステータスによらず FAIL にする。
#
# 個々のスクリプトのテストだけを実行したい場合は、対応する test_*.sh を直接実行する
# （例: bash tests/test_select_next_task.sh）。
# githooks/pre-commit はこのファイルを唯一のエントリポイントとして実行し、
# 1件でも FAIL があれば非ゼロで終了する。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

# テストファイル単位の内訳。PASS/FAIL/SKIP の件数（アサーション単位）だけでは、
# 「何件のテストファイルが実際に検証を行い、何件が丸ごとスキップされたのか」が
# 総合サマリーから読み取れないため、ファイル単位でも数える。
FILES_EXECUTED=0      # 検証を1件以上実行したファイル
FILES_ALL_SKIPPED=0   # サマリー行は出したが PASS も FAIL も 0 だったファイル（依存不足など）
FILES_UNCOUNTED=0     # サマリー行を出さない等で結果を集計できなかったファイル

SUMMARY_RE='^PASS: ([0-9]+), FAIL: ([0-9]+), SKIP: ([0-9]+)$'

# 実行するテストファイルは tests/ 直下の test_*.sh の実体から列挙する。登録リストを
# 持たないので登録漏れは起こらない。実行順は glob の順（名前順）で、順序に意味は無い。
# 1件も無ければループは回らず、下の「検証が1件も実行されなかった場合の検査」が FAIL にする。
# 配列に溜めずに glob を直接回すのは、macOS 既定の bash 3.2 が set -u 下で空配列の
# "${arr[@]}" を unbound variable として扱うためである。
FILES_TOTAL=0
shopt -s nullglob
for test_path in "$SCRIPT_DIR"/test_*.sh; do
  test_file="$(basename "$test_path")"
  FILES_TOTAL=$((FILES_TOTAL + 1))

  echo ""
  echo "##### $test_file #####"

  output="$(bash "$test_path" 2>&1)"
  exit_code=$?
  printf '%s\n' "$output"

  summary_line="$(printf '%s\n' "$output" | grep -E "$SUMMARY_RE" | tail -1)"
  if [ -n "$summary_line" ] && [[ "$summary_line" =~ $SUMMARY_RE ]]; then
    file_pass="${BASH_REMATCH[1]}"
    file_fail="${BASH_REMATCH[2]}"
    file_skip="${BASH_REMATCH[3]}"
    TOTAL_PASS=$((TOTAL_PASS + file_pass))
    TOTAL_FAIL=$((TOTAL_FAIL + file_fail))
    TOTAL_SKIP=$((TOTAL_SKIP + file_skip))
    # 依存不足で丸ごとスキップされたファイルは SKIP だけが立つ（tests/lib/common.sh の
    # check_test_dependencies を参照）。検証を1件も行っていないので実行済みとは数えない。
    if [ "$((file_pass + file_fail))" -gt 0 ]; then
      FILES_EXECUTED=$((FILES_EXECUTED + 1))
    else
      FILES_ALL_SKIPPED=$((FILES_ALL_SKIPPED + 1))
    fi
  else
    # サマリー行が無いと、そのファイルが何件通って何件落ちたのかを集計できない。
    # 終了ステータスが 0 でも黙って無視せず FAIL にする。以前はここが
    # exit_code != 0 の場合だけの分岐だったため、「サマリー行なし かつ exit 0」の
    # ファイルが PASS/FAIL/SKIP のどこにも計上されずに消えていた（TASK-91）。
    echo "FAIL: $test_file がサマリー行を出力せずに終了した（exit ${exit_code}）"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    FILES_UNCOUNTED=$((FILES_UNCOUNTED + 1))
  fi
done
shopt -u nullglob

echo ""
echo "=== 総合サマリー ==="

# ---- 検証が1件も実行されなかった場合の検査 ----
# 依存（bash・git・backlog）が欠けていると全テストファイルがスキップされ、PASS も
# FAIL も 0 になる。これを exit 0 のまま返すと、githooks/pre-commit のように終了
# ステータスしか見ない利用者からは全件成功と区別がつかず、1件も検証しないまま
# コミットが通る。run 自体の失敗として FAIL を1件加算し、既存の
# 「FAIL が1件でもあれば非ゼロ終了」の経路に乗せる。
if [ "$FILES_TOTAL" -eq 0 ]; then
  echo "FAIL: 検証が1件も実行されなかった（$SCRIPT_DIR 直下に test_*.sh が1つも無い）。"
  TOTAL_FAIL=$((TOTAL_FAIL + 1))
elif [ "$((TOTAL_PASS + TOTAL_FAIL))" -eq 0 ]; then
  printf 'FAIL: 検証が1件も実行されなかった（テストファイル %d件のうち %d件が丸ごとスキップされた）。依存（bash・git・backlog）が揃っているか確認すること。\n' \
    "$FILES_TOTAL" "$FILES_ALL_SKIPPED"
  TOTAL_FAIL=$((TOTAL_FAIL + 1))
fi

printf 'PASS: %d, FAIL: %d, SKIP: %d\n' "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_SKIP"
printf 'テストファイル: 実行 %d件 / 丸ごとスキップ %d件 / 集計不能 %d件（全 %d件）\n' \
  "$FILES_EXECUTED" "$FILES_ALL_SKIPPED" "$FILES_UNCOUNTED" "$FILES_TOTAL"

# ---- shellcheck 未導入の警告 ----
# 未導入だと tests/test_syntax.sh の静的検査が SKIP 1行に畳まれ、長い出力に埋もれる。
# 実行者が必ず読む総合サマリーの直後で知らせる。件数には加算せず、FAIL にもしない。
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "警告: shellcheck が PATH に無いため、tests/test_syntax.sh の静的検査は実行されていない（bash -n は実行済み）。"
  echo "      導入するには: brew install shellcheck"
fi

if [ "$TOTAL_FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
