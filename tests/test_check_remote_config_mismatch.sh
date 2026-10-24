#!/usr/bin/env bash
# claude-code/skills/improvement-dispatch/scripts/check-remote-config-mismatch に対するテスト。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 1. check-remote-config-mismatch: リモートの有無と auto_merge_reviewed の食い違い検知 ==="

# 引数: <変数名> <リモートを足すか: remote|none> <config.my.yml の中身: missing|nokey|<値>>
make_repo() {
  local dir
  dir="$(mktemp -d)"
  register_tmp_cleanup "$dir"
  (cd "$dir" && git init -q)
  if [ "$2" = "remote" ]; then
    (cd "$dir" && git remote add origin "https://example.invalid/repo.git")
  fi
  case "$3" in
    missing) : ;;
    nokey)
      mkdir -p "$dir/.backlog"
      printf 'improvement_loop:\n  max_in_progress: 1\n' > "$dir/.backlog/config.my.yml"
      ;;
    *)
      mkdir -p "$dir/.backlog"
      printf 'improvement_loop:\n  max_in_progress: 1\n  auto_merge_reviewed: %s  # コメント\n' "$3" > "$dir/.backlog/config.my.yml"
      ;;
  esac
  printf -v "$1" '%s' "$dir"
}

WARN_FACT='WARNING: git リモートが 1 つも無いが、auto_merge_reviewed が true ではない'

# ---- AC#1: リモートが無く、auto_merge_reviewed が false / キー無し / ファイル無し → MISMATCH ----
for cfg in false nokey missing; do
  make_repo REPO none "$cfg"
  run_in "$REPO" "$CHECK_REMOTE_CONFIG_MISMATCH_SCRIPT"
  assert "リモート無し・設定 $cfg で RESULT: MISMATCH（exit 1）" \
    run_result 1 'REMOTE_COUNT: 0' 'AUTO_MERGE_REVIEWED: false' 'RESULT: MISMATCH'
  assert "リモート無し・設定 $cfg で食い違いの事実が出る" has_text "$RUN_OUT" "$WARN_FACT"
  assert "リモート無し・設定 $cfg で config.my.yml の auto_merge_reviewed を見直す方法が出る" \
    has_text "$RUN_OUT" "$REPO/.backlog/config.my.yml の improvement_loop に auto_merge_reviewed: true を設定する"
done

# サブディレクトリから実行しても対象リポジトリのルートの config.my.yml を見る。
make_repo REPO none false
mkdir -p "$REPO/sub/dir"
run_in "$REPO/sub/dir" "$CHECK_REMOTE_CONFIG_MISMATCH_SCRIPT"
assert "サブディレクトリから実行しても RESULT: MISMATCH" run_result 1 'CONFIG_FILE: present' 'RESULT: MISMATCH'

# ---- AC#2: リモートがある、または auto_merge_reviewed が true → 警告なし ----
for cfg in false nokey missing true; do
  make_repo REPO remote "$cfg"
  run_in "$REPO" "$CHECK_REMOTE_CONFIG_MISMATCH_SCRIPT"
  expected_amr=false
  [ "$cfg" = "true" ] && expected_amr=true
  assert "リモート有り・設定 $cfg で RESULT: OK（exit 0）" \
    run_result 0 'REMOTE_COUNT: 1' "AUTO_MERGE_REVIEWED: $expected_amr" 'RESULT: OK'
  assert_not "リモート有り・設定 $cfg で警告が出ない" has_text "$RUN_OUT" 'WARNING:'
done

for cfg in true '"true"' TRUE; do
  make_repo REPO none "$cfg"
  run_in "$REPO" "$CHECK_REMOTE_CONFIG_MISMATCH_SCRIPT"
  assert "リモート無し・auto_merge_reviewed: $cfg で RESULT: OK（exit 0）" \
    run_result 0 'REMOTE_COUNT: 0' 'AUTO_MERGE_REVIEWED: true' 'RESULT: OK'
  assert_not "リモート無し・auto_merge_reviewed: $cfg で警告が出ない" has_text "$RUN_OUT" 'WARNING:'
done

# ---- AC#3: 検知は config.my.yml を変えない（ファイルが無ければ作らない） ----
make_repo REPO none false
before="$(cat "$REPO/.backlog/config.my.yml")"
run_in "$REPO" "$CHECK_REMOTE_CONFIG_MISMATCH_SCRIPT"
after="$(cat "$REPO/.backlog/config.my.yml")"
assert "MISMATCH を検知しても config.my.yml の内容が変わらない" [ "$before" = "$after" ]

make_repo REPO none missing
run_in "$REPO" "$CHECK_REMOTE_CONFIG_MISMATCH_SCRIPT"
assert "config.my.yml が無いとき、検知によってファイルが作られない" [ ! -e "$REPO/.backlog/config.my.yml" ]

# ---- ERROR ----
NOT_REPO="$(mktemp -d)"
register_tmp_cleanup "$NOT_REPO"
run_in "$NOT_REPO" env GIT_CEILING_DIRECTORIES="$(dirname "$NOT_REPO")" "$CHECK_REMOTE_CONFIG_MISMATCH_SCRIPT"
assert "git リポジトリの外では RESULT: ERROR（exit 2）" run_result 2 'RESULT: ERROR'

make_repo REPO none false
run_in "$REPO" "$CHECK_REMOTE_CONFIG_MISMATCH_SCRIPT" extra
assert "引数を渡すと RESULT: ERROR（exit 2）" run_result 2 'RESULT: ERROR'

# 共有ライブラリ（bin/lib/config_scalar.sh）を読み込めない配置では、誤って MISMATCH を
# 出さずに RESULT: ERROR になる。配布元の構造を真似た一時ディレクトリにスクリプトだけを置く。
BROKEN_DIST="$(mktemp -d)"
register_tmp_cleanup "$BROKEN_DIST"
mkdir -p "$BROKEN_DIST/claude-code/skills/improvement-dispatch/scripts"
cp "$CHECK_REMOTE_CONFIG_MISMATCH_SCRIPT" "$BROKEN_DIST/claude-code/skills/improvement-dispatch/scripts/"
make_repo REPO none false
run_in "$REPO" "$BROKEN_DIST/claude-code/skills/improvement-dispatch/scripts/check-remote-config-mismatch"
assert "共有ライブラリを読み込めないとき RESULT: ERROR（exit 2）で MISMATCH を出さない" run_result 2 'RESULT: ERROR'
assert_not "共有ライブラリを読み込めないとき警告が出ない" has_text "$RUN_OUT" 'WARNING:'

finish_tests
