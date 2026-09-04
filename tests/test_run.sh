#!/usr/bin/env bash
# tests/run.sh の集計とスキップの扱いに対するテスト。
#
# run.sh はテストファイルを子プロセスとして起動し、その出力のサマリー行だけを見て
# 全体を集計する。したがって run.sh 自身の検証は、実体の test_*.sh を使わずに、
# 一時ディレクトリへ run.sh を複製し、TEST_FILES と同名のスタブを並べて行える
# （run.sh は SCRIPT_DIR 配下しか見ないので、複製先が閉じた世界になる）。
# こうすると本物のテストを走らせずに、依存不足・全件成功・出力異常の各状況を
# 数秒で再現できる。
#
# あわせて tests/lib/common.sh の check_test_dependencies() が、依存不足時にも
# サマリー行を出力して終了することを、backlog を含まない PATH で実際に検証する。
#
# さらに run.sh の OPTIONAL_DEPENDENCIES（任意依存）の宣言が、実体のテスト・README と
# 食い違わないこと、および未導入時に総合サマリーへ再掲されることを検証する。
#
# 注意: 全角括弧などのマルチバイト文字が直後に続く変数参照は必ず ${VAR} と波括弧で
# 囲む。bash 3.2 は直後のマルチバイト列を変数名の一部として読むため、$VAR）と書くと
# set -u 下で unbound variable になり、その分岐に入った瞬間にテストが落ちる。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 16. tests/run.sh の集計とスキップされたテストファイルの扱い ==="

TOTAL_SUMMARY_RE='^PASS: [0-9]+, FAIL: [0-9]+, SKIP: [0-9]+$'

# run.sh の TEST_FILES に登録されている名前を実体から読む。複製した run.sh は
# 自身の網羅性検査で「登録された名前の実体がそろっていること」を要求するので、
# スタブの名前をここから取る必要がある。
registered_test_names() {
  sed -n '/^TEST_FILES=(/,/^)$/p' "$TESTS_RUNNER_SCRIPT" \
    | sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p'
}

# 引数: 出力先パス, スタブの種類
#   skipped: 依存不足で丸ごとスキップされたファイル（SKIP だけのサマリー行 + exit 0）
#   passing: 検証を2件通したファイル
#   silent:  サマリー行を出さずに exit 0 するファイル（結果を集計できない壊れた状態）
write_stub_test_file() {
  local stub_path="$1"
  local kind="$2"

  case "$kind" in
    skipped)
      cat > "$stub_path" <<'STUB'
#!/usr/bin/env bash
echo "SKIP: このテストの必須依存が無いためスキップする: backlog"
echo ""
echo "=== サマリー ==="
echo "PASS: 0, FAIL: 0, SKIP: 1"
exit 0
STUB
      ;;
    passing)
      cat > "$stub_path" <<'STUB'
#!/usr/bin/env bash
echo "PASS: 何かの検証"
echo "PASS: 別の検証"
echo ""
echo "=== サマリー ==="
echo "PASS: 2, FAIL: 0, SKIP: 0"
exit 0
STUB
      ;;
    silent)
      cat > "$stub_path" <<'STUB'
#!/usr/bin/env bash
echo "サマリー行を出さずに終わる"
exit 0
STUB
      ;;
    *)
      echo "write_stub_test_file: 未知の種類: $kind" >&2
      return 1
      ;;
  esac
}

# 引数: 全スタブの種類, （省略可）先頭の1ファイルだけに使う種類
# 複製先ディレクトリのパスをグローバル変数 STUB_RUNNER_DIR に入れて返す。
#
# 標準出力に返して dir="$(build_stub_runner_dir ...)" と受け取る形にはしない。
# コマンド置換は子シェルなので、その中で呼んだ register_tmp_cleanup() の登録が
# 親シェルの TMP_CLEANUP_PATHS に残らず、EXIT trap の後片付けが一時ディレクトリを
# 取りこぼす（tests/test_syntax.sh の mktemp/register_tmp_cleanup 検査は同一ファイル内に
# 両者が書かれていることしか見ないので、この取りこぼしは検知されない）。
STUB_RUNNER_DIR=""
build_stub_runner_dir() {
  local base_kind="$1"
  local first_kind="${2:-}"

  local dir
  dir="$(mktemp -d)"
  register_tmp_cleanup "$dir"

  cp "$TESTS_RUNNER_SCRIPT" "$dir/run.sh"

  local name
  local is_first=1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$is_first" -eq 1 ] && [ -n "$first_kind" ]; then
      write_stub_test_file "$dir/$name" "$first_kind"
    else
      write_stub_test_file "$dir/$name" "$base_kind"
    fi
    is_first=0
  done <<EOF
$REGISTERED_NAMES
EOF

  STUB_RUNNER_DIR="$dir"
}

# 引数: run.sh の出力
# 標準出力に総合サマリーの行（最後のサマリー行）を返す。
extract_total_summary() {
  printf '%s\n' "$1" | grep -E "$TOTAL_SUMMARY_RE" | tail -1
}

# 捕捉した出力を FAIL メッセージに混ぜるときは字下げする。字下げしないと、
# 出力に含まれるサマリー行を run.sh がこのテストファイルの集計値として拾ってしまう。
indent_output() {
  printf '%s\n' "$1" | sed 's/^/    /'
}

REGISTERED_NAMES="$(registered_test_names)"
REGISTERED_COUNT="$(printf '%s\n' "$REGISTERED_NAMES" | grep -c '[^[:space:]]')"

if [ "$REGISTERED_COUNT" -gt 0 ]; then
  pass "tests/run.sh の TEST_FILES から登録済みテストファイル名を ${REGISTERED_COUNT}件読み取れる"
else
  fail "tests/run.sh の TEST_FILES から登録済みテストファイル名を読み取れない（このテストの前提が崩れている）"
  finish_tests
fi

# ---- 1. 全ファイルが依存不足でスキップされた場合 ----
build_stub_runner_dir skipped
skipped_dir="$STUB_RUNNER_DIR"
skipped_output="$(bash "$skipped_dir/run.sh" 2>&1)"
skipped_exit=$?
skipped_summary="$(extract_total_summary "$skipped_output")"

if [ "$skipped_summary" = "PASS: 0, FAIL: 1, SKIP: $REGISTERED_COUNT" ]; then
  pass "全テストファイルがスキップされたとき、総合サマリーの SKIP がスキップされたファイル数（${REGISTERED_COUNT}件）を反映する"
else
  fail "全テストファイルがスキップされたときの総合サマリーが期待と違う（期待: PASS: 0, FAIL: 1, SKIP: $REGISTERED_COUNT / 実際: ${skipped_summary}）:
$(indent_output "$skipped_output")"
fi

if [ "$skipped_exit" -ne 0 ]; then
  pass "全テストファイルがスキップされたとき、run.sh が非ゼロで終了する（exit ${skipped_exit}）"
else
  fail "全テストファイルがスキップされたのに run.sh が exit 0 で終了した（全件成功と区別できない）"
fi

if printf '%s\n' "$skipped_output" | grep -q "検証が1件も実行されなかった"; then
  pass "全テストファイルがスキップされたとき、検証が1件も実行されなかった旨が出力される"
else
  fail "全テストファイルがスキップされたのに、検証が1件も実行されなかった旨が出力されない:
$(indent_output "$skipped_output")"
fi

if printf '%s\n' "$skipped_output" | grep -q "実行 0件 / 丸ごとスキップ ${REGISTERED_COUNT}件"; then
  pass "総合サマリーにテストファイル単位の内訳（実行 0件 / 丸ごとスキップ ${REGISTERED_COUNT}件）が出力される"
else
  fail "総合サマリーにテストファイル単位の内訳が出力されない:
$(indent_output "$skipped_output")"
fi

# ---- 2. 全ファイルが検証を通した場合（既存の集計を変えていないこと） ----
build_stub_runner_dir passing
passing_dir="$STUB_RUNNER_DIR"
passing_output="$(bash "$passing_dir/run.sh" 2>&1)"
passing_exit=$?
passing_summary="$(extract_total_summary "$passing_output")"
expected_pass=$((REGISTERED_COUNT * 2))

if [ "$passing_summary" = "PASS: $expected_pass, FAIL: 0, SKIP: 0" ]; then
  pass "全テストファイルが成功したとき、総合サマリーが各ファイルの件数の合計（PASS: ${expected_pass}）になる"
else
  fail "全テストファイルが成功したときの総合サマリーが期待と違う（期待: PASS: $expected_pass, FAIL: 0, SKIP: 0 / 実際: ${passing_summary}）:
$(indent_output "$passing_output")"
fi

if [ "$passing_exit" -eq 0 ]; then
  pass "全テストファイルが成功したとき、run.sh が exit 0 で終了する"
else
  fail "全テストファイルが成功したのに run.sh が非ゼロで終了した（exit ${passing_exit}）:
$(indent_output "$passing_output")"
fi

# ---- 3. 一部だけがスキップされた場合（スキップ自体は失敗にしない） ----
build_stub_runner_dir passing skipped
partial_dir="$STUB_RUNNER_DIR"
partial_output="$(bash "$partial_dir/run.sh" 2>&1)"
partial_exit=$?
partial_summary="$(extract_total_summary "$partial_output")"
expected_partial_pass=$(((REGISTERED_COUNT - 1) * 2))

if [ "$partial_summary" = "PASS: $expected_partial_pass, FAIL: 0, SKIP: 1" ]; then
  pass "一部のテストファイルだけがスキップされたとき、そのファイルだけが SKIP に計上される"
else
  fail "一部のテストファイルだけがスキップされたときの総合サマリーが期待と違う（期待: PASS: $expected_partial_pass, FAIL: 0, SKIP: 1 / 実際: ${partial_summary}）:
$(indent_output "$partial_output")"
fi

if [ "$partial_exit" -eq 0 ]; then
  pass "検証が1件でも実行されていれば、スキップされたファイルがあっても run.sh は exit 0 で終了する"
else
  fail "スキップされたファイルがあるだけで run.sh が非ゼロで終了した（exit ${partial_exit}）:
$(indent_output "$partial_output")"
fi

# ---- 4. サマリー行を出さずに exit 0 したファイル（黙って見逃さないこと） ----
build_stub_runner_dir passing silent
silent_dir="$STUB_RUNNER_DIR"
silent_output="$(bash "$silent_dir/run.sh" 2>&1)"
silent_exit=$?
silent_summary="$(extract_total_summary "$silent_output")"

if [ "$silent_summary" = "PASS: $expected_partial_pass, FAIL: 1, SKIP: 0" ]; then
  pass "サマリー行を出さずに exit 0 したテストファイルが FAIL として計上される"
else
  fail "サマリー行を出さずに exit 0 したテストファイルの扱いが期待と違う（期待: PASS: $expected_partial_pass, FAIL: 1, SKIP: 0 / 実際: ${silent_summary}）:
$(indent_output "$silent_output")"
fi

if [ "$silent_exit" -ne 0 ]; then
  pass "サマリー行を出さないテストファイルがあるとき、run.sh が非ゼロで終了する"
else
  fail "サマリー行を出さないテストファイルがあるのに run.sh が exit 0 で終了した:
$(indent_output "$silent_output")"
fi

if printf '%s\n' "$silent_output" | grep -q "実行 $((REGISTERED_COUNT - 1))件 / 丸ごとスキップ 0件 / 集計不能 1件"; then
  pass "総合サマリーの内訳が集計不能なテストファイルを1件として区別する"
else
  fail "総合サマリーの内訳が集計不能なテストファイルを区別していない:
$(indent_output "$silent_output")"
fi

# ---- 5. check_test_dependencies() が依存不足時にサマリー行を出すこと ----
# backlog を含まない PATH で common.sh を source するだけのプローブを実行する。
# PATH には最低限のコマンドだけをシンボリックリンクで並べ、backlog は入れない。
probe_dir="$(mktemp -d)"
register_tmp_cleanup "$probe_dir"
mkdir -p "$probe_dir/bin"

for probe_cmd in bash git dirname basename sed grep rm mkdir cat printf mktemp; do
  probe_src="$(command -v "$probe_cmd" 2>/dev/null)" || continue
  [ -n "$probe_src" ] || continue
  ln -s "$probe_src" "$probe_dir/bin/$probe_cmd" 2>/dev/null
done

cat > "$probe_dir/probe.sh" <<PROBE
#!/usr/bin/env bash
set -uo pipefail
source "$SCRIPT_DIR/lib/common.sh"
check_test_dependencies
pass "依存がそろっているのでここまで到達した"
finish_tests
PROBE

probe_output="$(PATH="$probe_dir/bin" bash "$probe_dir/probe.sh" 2>&1)"
probe_exit=$?
probe_summary="$(extract_total_summary "$probe_output")"

if printf '%s\n' "$probe_output" | grep -q "必須依存が無いためスキップする: backlog"; then
  pass "backlog を含まない PATH では check_test_dependencies() が依存不足を報告する"
else
  fail "backlog を含まない PATH でも check_test_dependencies() が依存不足を報告しない（このテストの前提が崩れている）:
$(indent_output "$probe_output")"
fi

if [ "$probe_summary" = "PASS: 0, FAIL: 0, SKIP: 1" ]; then
  pass "依存不足でスキップするテストファイルもサマリー行（SKIP: 1）を出力する"
else
  fail "依存不足でスキップしたテストファイルのサマリー行が期待と違う（期待: PASS: 0, FAIL: 0, SKIP: 1 / 実際: ${probe_summary}）:
$(indent_output "$probe_output")"
fi

if [ "$probe_exit" -eq 0 ]; then
  pass "依存不足によるスキップは exit 0 のまま（テスト対象の不具合として失敗にしない）"
else
  fail "依存不足によるスキップが非ゼロで終了した（exit ${probe_exit}）:
$(indent_output "$probe_output")"
fi

echo ""
echo "=== 17. tests/run.sh の任意依存（OPTIONAL_DEPENDENCIES）の宣言と報告 ==="
# 任意依存は「無くてもテストは走るが、その依存が担う検査だけが失われる」コマンドである
# （run.sh の OPTIONAL_DEPENDENCIES を参照）。宣言は run.sh の1箇所にしか無いので、
# 実体のテストが本当にその分岐を持っているか・README に説明があるかを機械的に押さえる。
# これが無いと、対象の検査が消えても宣言だけが残る／宣言と README がずれる形で腐る。

# run.sh の OPTIONAL_DEPENDENCIES を実体から読む（TEST_FILES と同じ読み取り方）。
optional_dependency_entries() {
  sed -n '/^OPTIONAL_DEPENDENCIES=(/,/^)$/p' "$TESTS_RUNNER_SCRIPT" \
    | sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p'
}

OPTIONAL_ENTRIES="$(optional_dependency_entries)"
OPTIONAL_COUNT="$(printf '%s\n' "$OPTIONAL_ENTRIES" | grep -c '[^[:space:]]')"

if [ "$OPTIONAL_COUNT" -gt 0 ]; then
  pass "tests/run.sh の OPTIONAL_DEPENDENCIES から任意依存を ${OPTIONAL_COUNT}件読み取れる"
else
  fail "tests/run.sh の OPTIONAL_DEPENDENCIES から任意依存を読み取れない（このテストの前提が崩れている）"
  finish_tests
fi

# ---- 1. 宣言の形式・実体との対応・README の記載 ----
# 走査対象から自分自身（tests/test_run.sh）を除くのは、ここに書く検査コードの中の
# コマンド名を「実体の分岐がある」と誤認しないためである。
optional_malformed=""
optional_unguarded=""
optional_undocumented=""
optional_cmd_names=""
while IFS= read -r optional_entry; do
  [ -n "$optional_entry" ] || continue
  IFS='|' read -r opt_cmd opt_lost opt_install <<<"$optional_entry"

  if [ -z "$opt_cmd" ] || [ -z "$opt_lost" ] || [ -z "$opt_install" ]; then
    optional_malformed="$optional_malformed  $optional_entry"$'\n'
    continue
  fi
  optional_cmd_names="$optional_cmd_names$opt_cmd"$'\n'

  guard_found=0
  for scan_file in "$REPO_ROOT"/tests/test_*.sh "$REPO_ROOT"/tests/lib/*.sh; do
    [ -f "$scan_file" ] || continue
    # 呼び出し方によって ${BASH_SOURCE[0]} は相対パスにもなるので、絶対パスに
    # そろえてから比較する。
    [ "$scan_file" = "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" ] && continue
    if grep -qE "command -v[[:space:]]+$opt_cmd([[:space:]]|\$)" "$scan_file"; then
      guard_found=1
      break
    fi
  done
  if [ "$guard_found" -eq 0 ]; then
    optional_unguarded="$optional_unguarded  $opt_cmd"$'\n'
  fi

  if ! grep -qF -- "$opt_cmd" "$REPO_ROOT/README.md"; then
    optional_undocumented="$optional_undocumented  $opt_cmd"$'\n'
  fi
done <<EOF
$OPTIONAL_ENTRIES
EOF

if [ -z "$optional_malformed" ]; then
  pass "OPTIONAL_DEPENDENCIES の各エントリが「コマンド名|失われる検査|導入方法」の3フィールドをそろえている"
else
  fail "OPTIONAL_DEPENDENCIES に「コマンド名|失われる検査|導入方法」の形式に反するエントリがある:
${optional_malformed%$'\n'}"
fi

if [ -z "$optional_unguarded" ]; then
  pass "OPTIONAL_DEPENDENCIES の各コマンドを tests/ 配下のいずれかが実際に command -v で分岐に使っている"
else
  fail "OPTIONAL_DEPENDENCIES に宣言されているが tests/ 配下のどこも command -v で分岐に使っていないコマンドがある（宣言が実体から取り残されている）:
${optional_unguarded%$'\n'}"
fi

if [ -z "$optional_undocumented" ]; then
  pass "OPTIONAL_DEPENDENCIES の各コマンドが README.md に記載されている"
else
  fail "OPTIONAL_DEPENDENCIES に宣言されているが README.md に記載が無いコマンドがある（導入すべきツールが実行者に伝わらない）:
${optional_undocumented%$'\n'}"
fi

# ---- 2. 任意依存が1件も無い PATH での報告 ----
# 任意依存を含まない最小の PATH を作り、複製した run.sh をそこで動かす。こうすると
# 実環境に任意依存が入っていてもいなくても同じ条件を再現できる。
# 注意: 字下げを含めてハッシュ記号の直後が静的検査ツールの名前で始まる行はディレクティブ
# として解釈され SC1072/SC1073 になる。コメントの語順を変えて避けること。
optional_bin_dir="$(mktemp -d)"
register_tmp_cleanup "$optional_bin_dir"
mkdir -p "$optional_bin_dir/bin"
for optional_base_cmd in bash git dirname basename sed grep tail cat rm mkdir mktemp; do
  # 任意依存そのものは、たとえ基本コマンドと同名でも張らない。
  if printf '%s\n' "$optional_cmd_names" | grep -Fxq -- "$optional_base_cmd"; then
    continue
  fi
  optional_base_src="$(command -v "$optional_base_cmd" 2>/dev/null)" || continue
  [ -n "$optional_base_src" ] || continue
  ln -s "$optional_base_src" "$optional_bin_dir/bin/$optional_base_cmd" 2>/dev/null
done

build_stub_runner_dir passing
optional_missing_dir="$STUB_RUNNER_DIR"
optional_missing_output="$(PATH="$optional_bin_dir/bin" bash "$optional_missing_dir/run.sh" 2>&1)"
optional_missing_exit=$?

optional_report_problems=""
if ! printf '%s\n' "$optional_missing_output" | grep -q "未導入の任意依存: ${OPTIONAL_COUNT}件"; then
  optional_report_problems="$optional_report_problems  総合サマリーに「未導入の任意依存: ${OPTIONAL_COUNT}件」が出ていない"$'\n'
fi
while IFS= read -r optional_entry; do
  [ -n "$optional_entry" ] || continue
  IFS='|' read -r opt_cmd opt_lost opt_install <<<"$optional_entry"
  [ -n "$opt_cmd" ] || continue
  if ! printf '%s\n' "$optional_missing_output" | grep -qF -- "$opt_cmd が PATH に無いため"; then
    optional_report_problems="$optional_report_problems  $opt_cmd の未導入が報告されていない"$'\n'
  fi
  if ! printf '%s\n' "$optional_missing_output" | grep -qF -- "導入するには: $opt_install"; then
    optional_report_problems="$optional_report_problems  $opt_cmd の導入方法（${opt_install}）が報告されていない"$'\n'
  fi
done <<EOF
$OPTIONAL_ENTRIES
EOF

if [ -z "$optional_report_problems" ]; then
  pass "任意依存が1件も無い PATH では、総合サマリーに未導入の任意依存 ${OPTIONAL_COUNT}件が、失われた検査と導入方法つきで再掲される"
else
  fail "任意依存が1件も無い PATH での総合サマリーの再掲が期待と違う:
${optional_report_problems%$'\n'}
$(indent_output "$optional_missing_output")"
fi

if [ "$optional_missing_exit" -eq 0 ]; then
  pass "任意依存が未導入でも run.sh は exit 0 のまま（未導入それ自体をコミットのブロック理由にしない）"
else
  fail "任意依存が未導入というだけで run.sh が非ゼロで終了した（exit ${optional_missing_exit}）:
$(indent_output "$optional_missing_output")"
fi

# ---- 3. 現在の PATH での報告が実態と一致すること ----
# 報告される集合が「実際に command -v で見つからない集合」と一致することを見る。
# 任意依存が全部そろっている環境では、1件も報告しないことの検査になる。
build_stub_runner_dir passing
optional_current_dir="$STUB_RUNNER_DIR"
optional_current_output="$(bash "$optional_current_dir/run.sh" 2>&1)"

expected_missing=""
while IFS= read -r optional_entry; do
  [ -n "$optional_entry" ] || continue
  IFS='|' read -r opt_cmd _opt_lost _opt_install <<<"$optional_entry"
  [ -n "$opt_cmd" ] || continue
  command -v "$opt_cmd" >/dev/null 2>&1 || expected_missing="$expected_missing$opt_cmd"$'\n'
done <<EOF
$OPTIONAL_ENTRIES
EOF

reported_missing="$(printf '%s\n' "$optional_current_output" \
  | sed -n 's/^  - \([^ ]*\) が PATH に無いため.*$/\1/p')"
[ -n "$reported_missing" ] && reported_missing="$reported_missing"$'\n'

if [ "$reported_missing" = "$expected_missing" ]; then
  if [ -z "$expected_missing" ]; then
    pass "現在の PATH では任意依存がすべて導入済みで、未導入の任意依存は1件も報告されない"
  else
    pass "現在の PATH で未導入として報告される任意依存が、実際に見つからないコマンドと一致する"
  fi
else
  fail "現在の PATH で報告される未導入の任意依存が実態と一致しない（期待: [${expected_missing}] / 実際: [${reported_missing}]）:
$(indent_output "$optional_current_output")"
fi

finish_tests
