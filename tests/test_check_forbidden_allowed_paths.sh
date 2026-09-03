#!/usr/bin/env bash
# tests/test_check_forbidden_allowed_paths.sh
#
# claude-skills/improvement-dispatch/scripts/check-forbidden-allowed-paths に
# 対するテスト。単体で実行すると、このファイルの検証だけが走る。
# tests/run.sh から全体実行の一部としても呼ばれる。
#
# 依存は bash/zsh・git・backlog のみ。いずれか欠けていれば、その旨を
# 報告してスキップする（テスト対象の不具合として失敗にはしない）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 14. claude-skills/improvement-dispatch/scripts/check-forbidden-allowed-paths の動作確認 ==="
# TASK-44: forbidden_paths/allowed_pathsと変更ファイル一覧を突き合わせる判定
# ロジックを、一時 git リポジトリに対して実際に実行して検証する。
#   14a. forbidden_paths に前方一致する変更ファイルがある -> VIOLATION（AC#1）
#   14b. forbidden_paths が設定されているが該当ファイルが無い -> OK
#   14c. allowed_paths の範囲外の変更ファイルがある -> VIOLATION（AC#2）
#   14d. allowed_paths の範囲内のみ -> OK
#   14e. forbidden_paths/allowed_paths が両方とも空配列 -> OK（AC#3）
#   14f. .backlog/config.my.yml 自体が無い -> OK（AC#3）
#   14g. 両方設定されている場合、allowed範囲内でもforbidden一致なら違反
#   14h. 変更ファイルを1件も渡さない場合 -> OK
#   14i. 対象リポジトリの外（gitリポジトリでない場所）で実行すると ERROR
#   14j. forbidden_paths を複数行YAMLリスト形式で書いた場合、インライン配列
#        形式と同じ判定結果（VIOLATION）になる（TASK-56 AC#1）
#   14k. allowed_paths を複数行YAMLリスト形式で書いた場合、インライン配列
#        形式と同じ判定結果（範囲外はVIOLATION、範囲内はOK）になる（TASK-56 AC#1）
#   14l. forbidden_paths を複数行YAMLリスト形式かつ空（次行に "-" 項目が
#        続かない）で書いた場合、キー自体が無い場合と同じく制限なし（OK）に
#        なる（既存の空配列＝無制限という意味論を壊さない）
#   14m. forbidden_paths の値が配列でもスカラーでもない壊れたYAML/サポート
#        対象外の記法（例: クォートされていない単一のパス文字列）のとき、
#        RESULT: ERROR（exit 2）になる（TASK-56 AC#3）
#   14n. forbidden_paths をシングルクォートのインライン配列で書いた場合、
#        ダブルクォート版と同じ判定結果になる（TASK-62 AC#2: 引用符除去は
#        bin/lib/yaml_unquote.sh の trim_and_unquote に集約されており、
#        bin/setup-improvement-loop の parse_statuses_block と挙動が
#        一致することをここでも確認する）
#   14o. forbidden_paths をシングルクォートの複数行YAMLリストで書いた場合、
#        ダブルクォート版と同じ判定結果になる（TASK-62 AC#2）
#   14p. .git/info/exclude で除外された .backlog/ 配下の変更は git diff 由来の
#        変更ファイル一覧に載らないため、forbidden_paths に ".backlog/" を
#        書いても RESULT: OK のまま止まらない。一方、同じパスを引数で明示的に
#        渡せば VIOLATION になる（TASK-69 AC#1。死角は判定側ではなく一覧の
#        作り方の側にあることを固定する）
#   14q. .claude/skills/<スキル名> 配下についても同じ（TASK-69 AC#2）
#   14r. その限界が、設定箇所（backlogmd-custom-config/config.my.yml）と
#        スクリプトの契約コメントの両方に明記されている（TASK-69 AC#1/AC#2。
#        記述が黙って消えるのを防ぐ）

TMP_CFA_REPO="$(mktemp -d)"
# macOS では mktemp -d が返すパス（/var/...）がシンボリックリンクであり、
# check-forbidden-allowed-paths 内部の git rev-parse --show-toplevel が返す
# 正規化後のパス（/private/var/...）と文字列比較が一致しないことがあるため、
# ここでも同じ正規化をしておく。
TMP_CFA_REPO="$(cd "$TMP_CFA_REPO" && pwd -P)"
register_tmp_cleanup "$TMP_CFA_REPO"

(cd "$TMP_CFA_REPO" && git init -q -b main && git commit -q --allow-empty -m init)
mkdir -p "$TMP_CFA_REPO/.backlog"
CFA_CONFIG="$TMP_CFA_REPO/.backlog/config.my.yml"

write_cfa_config() {
  cat >"$CFA_CONFIG" <<EOF
improvement_loop:
  forbidden_paths: $1
  allowed_paths: $2
EOF
}

# 複数行YAMLリスト形式で config.my.yml を書く。$1/$2 は改行区切りの要素
# （空文字なら「次行に "-" 項目が続かない」＝空のキーとして書く）。
write_cfa_config_multiline() {
  {
    printf 'improvement_loop:\n'
    printf '  forbidden_paths:\n'
    if [ -n "$1" ]; then
      printf '%s\n' "$1" | while IFS= read -r item; do
        printf '    - "%s"\n' "$item"
      done
    fi
    printf '  allowed_paths:\n'
    if [ -n "$2" ]; then
      printf '%s\n' "$2" | while IFS= read -r item; do
        printf '    - "%s"\n' "$item"
      done
    fi
  } >"$CFA_CONFIG"
}

echo ""
echo "--- 14a. forbidden_paths に前方一致する変更ファイルがあるとき、VIOLATION（非0終了コード）になる（AC#1） ---"
write_cfa_config '["secrets/", "vendor/"]' '[]'
cfa_out_a="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "src/a.txt" "secrets/token.txt" 2>&1)"
cfa_exit_a=$?
if [ "$cfa_exit_a" -ne 0 ] && printf '%s\n' "$cfa_out_a" | grep -Fxq 'RESULT: VIOLATION'; then
  pass "14a: forbidden_paths に前方一致する変更ファイルがあるとき、RESULT: VIOLATION（非0終了コード）（AC#1）"
else
  fail "14a: 期待した結果と異なる（exit ${cfa_exit_a}）:
$cfa_out_a"
fi
if printf '%s\n' "$cfa_out_a" | grep -Fxq 'secrets/token.txt' \
    && printf '%s\n' "$cfa_out_a" | grep -Fxq 'VIOLATION_COUNT: 1'; then
  pass "14a: 違反ファイルパスと件数が出力に含まれる"
else
  fail "14a: 違反ファイルパス/件数の出力が期待と異なる:
$cfa_out_a"
fi

echo ""
echo "--- 14b. forbidden_paths が設定されていても該当ファイルが無いとき、OK（exit 0）になる ---"
cfa_out_b="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "src/a.txt" "docs/readme.md" 2>&1)"
cfa_exit_b=$?
if [ "$cfa_exit_b" -eq 0 ] && printf '%s\n' "$cfa_out_b" | grep -Fxq 'RESULT: OK'; then
  pass "14b: forbidden_paths に一致する変更ファイルが無いとき、RESULT: OK（exit 0）"
else
  fail "14b: 期待した結果と異なる（exit ${cfa_exit_b}）:
$cfa_out_b"
fi

echo ""
echo "--- 14c. allowed_paths の範囲外の変更ファイルがあるとき、VIOLATION（非0終了コード）になる（AC#2） ---"
write_cfa_config '[]' '["src/", "tests/"]'
cfa_out_c="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "src/a.txt" "docs/readme.md" 2>&1)"
cfa_exit_c=$?
if [ "$cfa_exit_c" -ne 0 ] && printf '%s\n' "$cfa_out_c" | grep -Fxq 'RESULT: VIOLATION'; then
  pass "14c: allowed_paths の範囲外の変更ファイルがあるとき、RESULT: VIOLATION（非0終了コード）（AC#2）"
else
  fail "14c: 期待した結果と異なる（exit ${cfa_exit_c}）:
$cfa_out_c"
fi
if printf '%s\n' "$cfa_out_c" | grep -Fxq 'docs/readme.md'; then
  pass "14c: 範囲外の違反ファイルパスが出力に含まれる"
else
  fail "14c: 範囲外の違反ファイルパスが出力に含まれていない:
$cfa_out_c"
fi

echo ""
echo "--- 14d. allowed_paths の範囲内の変更ファイルのみのとき、OK（exit 0）になる ---"
cfa_out_d="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "src/a.txt" "tests/b.txt" 2>&1)"
cfa_exit_d=$?
if [ "$cfa_exit_d" -eq 0 ] && printf '%s\n' "$cfa_out_d" | grep -Fxq 'RESULT: OK'; then
  pass "14d: allowed_paths の範囲内のみのとき、RESULT: OK（exit 0）"
else
  fail "14d: 期待した結果と異なる（exit ${cfa_exit_d}）:
$cfa_out_d"
fi

echo ""
echo "--- 14e. forbidden_paths/allowed_paths が両方とも空配列のとき、常に OK（exit 0）になる（AC#3） ---"
write_cfa_config '[]' '[]'
cfa_out_e="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "secrets/x.txt" "anything/y.txt" 2>&1)"
cfa_exit_e=$?
if [ "$cfa_exit_e" -eq 0 ] && printf '%s\n' "$cfa_out_e" | grep -Fxq 'RESULT: OK'; then
  pass "14e: forbidden_paths/allowed_paths が両方空配列のとき、常に RESULT: OK（exit 0）（AC#3）"
else
  fail "14e: 期待した結果と異なる（exit ${cfa_exit_e}）:
$cfa_out_e"
fi

echo ""
echo "--- 14f. .backlog/config.my.yml 自体が無いとき、常に OK（exit 0）になる（AC#3） ---"
mv "$CFA_CONFIG" "${CFA_CONFIG}.bak"
cfa_out_f="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "secrets/x.txt" 2>&1)"
cfa_exit_f=$?
if [ "$cfa_exit_f" -eq 0 ] && printf '%s\n' "$cfa_out_f" | grep -Fxq 'RESULT: OK'; then
  pass "14f: config.my.yml 自体が無いとき、常に RESULT: OK（exit 0）（AC#3）"
else
  fail "14f: 期待した結果と異なる（exit ${cfa_exit_f}）:
$cfa_out_f"
fi
mv "${CFA_CONFIG}.bak" "$CFA_CONFIG"

echo ""
echo "--- 14g. 両方設定されている場合、allowed_paths の範囲内でも forbidden_paths に一致すれば違反になる ---"
write_cfa_config '["src/secret.txt"]' '["src/"]'
cfa_out_g="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "src/a.txt" "src/secret.txt" 2>&1)"
cfa_exit_g=$?
if [ "$cfa_exit_g" -ne 0 ] && printf '%s\n' "$cfa_out_g" | grep -Fxq 'RESULT: VIOLATION' \
    && printf '%s\n' "$cfa_out_g" | grep -Fxq 'VIOLATION_COUNT: 1' \
    && printf '%s\n' "$cfa_out_g" | grep -Fxq 'src/secret.txt'; then
  pass "14g: allowed範囲内でもforbiddenに一致するファイルだけが違反として検知され、allowed範囲内の他ファイルは違反にならない"
else
  fail "14g: 期待した結果と異なる（exit ${cfa_exit_g}）:
$cfa_out_g"
fi

echo ""
echo "--- 14h. 変更ファイルを1件も渡さないとき、OK（exit 0）になる ---"
cfa_out_h="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" 2>&1)"
cfa_exit_h=$?
if [ "$cfa_exit_h" -eq 0 ] && printf '%s\n' "$cfa_out_h" | grep -Fxq 'RESULT: OK'; then
  pass "14h: 変更ファイルを1件も渡さないとき、RESULT: OK（exit 0）"
else
  fail "14h: 期待した結果と異なる（exit ${cfa_exit_h}）:
$cfa_out_h"
fi

echo ""
echo "--- 14i. 対象リポジトリの外（gitリポジトリでない場所）で実行すると ERROR（exit 2）になる ---"
TMP_CFA_NONREPO="$(mktemp -d)"
register_tmp_cleanup "$TMP_CFA_NONREPO"
cfa_out_i="$(cd "$TMP_CFA_NONREPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "a.txt" 2>&1)"
cfa_exit_i=$?
if [ "$cfa_exit_i" -eq 2 ] && printf '%s\n' "$cfa_out_i" | grep -Fxq 'RESULT: ERROR'; then
  pass "14i: gitリポジトリでない場所で実行すると、RESULT: ERROR（exit 2）"
else
  fail "14i: 期待した結果と異なる（exit ${cfa_exit_i}）:
$cfa_out_i"
fi

echo ""
echo "--- 14j. forbidden_paths を複数行YAMLリスト形式で書いた場合、インライン配列形式と同じ判定結果（VIOLATION）になる（TASK-56 AC#1） ---"
write_cfa_config_multiline "$(printf 'secrets/\nvendor/')" ""
cfa_out_j="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "src/a.txt" "secrets/token.txt" 2>&1)"
cfa_exit_j=$?
if [ "$cfa_exit_j" -eq 1 ] && printf '%s\n' "$cfa_out_j" | grep -Fxq 'RESULT: VIOLATION' \
    && printf '%s\n' "$cfa_out_j" | grep -Fxq 'VIOLATION_COUNT: 1' \
    && printf '%s\n' "$cfa_out_j" | grep -Fxq 'secrets/token.txt'; then
  pass "14j: forbidden_paths を複数行YAMLリスト形式で書いた場合も、インライン配列形式と同じ RESULT: VIOLATION（TASK-56 AC#1）"
else
  fail "14j: 期待した結果と異なる（exit ${cfa_exit_j}）:
$cfa_out_j"
fi
cfa_out_j2="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "src/a.txt" "docs/readme.md" 2>&1)"
cfa_exit_j2=$?
if [ "$cfa_exit_j2" -eq 0 ] && printf '%s\n' "$cfa_out_j2" | grep -Fxq 'RESULT: OK'; then
  pass "14j: 複数行YAMLリスト形式の forbidden_paths に一致しない変更ファイルのときは RESULT: OK"
else
  fail "14j: 期待した結果と異なる（exit ${cfa_exit_j2}）:
$cfa_out_j2"
fi

echo ""
echo "--- 14k. allowed_paths を複数行YAMLリスト形式で書いた場合、インライン配列形式と同じ判定結果になる（TASK-56 AC#1） ---"
write_cfa_config_multiline "" "$(printf 'src/\ntests/')"
cfa_out_k1="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "src/a.txt" "docs/readme.md" 2>&1)"
cfa_exit_k1=$?
if [ "$cfa_exit_k1" -eq 1 ] && printf '%s\n' "$cfa_out_k1" | grep -Fxq 'RESULT: VIOLATION' \
    && printf '%s\n' "$cfa_out_k1" | grep -Fxq 'docs/readme.md'; then
  pass "14k: 複数行YAMLリスト形式の allowed_paths の範囲外の変更ファイルがあるとき、RESULT: VIOLATION"
else
  fail "14k: 期待した結果と異なる（exit ${cfa_exit_k1}）:
$cfa_out_k1"
fi
cfa_out_k2="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "src/a.txt" "tests/b.txt" 2>&1)"
cfa_exit_k2=$?
if [ "$cfa_exit_k2" -eq 0 ] && printf '%s\n' "$cfa_out_k2" | grep -Fxq 'RESULT: OK'; then
  pass "14k: 複数行YAMLリスト形式の allowed_paths の範囲内のみのとき、RESULT: OK"
else
  fail "14k: 期待した結果と異なる（exit ${cfa_exit_k2}）:
$cfa_out_k2"
fi

echo ""
echo "--- 14l. forbidden_paths が複数行YAMLリスト形式かつ空（次行に \"-\" 項目が続かない）のとき、制限なし（OK）になる ---"
cat >"$CFA_CONFIG" <<'EOF'
improvement_loop:
  forbidden_paths:
  allowed_paths: []
EOF
cfa_out_l="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "secrets/x.txt" 2>&1)"
cfa_exit_l=$?
if [ "$cfa_exit_l" -eq 0 ] && printf '%s\n' "$cfa_out_l" | grep -Fxq 'RESULT: OK'; then
  pass "14l: forbidden_paths: の後に複数行リスト項目が続かないとき、キー自体が無い場合と同様に RESULT: OK"
else
  fail "14l: 期待した結果と異なる（exit ${cfa_exit_l}）:
$cfa_out_l"
fi

echo ""
echo "--- 14m. forbidden_paths の値が配列でもスカラーでもない壊れたYAML/サポート対象外の記法のとき、RESULT: ERROR（exit 2）になる（TASK-56 AC#3） ---"
cat >"$CFA_CONFIG" <<'EOF'
improvement_loop:
  forbidden_paths: secrets/
  allowed_paths: []
EOF
cfa_out_m="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "secrets/x.txt" 2>&1)"
cfa_exit_m=$?
if [ "$cfa_exit_m" -eq 2 ] && printf '%s\n' "$cfa_out_m" | grep -Fxq 'RESULT: ERROR'; then
  pass "14m: forbidden_paths がサポート対象外の記法（インライン配列でも複数行YAMLリストでもない）のとき、RESULT: ERROR（exit 2）（TASK-56 AC#3）"
else
  fail "14m: 期待した結果と異なる（exit ${cfa_exit_m}）:
$cfa_out_m"
fi

echo ""
echo "--- 14n. forbidden_paths をシングルクォートのインライン配列で書いた場合、ダブルクォート版と同じ判定結果になる（TASK-62 AC#2） ---"
write_cfa_config "['secrets/', 'vendor/']" '[]'
cfa_out_n1="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "src/a.txt" "secrets/token.txt" 2>&1)"
cfa_exit_n1=$?
if [ "$cfa_exit_n1" -eq 1 ] && printf '%s\n' "$cfa_out_n1" | grep -Fxq 'RESULT: VIOLATION' \
    && printf '%s\n' "$cfa_out_n1" | grep -Fxq 'VIOLATION_COUNT: 1' \
    && printf '%s\n' "$cfa_out_n1" | grep -Fxq 'secrets/token.txt'; then
  pass "14n: シングルクォートのインライン配列の forbidden_paths でも、ダブルクォート版（14a）と同じ RESULT: VIOLATION（TASK-62 AC#2）"
else
  fail "14n: 期待した結果と異なる（exit ${cfa_exit_n1}）:
$cfa_out_n1"
fi
cfa_out_n2="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "src/a.txt" "docs/readme.md" 2>&1)"
cfa_exit_n2=$?
if [ "$cfa_exit_n2" -eq 0 ] && printf '%s\n' "$cfa_out_n2" | grep -Fxq 'RESULT: OK'; then
  pass "14n: シングルクォートのインライン配列の forbidden_paths に一致しない変更ファイルのときは RESULT: OK"
else
  fail "14n: 期待した結果と異なる（exit ${cfa_exit_n2}）:
$cfa_out_n2"
fi

echo ""
echo "--- 14o. forbidden_paths をシングルクォートの複数行YAMLリストで書いた場合、ダブルクォート版と同じ判定結果になる（TASK-62 AC#2） ---"
cat >"$CFA_CONFIG" <<'EOF'
improvement_loop:
  forbidden_paths:
    - 'secrets/'
    - 'vendor/'
  allowed_paths: []
EOF
cfa_out_o="$(cd "$TMP_CFA_REPO" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "src/a.txt" "secrets/token.txt" 2>&1)"
cfa_exit_o=$?
if [ "$cfa_exit_o" -eq 1 ] && printf '%s\n' "$cfa_out_o" | grep -Fxq 'RESULT: VIOLATION' \
    && printf '%s\n' "$cfa_out_o" | grep -Fxq 'VIOLATION_COUNT: 1' \
    && printf '%s\n' "$cfa_out_o" | grep -Fxq 'secrets/token.txt'; then
  pass "14o: シングルクォートの複数行YAMLリストの forbidden_paths でも、ダブルクォート版（14j）と同じ RESULT: VIOLATION（TASK-62 AC#2）"
else
  fail "14o: 期待した結果と異なる（exit ${cfa_exit_o}）:
$cfa_out_o"
fi

echo ""
echo "--- 14p. git 管理外（.git/info/exclude で除外）の .backlog/ 配下は git diff 由来の一覧に載らず機械的に止まらないが、引数で明示すれば判定される（TASK-69 AC#1） ---"
# bin/setup-improvement-loop 手順6が導入先の .git/info/exclude に .backlog と
# .claude/skills/<スキル名> を登録するため、この2つは git 管理外になる。
# 呼び出し側2箇所は変更ファイル一覧を git diff から作るので、これらのパスは
# 一覧に載らず、forbidden_paths に書いても機械的には止まらない。
# 一方でスクリプト自身はパスの追跡状態を見ないため、引数として渡されさえすれば
# 判定する。この「死角は判定側ではなく一覧の作り方の側にある」という切り分けを
# 固定するのがこの2ケースである（限界の記述そのものは 14r で確認する）。
TMP_CFA_IGNORED="$(mktemp -d)"
TMP_CFA_IGNORED="$(cd "$TMP_CFA_IGNORED" && pwd -P)"
register_tmp_cleanup "$TMP_CFA_IGNORED"
(
  cd "$TMP_CFA_IGNORED" || exit 1
  git init -q -b main
  git commit -q --allow-empty -m init
  printf '.backlog\n.claude/skills/improvement-dispatch\n' >> .git/info/exclude
  mkdir -p .backlog .claude/skills/improvement-dispatch/scripts
  cat > .backlog/config.my.yml <<'CFG'
improvement_loop:
  forbidden_paths: [".backlog/", ".claude/"]
  allowed_paths: []
CFG
  printf 'changed\n' > .claude/skills/improvement-dispatch/scripts/create-worktree
  printf 'src\n' > app.txt
  git add app.txt
) >/dev/null 2>&1

cfa_ignored_changed=()
while IFS= read -r cfa_line; do
  [ -n "$cfa_line" ] && cfa_ignored_changed+=("$cfa_line")
done < <(cd "$TMP_CFA_IGNORED" && git diff --name-only --cached)

if [ "${#cfa_ignored_changed[@]}" -eq 1 ] && [ "${cfa_ignored_changed[0]}" = "app.txt" ]; then
  pass "14p: git 管理外の .backlog/config.my.yml を書き換えても git diff --name-only --cached の一覧には現れない"
else
  fail "14p: 変更ファイル一覧が期待と異なる（${#cfa_ignored_changed[@]} 件）:
${cfa_ignored_changed[*]+${cfa_ignored_changed[*]}}"
fi

cfa_out_p="$(cd "$TMP_CFA_IGNORED" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" ${cfa_ignored_changed[@]+"${cfa_ignored_changed[@]}"} 2>&1)"
cfa_exit_p=$?
if [ "$cfa_exit_p" -eq 0 ] && printf '%s\n' "$cfa_out_p" | grep -Fxq 'RESULT: OK'; then
  pass "14p: forbidden_paths に \".backlog/\" があっても、git 差分由来の一覧を渡す限り RESULT: OK（機械的には止まらない。この限界は設定箇所とスクリプトのヘッダーに明記されている）"
else
  fail "14p: 期待した結果と異なる（exit ${cfa_exit_p}）:
$cfa_out_p"
fi

cfa_out_p2="$(cd "$TMP_CFA_IGNORED" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" ".backlog/config.my.yml" 2>&1)"
cfa_exit_p2=$?
if [ "$cfa_exit_p2" -eq 1 ] && printf '%s\n' "$cfa_out_p2" | grep -Fxq 'RESULT: VIOLATION' \
    && printf '%s\n' "$cfa_out_p2" | grep -Fxq '.backlog/config.my.yml'; then
  pass "14p: 同じ .backlog/config.my.yml を引数で明示的に渡せば RESULT: VIOLATION（スクリプトはパスの追跡状態を見ない）"
else
  fail "14p: 期待した結果と異なる（exit ${cfa_exit_p2}）:
$cfa_out_p2"
fi

echo ""
echo "--- 14q. git 管理外の .claude/skills/<スキル名> 配下も同じく git に見えず機械的に止まらないが、引数で明示すれば判定される（TASK-69 AC#2） ---"
cfa_status_q="$(cd "$TMP_CFA_IGNORED" && git status --porcelain)"
if ! printf '%s\n' "$cfa_status_q" | grep -Fq '.claude/skills/improvement-dispatch'; then
  pass "14q: .claude/skills/improvement-dispatch 配下の書き換えは git status --porcelain にも現れない（配布元リポジトリの実体への波及が導入先の git に見えないのと同じ理由）"
else
  fail "14q: 期待に反して git status に現れた:
$cfa_status_q"
fi

cfa_out_q="$(cd "$TMP_CFA_IGNORED" && "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" ".claude/skills/improvement-dispatch/scripts/create-worktree" 2>&1)"
cfa_exit_q=$?
if [ "$cfa_exit_q" -eq 1 ] && printf '%s\n' "$cfa_out_q" | grep -Fxq 'RESULT: VIOLATION' \
    && printf '%s\n' "$cfa_out_q" | grep -Fxq '.claude/skills/improvement-dispatch/scripts/create-worktree'; then
  pass "14q: .claude/skills/<スキル名> 配下のパスを引数で明示的に渡せば RESULT: VIOLATION"
else
  fail "14q: 期待した結果と異なる（exit ${cfa_exit_q}）:
$cfa_out_q"
fi

echo ""
echo "--- 14r. 機械的に止まらない範囲が、設定箇所（config.my.yml テンプレート）とスクリプトの契約コメントの両方に明記されている（TASK-69 AC#1/AC#2） ---"
# 14p/14q が固定しているのは「止まらない」という事実だけである。受入基準が
# 求めているのは、その事実が設定する人の読む場所に書かれていることなので、
# 記述が黙って消えないようここで確認する。
if grep -Fq 'git 管理外' "$SOURCE_CONFIG" \
    && grep -Fq '.git/info/exclude' "$SOURCE_CONFIG" \
    && grep -Fq '.backlog/' "$SOURCE_CONFIG" \
    && grep -Fq '.claude/skills/' "$SOURCE_CONFIG"; then
  pass "14r: config.my.yml テンプレートの forbidden_paths/allowed_paths のコメントに、git 管理外パス（.backlog/ ・.claude/skills/ ・.git/info/exclude）が機械的に止まらない旨が書かれている"
else
  fail "14r: config.my.yml テンプレートに git 管理外パスの限界の記述が無い: $SOURCE_CONFIG"
fi

if grep -Fq 'git 管理外' "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" \
    && grep -Fq '.backlog/' "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" \
    && grep -Fq '.claude/skills/' "$CHECK_FORBIDDEN_ALLOWED_SCRIPT"; then
  pass "14r: check-forbidden-allowed-paths の契約コメントに、判定が及ばない範囲（git 管理外パス）が書かれている"
else
  fail "14r: check-forbidden-allowed-paths のヘッダーに限界の記述が無い: $CHECK_FORBIDDEN_ALLOWED_SCRIPT"
fi

# 後片付け: write_cfa_config で使う想定のインライン配列形式に戻しておく
# （このファイル内で以降のテストが追加された場合の事故を防ぐ）。
write_cfa_config '[]' '[]'

finish_tests
