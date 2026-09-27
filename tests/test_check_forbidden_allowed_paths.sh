#!/usr/bin/env bash
# claude-code/skills/improvement-dispatch/scripts/check-forbidden-allowed-paths
# に対するテスト。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 1. claude-code/skills/improvement-dispatch/scripts/check-forbidden-allowed-paths の動作確認 ==="
# forbidden_paths / allowed_paths と変更ファイル一覧を突き合わせる判定ロジックを、
# 一時 git リポジトリに対して実際に実行して検証する。各ケースの内容は cfa_case の
# ラベル（1a 以降）を参照。

TMP_CFA_REPO="$(mktemp -d)"
# macOS の mktemp -d はシンボリックリンク経由のパスを返し、スクリプト内部の
# git rev-parse --show-toplevel が返す正規化後のパスと一致しないことがある。
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

# cfa_case <ラベル> <期待する終了コード> <完全一致で含むべき行（; 区切り）> [変更ファイル...]
# CFA_DIR（既定は TMP_CFA_REPO）で check-forbidden-allowed-paths を実行し、終了コードと
# 出力行をまとめて1件の検証として数える。各ケースは「設定を書く → cfa_case を並べる」の
# 表として読めるように書く。変更ファイルを渡さず "-" を1つだけ渡すと、実行せずに直前の
# 結果を検証する（同じ実行に2件の検証を書くとき）。
CFA_DIR="$TMP_CFA_REPO"
cfa_case() {
  local label="$1" code="$2" expected=()
  IFS=';' read -r -a expected <<<"$3"
  shift 3
  if [ "$#" -ne 1 ] || [ "$1" != "-" ]; then
    run_in "$CFA_DIR" "$CHECK_FORBIDDEN_ALLOWED_SCRIPT" "$@"
  fi
  assert "$label" run_result "$code" ${expected[@]+"${expected[@]}"}
}

V='RESULT: VIOLATION'
OK='RESULT: OK'

# 1a/1b: forbidden_paths（インライン配列・ダブルクォート）
write_cfa_config '["secrets/", "vendor/"]' '[]'
cfa_case "1a: forbidden_paths に前方一致する変更ファイルがあるとき、RESULT: VIOLATION（exit 1）（AC#1）" 1 "$V" src/a.txt secrets/token.txt
cfa_case "1a: 違反ファイルパスと件数が出力に含まれる" 1 "secrets/token.txt;VIOLATION_COUNT: 1" -
cfa_case "1b: forbidden_paths に一致する変更ファイルが無いとき、RESULT: OK（exit 0）" 0 "$OK" src/a.txt docs/readme.md

# 1c/1d: allowed_paths（インライン配列）
write_cfa_config '[]' '["src/", "tests/"]'
cfa_case "1c: allowed_paths の範囲外の変更ファイルがあるとき、RESULT: VIOLATION（exit 1）（AC#2）" 1 "$V" src/a.txt docs/readme.md
cfa_case "1c: 範囲外の違反ファイルパスが出力に含まれる" 1 "docs/readme.md" -
cfa_case "1d: allowed_paths の範囲内のみのとき、RESULT: OK（exit 0）" 0 "$OK" src/a.txt tests/b.txt

# 1e/1f: 制限なし
write_cfa_config '[]' '[]'
cfa_case "1e: forbidden_paths/allowed_paths が両方空配列のとき、常に RESULT: OK（exit 0）（AC#3）" 0 "$OK" secrets/x.txt anything/y.txt
mv "$CFA_CONFIG" "${CFA_CONFIG}.bak"
cfa_case "1f: config.my.yml 自体が無いとき、常に RESULT: OK（exit 0）（AC#3）" 0 "$OK" secrets/x.txt
mv "${CFA_CONFIG}.bak" "$CFA_CONFIG"

# 1g/1h: 両方設定・引数なし
write_cfa_config '["src/secret.txt"]' '["src/"]'
cfa_case "1g: allowed範囲内でもforbiddenに一致するファイルだけが違反として検知され、allowed範囲内の他ファイルは違反にならない" 1 "$V;VIOLATION_COUNT: 1;src/secret.txt" src/a.txt src/secret.txt
cfa_case "1h: 変更ファイルを1件も渡さないとき、RESULT: OK（exit 0）" 0 "$OK"

# 1i: git リポジトリの外
TMP_CFA_NONREPO="$(mktemp -d)"
register_tmp_cleanup "$TMP_CFA_NONREPO"
CFA_DIR="$TMP_CFA_NONREPO"
cfa_case "1i: gitリポジトリでない場所で実行すると、RESULT: ERROR（exit 2）" 2 "RESULT: ERROR" a.txt
CFA_DIR="$TMP_CFA_REPO"

# 1j/1k: 複数行YAMLリスト形式（TASK-56 AC#1）
write_cfa_config_multiline "$(printf 'secrets/\nvendor/')" ""
cfa_case "1j: forbidden_paths を複数行YAMLリスト形式で書いた場合も、インライン配列形式と同じ RESULT: VIOLATION（TASK-56 AC#1）" 1 "$V;VIOLATION_COUNT: 1;secrets/token.txt" src/a.txt secrets/token.txt
cfa_case "1j: 複数行YAMLリスト形式の forbidden_paths に一致しない変更ファイルのときは RESULT: OK" 0 "$OK" src/a.txt docs/readme.md
write_cfa_config_multiline "" "$(printf 'src/\ntests/')"
cfa_case "1k: 複数行YAMLリスト形式の allowed_paths の範囲外の変更ファイルがあるとき、RESULT: VIOLATION" 1 "$V;docs/readme.md" src/a.txt docs/readme.md
cfa_case "1k: 複数行YAMLリスト形式の allowed_paths の範囲内のみのとき、RESULT: OK" 0 "$OK" src/a.txt tests/b.txt

# 1l: 複数行形式で項目が続かない空のキー
printf 'improvement_loop:\n  forbidden_paths:\n  allowed_paths: []\n' >"$CFA_CONFIG"
cfa_case "1l: forbidden_paths: の後に複数行リスト項目が続かないとき、キー自体が無い場合と同様に RESULT: OK" 0 "$OK" secrets/x.txt

# 1m: サポート対象外の記法（TASK-56 AC#3）
printf 'improvement_loop:\n  forbidden_paths: secrets/\n  allowed_paths: []\n' >"$CFA_CONFIG"
cfa_case "1m: forbidden_paths がサポート対象外の記法（インライン配列でも複数行YAMLリストでもない）のとき、RESULT: ERROR（exit 2）（TASK-56 AC#3）" 2 "RESULT: ERROR" secrets/x.txt

# 1n/1o: シングルクォート（TASK-62 AC#2）
write_cfa_config "['secrets/', 'vendor/']" '[]'
cfa_case "1n: シングルクォートのインライン配列の forbidden_paths でも、ダブルクォート版（1a）と同じ RESULT: VIOLATION（TASK-62 AC#2）" 1 "$V;VIOLATION_COUNT: 1;secrets/token.txt" src/a.txt secrets/token.txt
cfa_case "1n: シングルクォートのインライン配列の forbidden_paths に一致しない変更ファイルのときは RESULT: OK" 0 "$OK" src/a.txt docs/readme.md
printf "improvement_loop:\n  forbidden_paths:\n    - 'secrets/'\n    - 'vendor/'\n  allowed_paths: []\n" >"$CFA_CONFIG"
cfa_case "1o: シングルクォートの複数行YAMLリストの forbidden_paths でも、ダブルクォート版（1j）と同じ RESULT: VIOLATION（TASK-62 AC#2）" 1 "$V;VIOLATION_COUNT: 1;secrets/token.txt" src/a.txt secrets/token.txt

# 1p/1q: git 管理外（.git/info/exclude で除外）のパスも、引数で明示すれば判定される（TASK-69）。
# bin/setup-improvement-loop が .backlog と .claude/skills/<スキル名> を
# .git/info/exclude に登録するので、この2つは git 管理外になる。スクリプト自身はパスの
# 追跡状態を見ず、引数で渡されさえすれば判定する。
TMP_CFA_IGNORED="$(mktemp -d)"
TMP_CFA_IGNORED="$(cd "$TMP_CFA_IGNORED" && pwd -P)"
register_tmp_cleanup "$TMP_CFA_IGNORED"
(
  cd "$TMP_CFA_IGNORED" || exit 1
  git init -q -b main
  git commit -q --allow-empty -m init
  printf '.backlog\n.claude/skills/improvement-dispatch\n' >> .git/info/exclude
  mkdir -p .backlog .claude/skills/improvement-dispatch/scripts
  printf 'improvement_loop:\n  forbidden_paths: [".backlog/", ".claude/"]\n  allowed_paths: []\n' > .backlog/config.my.yml
  printf 'changed\n' > .claude/skills/improvement-dispatch/scripts/create-worktree
) >/dev/null 2>&1
CFA_DIR="$TMP_CFA_IGNORED"
cfa_case "1p: git 管理外の .backlog/config.my.yml を引数で明示的に渡せば RESULT: VIOLATION（スクリプトはパスの追跡状態を見ない）（TASK-69 AC#1）" 1 "$V;.backlog/config.my.yml" .backlog/config.my.yml
cfa_case "1q: .claude/skills/<スキル名> 配下のパスを引数で明示的に渡せば RESULT: VIOLATION（TASK-69 AC#2）" 1 "$V;.claude/skills/improvement-dispatch/scripts/create-worktree" .claude/skills/improvement-dispatch/scripts/create-worktree
CFA_DIR="$TMP_CFA_REPO"

# 後片付け: 以降にテストが追加された場合の事故を防ぐため、インライン配列形式に戻す。
write_cfa_config '[]' '[]'

finish_tests
