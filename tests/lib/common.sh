# tests/test_*.sh の各ファイルから source される共通基盤。実行されず、必ず
# source される前提のためシバンは付けない。
#
# 提供するもの:
# - REPO_ROOT および各対象スクリプト・設定ファイルへのパス変数
# - PASS_COUNT/FAIL_COUNT/SKIP_COUNT と pass()/fail()/skip()
# - check_test_dependencies(): 必須依存が無い環境でのスキップ判定
# - register_tmp_cleanup()/cleanup_registered_tmp_paths(): 一時ディレクトリの後片付け
# - finish_tests(): 各テストファイル末尾で呼ぶサマリー出力・exit判定

COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$COMMON_LIB_DIR/../.." && pwd)"

SETUP_SCRIPT="$REPO_ROOT/bin/setup-improvement-loop"
CREATE_WORKTREE_SCRIPT="$REPO_ROOT/claude-code/skills/improvement-dispatch/scripts/create-worktree"
MERGE_SCRIPT="$REPO_ROOT/claude-code/skills/improvement-dispatch/scripts/merge-reviewed-branch"
SELECT_SCRIPT="$REPO_ROOT/claude-code/skills/improvement-dispatch/scripts/select-next-task"
CHECK_RECOVERY_SCRIPT="$REPO_ROOT/claude-code/skills/improvement-dispatch/scripts/check-progress-recovery"
CHECK_HANDOFF_SCRIPT="$REPO_ROOT/claude-code/skills/improvement-work/scripts/check-handoff"
CHECK_FORBIDDEN_ALLOWED_SCRIPT="$REPO_ROOT/claude-code/skills/improvement-dispatch/scripts/check-forbidden-allowed-paths"
RESOLVE_PATH_SCRIPT="$REPO_ROOT/bin/lib/resolve_path.sh"
YAML_UNQUOTE_SCRIPT="$REPO_ROOT/bin/lib/yaml_unquote.sh"
LIST_OPTED_IN_REPOS_SCRIPT="$REPO_ROOT/bin/lib/list_opted_in_repos.sh"
WORKTREE_PORCELAIN_SCRIPT="$REPO_ROOT/bin/lib/worktree_porcelain.sh"
WORKSPACE_DISPATCH_LIST_TARGET_REPOS_SCRIPT="$REPO_ROOT/claude-code/workspace-skills/workspace-dispatch/scripts/list-target-repos"
WORKSPACE_SCOUT_LIST_TARGET_REPOS_SCRIPT="$REPO_ROOT/claude-code/workspace-skills/workspace-scout/scripts/list-target-repos"
WORKSPACE_SCOUT_MAJOR_LIST_TARGET_REPOS_SCRIPT="$REPO_ROOT/claude-code/workspace-skills/workspace-scout-major/scripts/list-target-repos"
INSTALL_SCRIPT="$REPO_ROOT/install.zsh"
PRECOMMIT_HOOK="$REPO_ROOT/githooks/pre-commit"
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

# 必須依存（git・backlog・bash）が無ければ報告して exit 0 する（テスト対象の
# 不具合ではなくスキップとして扱う）。各テストファイルの冒頭で呼ぶ。
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
    printf 'このテストの必須依存が無いためスキップする: %s\n' "${missing[*]}"
    exit 0
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
