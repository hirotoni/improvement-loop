#!/usr/bin/env bash
# tests/test_list_opted_in_repos.sh
#
# bin/lib/list_opted_in_repos.sh の list_opted_in_repos() に対する単体テスト。
# 単体で実行すると、このファイルの検証だけが走る。tests/run.sh から全体実行の
# 一部としても呼ばれる。
#
# 依存は bash/zsh・git・backlog のみ。いずれか欠けていれば、その旨を
# 報告してスキップする（テスト対象の不具合として失敗にはしない）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

# shellcheck source=../bin/lib/list_opted_in_repos.sh
source "$LIST_OPTED_IN_REPOS_SCRIPT"

echo "=== 1. 一時ワークスペースディレクトリでの opt-in 判定 ==="

TMP_WORKSPACE="$(mktemp -d)"
register_tmp_cleanup "$TMP_WORKSPACE"

# あるダミースキルディレクトリ（シンボリックリンクの正しいリンク先として使う）。
DUMMY_SKILL_DIR="$(mktemp -d)"
register_tmp_cleanup "$DUMMY_SKILL_DIR"
mkdir -p "$DUMMY_SKILL_DIR/improvement-dispatch" "$DUMMY_SKILL_DIR/improvement-scout"

# ---- repo-opted-in-dispatch: git リポジトリ、improvement-dispatch に opt-in 済み ----
mkdir -p "$TMP_WORKSPACE/repo-opted-in-dispatch"
(cd "$TMP_WORKSPACE/repo-opted-in-dispatch" && git init -q)
mkdir -p "$TMP_WORKSPACE/repo-opted-in-dispatch/.claude/skills"
ln -s "$DUMMY_SKILL_DIR/improvement-dispatch" "$TMP_WORKSPACE/repo-opted-in-dispatch/.claude/skills/improvement-dispatch"

# ---- repo-opted-in-both: git リポジトリ、improvement-dispatch/improvement-scout 両方に opt-in 済み ----
mkdir -p "$TMP_WORKSPACE/repo-opted-in-both"
(cd "$TMP_WORKSPACE/repo-opted-in-both" && git init -q)
mkdir -p "$TMP_WORKSPACE/repo-opted-in-both/.claude/skills"
ln -s "$DUMMY_SKILL_DIR/improvement-dispatch" "$TMP_WORKSPACE/repo-opted-in-both/.claude/skills/improvement-dispatch"
ln -s "$DUMMY_SKILL_DIR/improvement-scout" "$TMP_WORKSPACE/repo-opted-in-both/.claude/skills/improvement-scout"

# ---- repo-not-opted-in: git リポジトリだが、対象スキルのシンボリックリンクが無い ----
mkdir -p "$TMP_WORKSPACE/repo-not-opted-in"
(cd "$TMP_WORKSPACE/repo-not-opted-in" && git init -q)

# ---- repo-broken-symlink: git リポジトリだが、シンボリックリンクのリンク先が存在しない ----
mkdir -p "$TMP_WORKSPACE/repo-broken-symlink"
(cd "$TMP_WORKSPACE/repo-broken-symlink" && git init -q)
mkdir -p "$TMP_WORKSPACE/repo-broken-symlink/.claude/skills"
ln -s "$DUMMY_SKILL_DIR/does-not-exist" "$TMP_WORKSPACE/repo-broken-symlink/.claude/skills/improvement-dispatch"

# ---- not-a-git-repo: 通常のディレクトリ（git リポジトリではない）だが、
#      対象スキルのシンボリックリンクは正しく存在する ----
mkdir -p "$TMP_WORKSPACE/not-a-git-repo/.claude/skills"
ln -s "$DUMMY_SKILL_DIR/improvement-dispatch" "$TMP_WORKSPACE/not-a-git-repo/.claude/skills/improvement-dispatch"

# ---- a-plain-file: ディレクトリではなくファイル（深さ1の非ディレクトリ混在の回帰） ----
: > "$TMP_WORKSPACE/a-plain-file"

# ---- テスト対象呼び出し（marker=improvement-dispatch） ----
dispatch_result="$(list_opted_in_repos "$TMP_WORKSPACE" "improvement-dispatch")"

expected_dispatch=$'repo-opted-in-both\nrepo-opted-in-dispatch'
actual_dispatch_names="$(printf '%s\n' "$dispatch_result" | xargs -n1 basename | sort)"
if [ "$actual_dispatch_names" = "$expected_dispatch" ]; then
  pass "marker=improvement-dispatch: opt-in 済みリポジトリ（repo-opted-in-dispatch, repo-opted-in-both）だけが列挙される"
else
  fail "marker=improvement-dispatch: 期待した集合と異なる。期待:
$expected_dispatch
実際:
$actual_dispatch_names"
fi

# 絶対パスで返っていることを確認する。
first_line="$(printf '%s\n' "$dispatch_result" | head -1)"
case "$first_line" in
  /*) pass "list_opted_in_repos は絶対パスを返す" ;;
  *) fail "list_opted_in_repos が絶対パスを返していない: $first_line" ;;
esac

# ソート済み（辞書順）であることを確認する。
sorted_check="$(printf '%s\n' "$dispatch_result" | sort)"
if [ "$dispatch_result" = "$sorted_check" ]; then
  pass "list_opted_in_repos の出力はソート済みである"
else
  fail "list_opted_in_repos の出力がソートされていない: $dispatch_result"
fi

# ---- テスト対象呼び出し（marker=improvement-scout） ----
scout_result="$(list_opted_in_repos "$TMP_WORKSPACE" "improvement-scout")"
actual_scout_names="$(printf '%s\n' "$scout_result" | xargs -n1 basename | sort)"
if [ "$actual_scout_names" = "repo-opted-in-both" ]; then
  pass "marker=improvement-scout: opt-in 済みリポジトリ（repo-opted-in-both のみ）だけが列挙される"
else
  fail "marker=improvement-scout: 期待した集合と異なる。期待: repo-opted-in-both
実際:
$actual_scout_names"
fi

# ---- 除外対象が誤って含まれていないことの直接確認 ----
if printf '%s\n' "$dispatch_result" | grep -Fq "repo-not-opted-in"; then
  fail "opt-in していないリポジトリ（repo-not-opted-in）が誤って含まれている"
else
  pass "opt-in していないリポジトリ（repo-not-opted-in）が正しく除外される"
fi

if printf '%s\n' "$dispatch_result" | grep -Fq "repo-broken-symlink"; then
  fail "リンク切れのシンボリックリンクを持つリポジトリ（repo-broken-symlink）が誤って含まれている"
else
  pass "リンク切れのシンボリックリンクを持つリポジトリ（repo-broken-symlink）が正しく除外される"
fi

if printf '%s\n' "$dispatch_result" | grep -Fq "not-a-git-repo"; then
  fail "git リポジトリでないディレクトリ（not-a-git-repo）が誤って含まれている"
else
  pass "git リポジトリでないディレクトリ（not-a-git-repo）が正しく除外される"
fi

echo ""
echo "=== 2. 境界ケース ==="

# ---- ワークスペースディレクトリが存在しない ----
NONEXISTENT_WORKSPACE="$TMP_WORKSPACE/does-not-exist"
nonexistent_output="$(list_opted_in_repos "$NONEXISTENT_WORKSPACE" "improvement-dispatch")"
nonexistent_exit=$?
if [ "$nonexistent_exit" -eq 0 ] && [ -z "$nonexistent_output" ]; then
  pass "存在しないワークスペースディレクトリに対して exit 0・空出力を返す"
else
  fail "存在しないワークスペースディレクトリに対する挙動が想定と異なる（exit ${nonexistent_exit}）: $nonexistent_output"
fi

# ---- 直下にサブディレクトリが1つも無い空のワークスペース ----
EMPTY_WORKSPACE="$(mktemp -d)"
register_tmp_cleanup "$EMPTY_WORKSPACE"
empty_output="$(list_opted_in_repos "$EMPTY_WORKSPACE" "improvement-dispatch")"
empty_exit=$?
if [ "$empty_exit" -eq 0 ] && [ -z "$empty_output" ]; then
  pass "サブディレクトリが1つも無いワークスペースに対して exit 0・空出力を返す（nullglob 由来の誤展開が無い）"
else
  fail "空のワークスペースに対する挙動が想定と異なる（exit ${empty_exit}）: $empty_output"
fi

# ---- 引数不足 ----
if list_opted_in_repos "$TMP_WORKSPACE" >/dev/null 2>&1; then
  fail "skill_marker_name を省略しても成功してしまう（本来は非ゼロで終了すべき）"
else
  pass "skill_marker_name を省略すると非ゼロで終了する"
fi

finish_tests
