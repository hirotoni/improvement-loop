#!/usr/bin/env bash
# improvement-loop の依存ゼロの最小テストランナー。依存は bash・git・backlog のみで、
# いずれか欠けていれば各テストファイルがその旨を報告してスキップする
# （テスト対象の不具合として失敗にはしない）。スキップされたファイルも総合サマリーの
# SKIP に計上される。ただし検証が1件も実行されなかった run 自体は FAIL とする
# （後述の「検証が1件も実行されなかった場合の検査」を参照）。
#
# tests/ 配下の対象スクリプトごとの test_*.sh を順にサブプロセスとして実行し、
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

# 実行するテストファイルの一覧であり、実行順序の正本でもある。対象スクリプトが
# 増えたらここに1行追加する。追加を忘れても下の網羅性の検査が FAIL にする。
TEST_FILES=(
  "test_syntax.sh"
  "test_setup_improvement_loop.sh"
  "test_list_opted_in_repos.sh"
  "test_select_next_task.sh"
  "test_merge_reviewed_branch.sh"
  "test_create_worktree.sh"
  "test_pre_commit_hook.sh"
  "test_check_handoff.sh"
  "test_skill_script_lookup.sh"
  "test_check_progress_recovery.sh"
  "test_check_forbidden_allowed_paths.sh"
  "test_backlog_plain_single_source.sh"
  "test_completed_tasks_lookup_single_source.sh"
  "test_run.sh"
)

# tests/ 配下に実在するが意図的に実行しない test_*.sh。通常は空である。
# 除外するときは、なぜ実行しないのかを1行コメントで添えてファイル名を追加する。
EXCLUDED_TEST_FILES=()

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

# テストファイル単位の内訳。PASS/FAIL/SKIP の件数（アサーション単位）だけでは、
# 「何件のテストファイルが実際に検証を行い、何件が丸ごとスキップされたのか」が
# 総合サマリーから読み取れないため、ファイル単位でも数える。
FILES_EXECUTED=0      # 検証を1件以上実行したファイル
FILES_ALL_SKIPPED=0   # サマリー行は出したが PASS も FAIL も 0 だったファイル（依存不足など）
FILES_UNCOUNTED=0     # 実体が無い・サマリー行を出さない等で結果を集計できなかったファイル

SUMMARY_RE='^PASS: ([0-9]+), FAIL: ([0-9]+), SKIP: ([0-9]+)$'

# ---- テストファイルの網羅性の検査 ----
# TEST_FILES はハードコードの列挙なので、tests/ に test_*.sh を足して登録を忘れると
# そのテストは一度も実行されないまま全体サマリーが FAIL: 0 を出し続ける。そこで
# tests/ 配下の実体を動的に列挙し、TEST_FILES と EXCLUDED_TEST_FILES の和集合と
# 一致するかを実行前に検査する。
#
# この検査を新しいテストファイルにせず run.sh 本体に置いたのは、検査自身が
# TEST_FILES への登録を要すると「検査テストの登録漏れ」だけ検知できない入れ子の穴が
# 残るためである。run.sh は登録を読む側なので、この穴が構造的に発生しない。
#
# 一致している場合は PASS を加算せず情報行を出すだけにする（加算すると全体の PASS
# 件数が既存の集計値からずれる）。不一致でも実行ループは打ち切らない（打ち切ると
# 既存テストの結果が読めなくなり、原因の切り分けが難しくなる）。
#
# 集合の比較は配列ではなく改行区切りの文字列に対して行う。macOS 既定の bash 3.2 は
# set -u 下で空配列を "${arr[@]}" と展開すると unbound variable になり、既定で空の
# EXCLUDED_TEST_FILES を素直に回せないためである。
shopt -s nullglob
DISCOVERED_TEST_FILES=()
for discovered_path in "$SCRIPT_DIR"/test_*.sh; do
  DISCOVERED_TEST_FILES+=("$(basename "$discovered_path")")
done
shopt -u nullglob

# 改行区切りの文字列に指定の行がちょうど1行として含まれるか。
# 引数: 探す値, 改行区切りの文字列
contains_line() {
  grep -Fxq -- "$1" <<<"$2"
}

# 各配列を改行区切りの文字列にする（空配列なら空文字列）。
DISCOVERED_LINES=""
if [ "${#DISCOVERED_TEST_FILES[@]}" -gt 0 ]; then
  DISCOVERED_LINES="$(printf '%s\n' "${DISCOVERED_TEST_FILES[@]}")"
fi
REGISTERED_LINES=""
if [ "${#TEST_FILES[@]}" -gt 0 ]; then
  REGISTERED_LINES="$(printf '%s\n' "${TEST_FILES[@]}")"
fi
EXCLUDED_LINES=""
if [ "${#EXCLUDED_TEST_FILES[@]}" -gt 0 ]; then
  EXCLUDED_LINES="$(printf '%s\n' "${EXCLUDED_TEST_FILES[@]}")"
fi

echo "=== テストファイルの網羅性 ==="

COVERAGE_FAIL=0

if [ "${#DISCOVERED_TEST_FILES[@]}" -eq 0 ]; then
  echo "FAIL: $SCRIPT_DIR 配下に test_*.sh が1つも見つからない（テストが1件も実行されない状態になっている）"
  COVERAGE_FAIL=$((COVERAGE_FAIL + 1))
fi

# 1. 実体にあるが TEST_FILES にも EXCLUDED_TEST_FILES にも無い＝登録漏れ。
#    これを検知するのがこの検査の主目的である。
unregistered=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  contains_line "$name" "$REGISTERED_LINES" && continue
  contains_line "$name" "$EXCLUDED_LINES" && continue
  unregistered="$unregistered $name"
done <<<"$DISCOVERED_LINES"
if [ -n "$unregistered" ]; then
  echo "FAIL: tests/ に実在するが tests/run.sh の TEST_FILES に登録されていない test_*.sh がある（このままでは一度も実行されない）:${unregistered}"
  echo "      実行するなら TEST_FILES に、意図的に実行しないなら理由を添えて EXCLUDED_TEST_FILES に追加すること。"
  COVERAGE_FAIL=$((COVERAGE_FAIL + 1))
fi

# 2. EXCLUDED_TEST_FILES にあるが実体が無い＝除外の記述が実体から取り残されている。
#    （TEST_FILES 側の同じ向きの欠落は、下の実行ループが1件ずつ FAIL にする）
stale_excluded=""
conflicting=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if ! contains_line "$name" "$DISCOVERED_LINES"; then
    stale_excluded="$stale_excluded $name"
  fi
  # 3. TEST_FILES と EXCLUDED_TEST_FILES の両方に載っている＝設定の矛盾。
  if contains_line "$name" "$REGISTERED_LINES"; then
    conflicting="$conflicting $name"
  fi
done <<<"$EXCLUDED_LINES"
if [ -n "$stale_excluded" ]; then
  echo "FAIL: EXCLUDED_TEST_FILES に載っているが tests/ に実在しない test_*.sh がある（除外の記述が実体から取り残されている）:${stale_excluded}"
  COVERAGE_FAIL=$((COVERAGE_FAIL + 1))
fi
if [ -n "$conflicting" ]; then
  echo "FAIL: TEST_FILES と EXCLUDED_TEST_FILES の両方に載っている test_*.sh がある（実行するのかしないのかが決まらない）:${conflicting}"
  COVERAGE_FAIL=$((COVERAGE_FAIL + 1))
fi

if [ "$COVERAGE_FAIL" -eq 0 ]; then
  printf 'tests/ 配下の test_*.sh %d件はすべて TEST_FILES または EXCLUDED_TEST_FILES に登録されている（実行対象 %d件 / 意図的な除外 %d件）\n' \
    "${#DISCOVERED_TEST_FILES[@]}" "${#TEST_FILES[@]}" "${#EXCLUDED_TEST_FILES[@]}"
else
  TOTAL_FAIL=$((TOTAL_FAIL + COVERAGE_FAIL))
fi

for test_file in "${TEST_FILES[@]}"; do
  test_path="$SCRIPT_DIR/$test_file"

  if [ ! -f "$test_path" ]; then
    echo "FAIL: テストファイルが見つからない: $test_path"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    FILES_UNCOUNTED=$((FILES_UNCOUNTED + 1))
    continue
  fi

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

echo ""
echo "=== 総合サマリー ==="

# ---- 検証が1件も実行されなかった場合の検査 ----
# 依存（bash・git・backlog）が欠けていると全テストファイルがスキップされ、PASS も
# FAIL も 0 になる。これを exit 0 のまま返すと、githooks/pre-commit のように終了
# ステータスしか見ない利用者からは全件成功と区別がつかず、1件も検証しないまま
# コミットが通る。run 自体の失敗として FAIL を1件加算し、既存の
# 「FAIL が1件でもあれば非ゼロ終了」の経路に乗せる。
if [ "$((TOTAL_PASS + TOTAL_FAIL))" -eq 0 ]; then
  printf 'FAIL: 検証が1件も実行されなかった（テストファイル %d件のうち %d件が丸ごとスキップされた）。依存（bash・git・backlog）が揃っているか確認すること。\n' \
    "${#TEST_FILES[@]}" "$FILES_ALL_SKIPPED"
  TOTAL_FAIL=$((TOTAL_FAIL + 1))
fi

printf 'PASS: %d, FAIL: %d, SKIP: %d\n' "$TOTAL_PASS" "$TOTAL_FAIL" "$TOTAL_SKIP"
printf 'テストファイル: 実行 %d件 / 丸ごとスキップ %d件 / 集計不能 %d件（登録 %d件）\n' \
  "$FILES_EXECUTED" "$FILES_ALL_SKIPPED" "$FILES_UNCOUNTED" "${#TEST_FILES[@]}"

if [ "$TOTAL_FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
