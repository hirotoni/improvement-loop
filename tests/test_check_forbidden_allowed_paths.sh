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

# 後片付け: write_cfa_config で使う想定のインライン配列形式に戻しておく
# （このファイル内で以降のテストが追加された場合の事故を防ぐ）。
write_cfa_config '[]' '[]'

finish_tests
