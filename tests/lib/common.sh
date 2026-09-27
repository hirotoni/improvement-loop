# tests/test_*.sh の各ファイルから source される共通基盤。実行されず、必ず
# source される前提のためシバンは付けない。
#
# 提供するもの:
# - REPO_ROOT および各対象スクリプト・設定ファイルへのパス変数
# - PASS_COUNT/FAIL_COUNT/SKIP_COUNT と pass()/fail()/skip()
# - check_test_dependencies(): 必須依存が無い環境でのスキップ判定
# - register_tmp_cleanup()/cleanup_registered_tmp_paths(): 一時ディレクトリの後片付け
# - finish_tests(): 各テストファイル末尾で呼ぶサマリー出力・exit判定
# - run_in()/run_result()/run_result_text()/has_line()/has_text()/first_line_is()/
#   last_lines_are()/assert()/assert_not(): 1件の検証を1行で書くためのヘルパー

COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$COMMON_LIB_DIR/../.." && pwd)"

SETUP_SCRIPT="$REPO_ROOT/bin/setup-improvement-loop"
CREATE_WORKTREE_SCRIPT="$REPO_ROOT/claude-code/skills/improvement-dispatch/scripts/create-worktree"
TOUCH_OCCUPANCY_SCRIPT="$REPO_ROOT/claude-code/skills/improvement-dispatch/scripts/touch-occupancy"
MERGE_SCRIPT="$REPO_ROOT/claude-code/skills/improvement-dispatch/scripts/merge-reviewed-branch"
SELECT_SCRIPT="$REPO_ROOT/claude-code/skills/improvement-dispatch/scripts/select-next-task"
CHECK_RECOVERY_SCRIPT="$REPO_ROOT/claude-code/skills/improvement-dispatch/scripts/check-progress-recovery"
CHECK_HANDOFF_SCRIPT="$REPO_ROOT/claude-code/skills/improvement-work/scripts/check-handoff"
BACKLOG_CONFIG_SNAPSHOT_SCRIPT="$REPO_ROOT/claude-code/skills/improvement-dispatch/scripts/backlog-config-snapshot"
CHECK_FORBIDDEN_ALLOWED_SCRIPT="$REPO_ROOT/claude-code/skills/improvement-dispatch/scripts/check-forbidden-allowed-paths"
RESOLVE_PATH_SCRIPT="$REPO_ROOT/bin/lib/resolve_path.sh"
YAML_UNQUOTE_SCRIPT="$REPO_ROOT/bin/lib/yaml_unquote.sh"
LIST_OPTED_IN_REPOS_SCRIPT="$REPO_ROOT/bin/lib/list_opted_in_repos.sh"
WORKTREE_PORCELAIN_SCRIPT="$REPO_ROOT/bin/lib/worktree_porcelain.sh"
OCCUPANCY_LIB_SCRIPT="$REPO_ROOT/bin/lib/occupancy.sh"
WORKSPACE_DISPATCH_LIST_TARGET_REPOS_SCRIPT="$REPO_ROOT/claude-code/workspace-skills/workspace-dispatch/scripts/list-target-repos"
WORKSPACE_SCOUT_LIST_TARGET_REPOS_SCRIPT="$REPO_ROOT/claude-code/workspace-skills/workspace-scout/scripts/list-target-repos"
WORKSPACE_SCOUT_MAJOR_LIST_TARGET_REPOS_SCRIPT="$REPO_ROOT/claude-code/workspace-skills/workspace-scout-major/scripts/list-target-repos"
INSTALL_SCRIPT="$REPO_ROOT/install.zsh"
PRECOMMIT_HOOK="$REPO_ROOT/githooks/pre-commit"
TESTS_RUNNER_SCRIPT="$REPO_ROOT/tests/run.sh"
SOURCE_CONFIG="$REPO_ROOT/backlog-md/config.my.yml"
SOURCE_SKILLS_DIR="$REPO_ROOT/claude-code/skills"
SOURCE_WORKSPACE_SKILLS_DIR="$REPO_ROOT/claude-code/workspace-skills"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL: %s\n' "$1"
}

skip() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  printf 'SKIP: %s\n' "$1"
}

# ---- 1件の検証を1行で書くためのヘルパー ----
# if/pass/fail の6〜7行を、assert "<ラベル>" <条件コマンド...> の1行で書くためのもの。
# 条件コマンドには has_line・has_text・run_result・[ ... ] などを1つだけ渡す。
# `assert ラベル [ ... ] && has_line ...` と書くと && の右辺は assert の外で評価され、
# 検証に含まれない。複数の条件は run_result にまとめるか、assert を分ける。
#
# run_in <ディレクトリ> <コマンド...>
#   ディレクトリへ cd してコマンドを実行し、標準出力と標準エラーを RUN_OUT に、
#   終了コードを RUN_EXIT に入れる。FAIL 時に添える ASSERT_DETAIL も更新する。
RUN_OUT=""
RUN_EXIT=0
ASSERT_DETAIL=""
run_in() {
  local dir="$1"
  shift
  RUN_OUT="$(cd "$dir" && "$@" 2>&1)"
  RUN_EXIT=$?
  ASSERT_DETAIL="exit ${RUN_EXIT}:
$RUN_OUT"
}

# has_line <テキスト> <行>: テキストに行と完全一致する行があれば真。
# パイプではなくヒアストリングで渡す。pipefail の下で grep -q が早く終わると、
# 大きな出力では printf 側が SIGPIPE で失敗し、一致していても偽になるためである。
has_line() {
  grep -Fxq -- "$2" <<<"$1"
}

# has_text <テキスト> <部分文字列>: テキストに部分文字列が含まれれば真。
has_text() {
  grep -Fq -- "$2" <<<"$1"
}

# run_result <期待する終了コード|nz> [行...]: 直近の run_in の終了コードが期待どおり
# （nz は 0 以外）で、RUN_OUT に各行と完全一致する行があれば真。
run_result() {
  local code="$1" line
  shift
  if [ "$code" = "nz" ]; then
    [ "$RUN_EXIT" -ne 0 ] || return 1
  else
    [ "$RUN_EXIT" -eq "$code" ] || return 1
  fi
  for line in "$@"; do
    has_line "$RUN_OUT" "$line" || return 1
  done
  return 0
}

# run_result_text <期待する終了コード|nz> [部分文字列...]: run_result の部分一致版。
run_result_text() {
  local code="$1" text
  shift
  run_result "$code" || return 1
  for text in "$@"; do
    has_text "$RUN_OUT" "$text" || return 1
  done
  return 0
}

# first_line_is <行>: RUN_OUT の1行目が行と一致すれば真。
first_line_is() {
  [ "$(printf '%s\n' "$RUN_OUT" | head -1)" = "$1" ]
}

# last_lines_are <行...>: RUN_OUT の末尾の行が引数の並び（先頭の引数が上の行）と一致すれば真。
last_lines_are() {
  [ "$(printf '%s\n' "$RUN_OUT" | tail -n "$#")" = "$(printf '%s\n' "$@")" ]
}

# assert <ラベル> <条件コマンド...>: 条件が真なら PASS、偽なら FAIL を1件計上する。
# FAIL 時は ASSERT_DETAIL（直近の run_in の終了コードと出力）を添える。
assert() {
  local label="$1"
  shift
  if "$@"; then
    pass "$label"
  else
    fail "$label${ASSERT_DETAIL:+
$ASSERT_DETAIL}"
  fi
}

# assert_not <ラベル> <条件コマンド...>: 条件が偽なら PASS、真なら FAIL を1件計上する。
assert_not() {
  local label="$1"
  shift
  if "$@"; then
    fail "$label${ASSERT_DETAIL:+
$ASSERT_DETAIL}"
  else
    pass "$label"
  fi
}

# 必須依存（git・backlog・bash）が無ければ SKIP を1件計上して finish_tests() で
# 終了する（テスト対象の不具合ではなくスキップとして扱うので終了ステータスは 0）。
# 各テストファイルの冒頭で呼ぶ。
#
# ここで finish_tests() を通すのは、サマリー行（PASS: x, FAIL: y, SKIP: z）を必ず
# 出力させるためである。tests/run.sh はこの行だけを見て各ファイルの結果を合算する
# ので、サマリー行を出さずに exit 0 すると、そのファイルは PASS にも FAIL にも
# SKIP にも計上されない。以前はここが printf + exit 0 だったため、backlog が
# PATH に無い環境では全ファイルがこの経路に入り、総合サマリーが
# PASS: 0, FAIL: 0, SKIP: 0 かつ exit 0 という「全件成功」と区別できない出力に
# なっていた（TASK-91）。
#
# bash は zsh で代替できる依存ではなく単独の必須依存である。run.sh は各テスト
# ファイルを bash で起動し、テスト本体も BASH_SOURCE・BASH_REMATCH・shopt など
# zsh では同じ意味にならない機能に依存している。bash と zsh を or 条件で見ると、
# zsh さえあれば依存を満たすと判定され、そのあと command not found で落ちても
# 原因が依存不足だと伝わらない。
#
# zsh はここでは見ない。zsh が要るのは install.zsh を実行するときだけなので、
# その依存は実際に実行する tests/test_setup_improvement_loop.sh が使用箇所で
# skip する形で局所的に扱う。ここで共通の必須依存にすると、install.zsh に
# 触れないテストまで zsh が無いだけで丸ごと止まる。
check_test_dependencies() {
  local missing=()
  local cmd
  for cmd in git backlog bash; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    skip "このテストの必須依存が無いためスキップする: ${missing[*]}"
    finish_tests
  fi
}

# 一時ディレクトリの後片付けレジストリ。作った直後に register_tmp_cleanup へ
# パスを渡して登録するだけでよい。trap は source 時に一度だけ設定するので、
# テストを追加するたびに trap 行を書き換える必要は無い。
TMP_CLEANUP_PATHS=()
register_tmp_cleanup() {
  TMP_CLEANUP_PATHS+=("$@")
}
cleanup_registered_tmp_paths() {
  if [ "${#TMP_CLEANUP_PATHS[@]}" -gt 0 ]; then
    rm -rf "${TMP_CLEANUP_PATHS[@]}"
  fi
}
trap cleanup_registered_tmp_paths EXIT

# 各テストファイルの末尾で呼ぶ。サマリー行を出力し、FAIL が1件でもあれば
# 非ゼロで終了する。tests/run.sh はこのサマリー行をパースして全ファイル分を合算する。
finish_tests() {
  echo ""
  echo "=== サマリー ==="
  printf 'PASS: %d, FAIL: %d, SKIP: %d\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

  if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  fi
  exit 0
}
