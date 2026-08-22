#!/usr/bin/env bash
# tests/run.sh
#
# improvement-loop の依存ゼロの最小テストランナー。
# 依存は bash/zsh・git・backlog のみ。いずれか欠けていれば、その旨を
# 報告してスキップする（テスト対象の不具合として失敗にはしない）。
#
# 実行するもの:
#   1. install.zsh / bin/setup-improvement-loop の構文チェック（bash -n）。
#      shellcheck があれば追加で実行する（無ければスキップを明示）。
#   2. 一時 git リポジトリに対して bin/setup-improvement-loop を実行し、
#      配置結果（シンボリックリンク・config.my.yml・.git/info/exclude）を検証する。
#   3. 同じ一時リポジトリに対して再実行し、冪等性とユーザー所有ファイル保護を検証する。
#
# 1 件でも失敗すれば非ゼロで終了する。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP_SCRIPT="$REPO_ROOT/bin/setup-improvement-loop"
INSTALL_SCRIPT="$REPO_ROOT/install.zsh"
SOURCE_CONFIG="$REPO_ROOT/backlogmd-custom-config/config.my.yml"
SOURCE_SKILLS_DIR="$REPO_ROOT/claude-skills"

# SKILL_NAMES は claude-skills/ ディレクトリの実体を単一の情報源として動的に
# 列挙する。bin/setup-improvement-loop 側と同じ方式で導出することで、片方だけ
# 更新して他方が追随しないという実装依存の同期漏れを構造的に無くす。
shopt -s nullglob
SKILL_NAMES=()
for skill_dir in "$SOURCE_SKILLS_DIR"/*/; do
  SKILL_NAMES+=("$(basename "$skill_dir")")
done
shopt -u nullglob
if [ "${#SKILL_NAMES[@]}" -eq 0 ]; then
  printf 'FAIL: claude-skills 配下にスキルディレクトリが1つも無い: %s\n' "$SOURCE_SKILLS_DIR"
  exit 1
fi

# REQUIRED_STATUSES は bin/setup-improvement-loop 側の定義を単一の情報源として
# 使う。ここに配列リテラルを複製すると、片方だけ更新されてテストが実体と
# ズレたまま緑になる恐れがあるため、対象スクリプトからその1行を抽出して評価する。
REQUIRED_STATUSES_DEF="$(grep -m1 '^REQUIRED_STATUSES=' "$SETUP_SCRIPT" || true)"
if [ -z "$REQUIRED_STATUSES_DEF" ]; then
  printf 'FAIL: bin/setup-improvement-loop に REQUIRED_STATUSES の定義が見つからない\n'
  exit 1
fi
eval "$REQUIRED_STATUSES_DEF"

# .backlog/config.yml の statuses 行に REQUIRED_STATUSES の全項目が含まれるか検証する。
# 引数: config.yml のパス, 呼び出し元がログに出す説明文の接頭辞
assert_statuses_present() {
  local config_file="$1"
  local label="$2"
  if [ ! -f "$config_file" ]; then
    fail "$label: $config_file が存在しない"
    return
  fi
  local status_line
  status_line="$(grep -m1 '^statuses:' "$config_file" || true)"
  if [ -z "$status_line" ]; then
    fail "$label: $config_file に statuses 行が無い"
    return
  fi
  local missing=()
  local status
  for status in "${REQUIRED_STATUSES[@]}"; do
    if ! grep -Fq "\"$status\"" <<<"$status_line"; then
      missing+=("$status")
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    pass "$label: statuses に improvement ループの既定6ステータスがすべて含まれる"
  else
    fail "$label: statuses に不足がある（${missing[*]}）: $status_line"
  fi
}

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

# ---- 0. 依存の確認 ----
missing=()
for cmd in git backlog; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done
if ! command -v bash >/dev/null 2>&1 && ! command -v zsh >/dev/null 2>&1; then
  missing+=("bash または zsh")
fi

if [ "${#missing[@]}" -gt 0 ]; then
  printf 'このテストの必須依存が無いためスキップする: %s\n' "${missing[*]}"
  exit 0
fi

echo "=== 1. 構文チェック ==="

if bash -n "$INSTALL_SCRIPT" 2>/tmp/tests-run-sh-syntax-err.$$; then
  pass "bash -n install.zsh"
else
  fail "bash -n install.zsh: $(cat /tmp/tests-run-sh-syntax-err.$$)"
fi

if bash -n "$SETUP_SCRIPT" 2>>/tmp/tests-run-sh-syntax-err.$$; then
  pass "bash -n bin/setup-improvement-loop"
else
  fail "bash -n bin/setup-improvement-loop: $(cat /tmp/tests-run-sh-syntax-err.$$)"
fi
rm -f /tmp/tests-run-sh-syntax-err.$$

if command -v shellcheck >/dev/null 2>&1; then
  # bin/setup-improvement-loop は bash なので shellcheck が完全サポートする。
  # install.zsh とまとめて1回の shellcheck 呼び出しで渡すと、zsh は
  # shellcheck が対応しない shell のため SC1071 で即座に fatal
  # parse error になり、setup-improvement-loop 側も一切linterされずに
  # 巻き添えで FAIL してしまう。そのため個別に実行する。
  if shellcheck "$SETUP_SCRIPT"; then
    pass "shellcheck bin/setup-improvement-loop"
  else
    fail "shellcheck bin/setup-improvement-loop (指摘あり。上の出力を参照)"
  fi

  # install.zsh は zsh 専用スクリプトで、shellcheck は zsh を直接サポート
  # しない。ファイル冒頭の `# shellcheck shell=bash` ディレクティブにより
  # bash として（精度は落ちるが）解析させる。zsh 固有構文（${0:A:h} や
  # print 組み込みなど）による誤検知が出ることがあるため、ここでの指摘は
  # 参考情報として報告するのみで、テスト全体の hard failure にはしない。
  if shellcheck "$INSTALL_SCRIPT"; then
    pass "shellcheck install.zsh (shell=bash として、精度は参考程度)"
  else
    echo "NOTE: shellcheck install.zsh に指摘あり。install.zsh は zsh 専用のため" \
         "zsh 構文由来の誤検知を含みうる。上の出力を参照し、実際のバグかどうかは" \
         "目視で判断すること（この結果だけでテストを失敗にはしない）。"
    skip "shellcheck install.zsh (指摘あり。zsh 構文の誤検知の可能性があるため参考情報扱い)"
  fi
else
  skip "shellcheck が PATH に無いため実行しなかった"
fi

echo ""
echo "=== 2. 一時リポジトリへのセットアップ ==="

TMP_REPO="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
TMP_REPO_SYMLINK="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_REPO" "$TMP_HOME" "$TMP_REPO_SYMLINK"
}
trap cleanup EXIT

(cd "$TMP_REPO" && git init -q)

setup_output="$("$SETUP_SCRIPT" "$TMP_REPO" 2>&1)"
setup_exit=$?
if [ "$setup_exit" -eq 0 ]; then
  pass "1回目の setup-improvement-loop 実行が成功する（exit 0）"
else
  fail "1回目の setup-improvement-loop 実行が失敗した（exit ${setup_exit}）:
$setup_output"
fi

# ---- シンボリックリンクの検証 ----
for name in "${SKILL_NAMES[@]}"; do
  link_path="$TMP_REPO/.claude/skills/$name"
  expected_target="$SOURCE_SKILLS_DIR/$name"
  if [ -L "$link_path" ]; then
    resolved="$(cd "$link_path" 2>/dev/null && pwd -P)"
    expected_resolved="$(cd "$expected_target" && pwd -P)"
    if [ "$resolved" = "$expected_resolved" ]; then
      pass ".claude/skills/$name はリポジトリの claude-skills/$name への正しいシンボリックリンクである"
    else
      fail ".claude/skills/$name のリンク先が誤っている（${resolved} != ${expected_resolved}）"
    fi
  else
    fail ".claude/skills/$name がシンボリックリンクとして存在しない"
  fi
done

# ---- .backlog/config.yml の statuses の検証 ----
# backlog init --defaults の既定 statuses は To Do / In Progress / Done の3種のみで、
# improvement ループの4スキルが前提とする Proposed / In Review / Reviewed が無いと
# improvement-work が最初に In Review へ上げようとした時点で Invalid status で失敗する。
assert_statuses_present "$TMP_REPO/.backlog/config.yml" "1回目実行後"

# ---- config.my.yml の検証 ----
target_config="$TMP_REPO/.backlog/config.my.yml"
if [ -f "$target_config" ]; then
  if diff -q "$SOURCE_CONFIG" "$target_config" >/dev/null 2>&1; then
    pass ".backlog/config.my.yml がソースと一致する"
  else
    fail ".backlog/config.my.yml がソースと一致しない"
  fi
else
  fail ".backlog/config.my.yml が存在しない"
fi

# ---- .git/info/exclude の検証 ----
exclude_file="$TMP_REPO/.git/info/exclude"
expected_lines=(".backlog/")
for name in "${SKILL_NAMES[@]}"; do
  expected_lines+=(".claude/skills/$name")
done

if [ -f "$exclude_file" ]; then
  all_present=true
  for line in "${expected_lines[@]}"; do
    if ! grep -Fxq "$line" "$exclude_file"; then
      all_present=false
      fail ".git/info/exclude に '$line' が無い"
    fi
  done
  if [ "$all_present" = true ]; then
    pass ".git/info/exclude に期待する ${#expected_lines[@]} 行がすべて含まれる"
  fi
else
  fail ".git/info/exclude が存在しない"
fi

echo ""
echo "=== 2b. install.zsh 経由でシンボリックリンクされた状態での実行 ==="
# install.zsh は bin/setup-improvement-loop を $HOME/.local/bin にシンボリック
# リンクする。実際にインストールされた環境では、このスクリプトは常にリンク
# 経由で起動される。BASH_SOURCE をシンボリックリンク解決せずに使うと、配布元
# ルートの算出を誤り「配布元の claude-skills ディレクトリが見つからない」で
# 落ちる（過去の不具合）。一時 $HOME に対して install.zsh を実行し、出来た
# シンボリックリンク経由で setup-improvement-loop を起動して検証する。

if command -v zsh >/dev/null 2>&1; then
  install_output="$(HOME="$TMP_HOME" zsh "$INSTALL_SCRIPT" 2>&1)"
  install_exit=$?
  if [ "$install_exit" -eq 0 ]; then
    pass "install.zsh が一時 \$HOME に対して成功する（exit 0）"
  else
    fail "install.zsh が一時 \$HOME に対して失敗した（exit ${install_exit}）:
$install_output"
  fi

  INSTALLED_SYMLINK="$TMP_HOME/.local/bin/setup-improvement-loop"
  if [ -L "$INSTALLED_SYMLINK" ]; then
    pass "install.zsh が $INSTALLED_SYMLINK にシンボリックリンクを作成した"

    (cd "$TMP_REPO_SYMLINK" && git init -q)

    symlink_output="$("$INSTALLED_SYMLINK" "$TMP_REPO_SYMLINK" 2>&1)"
    symlink_exit=$?
    if [ "$symlink_exit" -eq 0 ]; then
      pass "シンボリックリンク経由の setup-improvement-loop 実行が成功する（exit 0）"
    else
      fail "シンボリックリンク経由の setup-improvement-loop 実行が失敗した（exit ${symlink_exit}）:
$symlink_output"
    fi

    symlink_links_ok=true
    for name in "${SKILL_NAMES[@]}"; do
      link_path="$TMP_REPO_SYMLINK/.claude/skills/$name"
      expected_target="$SOURCE_SKILLS_DIR/$name"
      if [ -L "$link_path" ]; then
        resolved="$(cd "$link_path" 2>/dev/null && pwd -P)"
        expected_resolved="$(cd "$expected_target" && pwd -P)"
        if [ "$resolved" != "$expected_resolved" ]; then
          symlink_links_ok=false
          fail "シンボリックリンク経由実行: .claude/skills/$name のリンク先が誤っている（${resolved} != ${expected_resolved}）"
        fi
      else
        symlink_links_ok=false
        fail "シンボリックリンク経由実行: .claude/skills/$name がシンボリックリンクとして存在しない"
      fi
    done
    if [ "$symlink_links_ok" = true ]; then
      pass "シンボリックリンク経由実行でも、本物のリポジトリの claude-skills/ を配布元として正しく使えている"
    fi
  else
    fail "install.zsh がシンボリックリンクを作成しなかった: $INSTALLED_SYMLINK"
  fi
else
  skip "zsh が PATH に無いため、シンボリックリンク経由の実行テストを行わなかった"
fi

echo ""
echo "=== 3. 冪等性・ユーザー所有ファイル保護の検証 ==="

MARKER="# TEST-MARKER-$$-$(date +%s)"
printf '\n%s\n' "$MARKER" >> "$target_config"

# .backlog/config.yml の statuses にユーザー独自のステータスを追加しておき、
# 再実行で消えないこと（既存設定の保持）と、6ステータスが揃った状態が
# 維持されること（欠けている分だけ補う冪等性）を同時に検証する。
target_backlog_config="$TMP_REPO/.backlog/config.yml"
CUSTOM_STATUS="CustomStatus-$$"
cp "$target_backlog_config" "$target_backlog_config.pre-idempotency-check"
sed "s/^statuses: \[\(.*\)\]\$/statuses: [\1, \"$CUSTOM_STATUS\"]/" \
  "$target_backlog_config.pre-idempotency-check" > "$target_backlog_config"
rm -f "$target_backlog_config.pre-idempotency-check"

setup_output2="$("$SETUP_SCRIPT" "$TMP_REPO" 2>&1)"
setup_exit2=$?
if [ "$setup_exit2" -eq 0 ]; then
  pass "2回目の setup-improvement-loop 実行が成功する（exit 0）"
else
  fail "2回目の setup-improvement-loop 実行が失敗した（exit ${setup_exit2}）:
$setup_output2"
fi

if grep -Fxq "$MARKER" "$target_config" 2>/dev/null; then
  pass "再実行後も .backlog/config.my.yml へのユーザー変更が保持されている（上書きされない）"
else
  fail "再実行で .backlog/config.my.yml のユーザー変更が失われた"
fi

# ---- .backlog/config.yml の statuses の冪等性・既存設定保持の検証 ----
assert_statuses_present "$target_backlog_config" "2回目実行後"
if grep -m1 '^statuses:' "$target_backlog_config" | grep -Fq "\"$CUSTOM_STATUS\""; then
  pass "再実行後もユーザー独自の statuses（${CUSTOM_STATUS}）が保持されている"
else
  fail "再実行でユーザー独自の statuses（${CUSTOM_STATUS}）が失われた"
fi

# シンボリックリンクが再実行後も壊れていないことも確認する。
links_ok=true
for name in "${SKILL_NAMES[@]}"; do
  link_path="$TMP_REPO/.claude/skills/$name"
  if [ -L "$link_path" ] && [ -d "$link_path" ]; then
    : # ok
  else
    links_ok=false
    fail "再実行後、.claude/skills/$name が正しいシンボリックリンクでなくなっている"
  fi
done
if [ "$links_ok" = true ]; then
  pass "再実行後もすべてのシンボリックリンクが健全である"
fi

# .git/info/exclude に重複行が増えていないことも確認する。
no_dup=true
for line in "${expected_lines[@]}"; do
  count="$(grep -Fxc "$line" "$exclude_file" 2>/dev/null || true)"
  if [ "$count" != "1" ]; then
    no_dup=false
    fail "再実行後、.git/info/exclude の '$line' が重複している（$count 行）"
  fi
done
if [ "$no_dup" = true ]; then
  pass ".git/info/exclude に重複行が無い（再実行後も各行1回）"
fi

echo ""
echo "=== 4. statuses: [] (空配列) に対する回帰テスト ==="
# macOS の既定 /bin/bash は 3.2 系であり、set -u 下で空配列を
# "${arr[@]}" のように無条件展開すると unbound variable で落ちる
# （bash 4.4 で修正されたバグ）。.backlog/config.yml の statuses が
# 空配列（例: ユーザーが手動で `statuses: []` にした場合）でも
# setup-improvement-loop がクラッシュしないことを確認する。

TMP_REPO_EMPTY_STATUSES="$(mktemp -d)"
cleanup_empty_statuses() {
  rm -rf "$TMP_REPO_EMPTY_STATUSES"
}
trap 'cleanup_empty_statuses; cleanup' EXIT

(cd "$TMP_REPO_EMPTY_STATUSES" && git init -q)
mkdir -p "$TMP_REPO_EMPTY_STATUSES/.backlog"
cat > "$TMP_REPO_EMPTY_STATUSES/.backlog/config.yml" <<'YAML'
project_name: "empty-statuses-test"
default_status: "To Do"
statuses: []
labels: []
date_format: yyyy-mm-dd
max_column_width: 20
auto_open_browser: true
default_port: 6420
remote_operations: true
auto_commit: false
filesystem_only: false
bypass_git_hooks: false
check_active_branches: true
active_branch_days: 30
task_prefix: "task"
YAML

empty_statuses_output="$("$SETUP_SCRIPT" "$TMP_REPO_EMPTY_STATUSES" 2>&1)"
empty_statuses_exit=$?
if [ "$empty_statuses_exit" -eq 0 ]; then
  pass "statuses: [] な config.yml に対しても setup-improvement-loop が成功する（exit 0）"
else
  fail "statuses: [] な config.yml で setup-improvement-loop が失敗した（exit ${empty_statuses_exit}）:
$empty_statuses_output"
fi
assert_statuses_present "$TMP_REPO_EMPTY_STATUSES/.backlog/config.yml" "statuses: [] からの補完後"

echo ""
echo "=== サマリー ==="
printf 'PASS: %d, FAIL: %d, SKIP: %d\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
