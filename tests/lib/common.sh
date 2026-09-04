# tests/lib/common.sh
#
# tests/test_*.sh の各ファイルから source される共通基盤。
# TASK-36 で tests/run.sh（旧・単一の1600行超モノリシックファイル）を
# 対象スクリプトごとの独立したテストファイルに分割した際に切り出した。
# このファイル自体は実行されず、必ず source される前提のためシバンは
# 付けない（bin/lib/resolve_path.sh と同じ慣例）。
#
# 提供するもの:
# - REPO_ROOT および各対象スクリプト・設定ファイルへのパス変数
# - PASS_COUNT/FAIL_COUNT/SKIP_COUNT と pass()/fail()/skip()
# - check_test_dependencies(): git/backlog/bash が無い環境での
#   スキップ判定（各テストファイルの冒頭で呼ぶ）
# - register_tmp_cleanup()/cleanup_registered_tmp_paths(): 一時ディレクトリの
#   後片付けをレジストリ方式でまとめる。新しい一時ディレクトリを使うテストを
#   追加する際は、ディレクトリを作った直後に register_tmp_cleanup へパスを
#   渡して登録するだけでよい。trap はこのファイルが source された時点で
#   一度だけ設定するため、テストを追加するたびに trap 行（それ以前の
#   cleanup 呼び出しの列挙）を書き換える必要が無い。
# - finish_tests(): 各テストファイル末尾で呼ぶ共通のサマリー出力・exit判定。
#   tests/run.sh はこのサマリー行（"PASS: x, FAIL: y, SKIP: z"）をパースして
#   全ファイル分を合算する。

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

# check_test_dependencies: 必須依存（git・backlog・bash）が無ければ
# その旨を報告して exit 0 する（テスト対象の不具合として扱わず
# スキップする）。各テストファイルの冒頭で呼ぶ。
#
# bash は「zsh でも代替できる依存」ではなく単独の必須依存である。
# tests/run.sh は各テストファイルを bash "$test_path" として起動し、
# githooks/pre-commit も exec bash で run.sh を起動する。テスト本体も
# BASH_SOURCE・BASH_REMATCH・shopt など zsh では同じ意味にならない
# bash 固有の機能に依存している。
#
# このリポジトリは macOS での実行を前提としており（README「前提条件」）、
# macOS では /bin/bash が OS 同梱で削除できないため、bash が欠けて
# ここに引っかかることは通常は起こらない。それでも bash を単独の必須依存
# として見ているのは、PATH を絞った実行など例外的な状況で判定が素通り
# しないようにするためである。以前はここで bash と zsh を or 条件で見て
# いたため、zsh さえあれば依存を満たすと判定され、そのあとテスト本体が
# command not found で落ちても失敗の原因が依存不足だとは伝わらなかった
# （TASK-81）。
#
# zsh はここでは見ない。zsh が要るのは install.zsh（シバンが
# #!/usr/bin/env zsh の zsh 専用スクリプト）を実行するときだけであり、
# bash の代わりに使えるものではない。その依存は install.zsh を実際に
# 実行する tests/test_setup_improvement_loop.sh が、使用箇所で
# command -v zsh を見て skip する形で局所的に扱う。ここで zsh を共通の
# 必須依存にすると、install.zsh に触れないテストまで zsh が無いだけで
# 丸ごと止まってしまう。
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

# 一時ディレクトリの後片付けレジストリ。
# 新しい一時ディレクトリを使うテストを追加する際は、ディレクトリを
# 作った直後に register_tmp_cleanup へパスを渡して登録するだけでよい。
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

# finish_tests: 各テストファイルの末尾で呼ぶ。サマリー行を出力し、
# FAIL が1件でもあれば非ゼロで終了する。
finish_tests() {
  echo ""
  echo "=== サマリー ==="
  printf 'PASS: %d, FAIL: %d, SKIP: %d\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

  if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  fi
  exit 0
}
