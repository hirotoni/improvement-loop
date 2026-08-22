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
CREATE_WORKTREE_SCRIPT="$REPO_ROOT/bin/create-worktree"
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

if bash -n "$CREATE_WORKTREE_SCRIPT" 2>>/tmp/tests-run-sh-syntax-err.$$; then
  pass "bash -n bin/create-worktree"
else
  fail "bash -n bin/create-worktree: $(cat /tmp/tests-run-sh-syntax-err.$$)"
fi
rm -f /tmp/tests-run-sh-syntax-err.$$

if command -v shellcheck >/dev/null 2>&1; then
  # bin/setup-improvement-loop・bin/create-worktree は bash なので shellcheck が
  # 完全サポートする。install.zsh とまとめて1回の shellcheck 呼び出しで渡すと、
  # zsh は shellcheck が対応しない shell のため SC1071 で即座に fatal
  # parse error になり、他のスクリプト側も一切linterされずに巻き添えで FAIL
  # してしまう。そのため個別に実行する。
  if shellcheck "$SETUP_SCRIPT"; then
    pass "shellcheck bin/setup-improvement-loop"
  else
    fail "shellcheck bin/setup-improvement-loop (指摘あり。上の出力を参照)"
  fi

  if shellcheck "$CREATE_WORKTREE_SCRIPT"; then
    pass "shellcheck bin/create-worktree"
  else
    fail "shellcheck bin/create-worktree (指摘あり。上の出力を参照)"
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
echo "=== 1c. SKILL.md 埋め込み bash ブロックの構文チェック ==="
# claude-skills/improvement-dispatcher/SKILL.md と claude-skills/improvement-work/SKILL.md には、
# orchestrator/work が実際に実行する bash コードブロックが埋め込まれている
# （例: improvement-dispatcher の手順3・手順5）。ここでは各 ```bash フェンスブロックを抽出し、
# bash -n で構文チェックする。フェンスは箇条書きの入れ子（行頭に空白のインデント）で
# 書かれていることがあるため、行頭が完全に ```bash / ``` と一致する場合だけでなく、
# 前後に空白を許した正規表現でマッチさせる。
#
# ブロックには <n> や <作業ブランチ> のようなプレースホルダが含まれることがある。この山括弧を
# そのまま bash -n に渡すと、bash がリダイレクト演算子（`<`/`>`）として誤解釈し、プレース
# ホルダ自体が原因の構文エラーになる（例: `git worktree remove <ワークツリーのパス>` は、
# `<`/`>` の後に続くはずのファイル名が無いというエラーになる）。これは TASK-6 実装時に手動で
# `bash -n` を17ブロック（dispatcher 9個、work 8個）に対して実行した際、4ブロックを
# プレースホルダ由来として個別に除外した対象と一致する。
# ここではブロックを除外する代わりに、構文チェック前に `<...>`（山括弧を含まない中身）を
# 安全なダミートークンへ機械的に置換する。これにより山括弧に起因する偽陽性を消しつつ、
# クォートの閉じ忘れ等の本物の構文エラーはそのまま検出できるので、個別のブロック除外リストを
# 保守せずに恒常的な自動チェックの対象へ含められる。置換パターンは `<(` で始まる箇所
# （プロセス置換 `<(cmd)`）を除外しており、`<(cmd1) <(cmd2) > out` のような行で
# 2つ目のプロセス置換と実際のリダイレクトを1つのプレースホルダとして誤って飲み込まないようにする。
check_skill_bash_blocks() {
  local skill_file="$1"
  local label="$2"

  if [ ! -f "$skill_file" ]; then
    fail "$label: $skill_file が存在しない"
    return
  fi

  local open_re='^[[:space:]]*```bash[[:space:]]*$'
  local close_re='^[[:space:]]*```[[:space:]]*$'

  # 抽出ループとは独立に開始フェンス（```bash、インデント許容）の総数を数え、
  # ループ側の処理件数と突き合わせる。ループのバグ（フェンスの見落とし、閉じフェンスが
  # 無いまま終端する 等）でブロックが黙って処理から漏れることを検出するための二重チェック。
  local expected_count
  expected_count="$(grep -Ec "$open_re" "$skill_file" || true)"

  local in_block=0
  local block_num=0
  local block=""
  local line
  local found_any=0

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_block" -eq 0 ]; then
      if [[ "$line" =~ $open_re ]]; then
        in_block=1
        block=""
      fi
      continue
    fi

    if [[ "$line" =~ $close_re ]]; then
      in_block=0
      block_num=$((block_num + 1))
      found_any=1

      local sanitized
      sanitized="$(printf '%s\n' "$block" | sed -E 's/<[^<>(][^<>]*>/PLACEHOLDER_TOKEN/g')"

      if [ -z "$(printf '%s' "$sanitized" | tr -d '[:space:]')" ]; then
        fail "$label: bash ブロック #$block_num が空である（内容の抽出漏れの可能性がある）"
        continue
      fi

      local block_tmp
      block_tmp="$(mktemp)"
      printf '%s' "$sanitized" > "$block_tmp"

      local err_out
      err_out="$(bash -n "$block_tmp" 2>&1)"
      local rc=$?
      rm -f "$block_tmp"

      if [ "$rc" -eq 0 ]; then
        pass "$label: bash ブロック #$block_num の構文チェック"
      else
        fail "$label: bash ブロック #$block_num の構文エラー: $err_out"
      fi
      continue
    fi

    block+="$line"$'\n'
  done < "$skill_file"

  if [ "$in_block" -eq 1 ]; then
    fail "$label: 閉じフェンス（\`\`\`）が見つからないまま bash ブロックが終端した（ブロック #$((block_num + 1)) 相当）"
  fi

  if [ "$found_any" -eq 0 ]; then
    fail "$label: \`\`\`bash ブロックが1つも見つからない（抽出ロジックの不具合の可能性がある）"
  elif [ "$block_num" -ne "$expected_count" ]; then
    fail "$label: 抽出できたブロック数（$block_num）が開始フェンスの総数（$expected_count）と一致しない（見落としの可能性がある）"
  fi
}

check_skill_bash_blocks "$SOURCE_SKILLS_DIR/improvement-dispatcher/SKILL.md" "improvement-dispatcher/SKILL.md"
check_skill_bash_blocks "$SOURCE_SKILLS_DIR/improvement-work/SKILL.md" "improvement-work/SKILL.md"

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
expected_lines=(".backlog")
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
echo "=== 5. statuses の複数行YAMLリスト形式に対する回帰テスト ==="
# .backlog/config.yml の statuses を複数行YAMLリスト形式
# （statuses: の次行以降に "  - \"To Do\"" のように列挙する形式）で手動編集する
# ケースは想定されている（bin/setup-improvement-loop:15-19 の冪等性方針コメント、
# 各SKILL.mdの手順が config.yml の statuses への直接編集を案内している）。
# この形式で setup-improvement-loop を（再）実行しても、壊れたYAML
# （置換し損ねた元の "  - ..." 行が残る等）を生成しないことを確認する。

TMP_REPO_MULTILINE_STATUSES="$(mktemp -d)"
cleanup_multiline_statuses() {
  rm -rf "$TMP_REPO_MULTILINE_STATUSES"
}
trap 'cleanup_multiline_statuses; cleanup_empty_statuses; cleanup' EXIT

(cd "$TMP_REPO_MULTILINE_STATUSES" && git init -q)
mkdir -p "$TMP_REPO_MULTILINE_STATUSES/.backlog"
cat > "$TMP_REPO_MULTILINE_STATUSES/.backlog/config.yml" <<'YAML'
project_name: "multiline-statuses-test"
default_status: "To Do"
statuses:
  - "To Do"
  - "In Progress"
  - "Done"
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

multiline_statuses_output="$("$SETUP_SCRIPT" "$TMP_REPO_MULTILINE_STATUSES" 2>&1)"
multiline_statuses_exit=$?
if [ "$multiline_statuses_exit" -eq 0 ]; then
  pass "statuses が複数行YAMLリスト形式な config.yml に対しても setup-improvement-loop が成功する（exit 0）"
else
  fail "statuses が複数行YAMLリスト形式な config.yml で setup-improvement-loop が失敗した（exit ${multiline_statuses_exit}）:
$multiline_statuses_output"
fi

multiline_result_config="$TMP_REPO_MULTILINE_STATUSES/.backlog/config.yml"
assert_statuses_present "$multiline_result_config" "複数行リスト形式からの補完後"

# statuses: 行の直後に、置換し損ねた元の "  - ..." 行が残っていないことを確認する
# （壊れたYAMLになっていないことの直接的な検証）。
orphan_list_lines="$(awk '
  /^statuses:/ { found=1; next }
  found && /^[[:space:]]*-/ { print; next }
  found { exit }
' "$multiline_result_config")"
if [ -z "$orphan_list_lines" ]; then
  pass "statuses: 行の直後に元の複数行リスト項目が残っていない（壊れたYAMLになっていない）"
else
  fail "statuses: 行の直後に元の複数行リスト項目が残っている（壊れたYAMLの兆候）: $orphan_list_lines"
fi

# statuses 以降の他のトップレベルキー（labels 等）が失われていない
# （置換対象の行範囲を誤って広げ過ぎていない）ことも確認する。
if grep -Fxq 'labels: []' "$multiline_result_config"; then
  pass "statuses 以降の他のキー（labels）が保持されている"
else
  fail "statuses 以降の他のキー（labels）が失われた、または壊れた"
fi

# 再実行しても壊れず、冪等であることも確認する（正規化後はインライン形式に
# なっているはずなので、既存のインライン形式向け経路がそのまま通る）。
multiline_statuses_output2="$("$SETUP_SCRIPT" "$TMP_REPO_MULTILINE_STATUSES" 2>&1)"
multiline_statuses_exit2=$?
if [ "$multiline_statuses_exit2" -eq 0 ]; then
  pass "複数行リスト形式から正規化された後の再実行も成功する（exit 0）"
else
  fail "複数行リスト形式から正規化された後の再実行が失敗した（exit ${multiline_statuses_exit2}）:
$multiline_statuses_output2"
fi
assert_statuses_present "$multiline_result_config" "複数行リスト形式からの正規化後、再実行後"

echo ""
echo "=== 6. config.my.yml の不足キー補完（マイグレーション）の回帰テスト ==="
# 配布元テンプレート（backlogmd-custom-config/config.my.yml）に新しいキーが
# 追加された状況を、「導入先の config.my.yml に一部キーが欠けている」状態として
# 再現する。setup-improvement-loop を実行すると、欠けているキーだけがテンプレート
# 側のコメント・既定値付きで補われ、既存のキーの値・コメント、テンプレートに
# 無いユーザー独自のキーはそのまま残ることを確認する（TASK-19）。

TMP_REPO_MIGRATION="$(mktemp -d)"
cleanup_migration() {
  rm -rf "$TMP_REPO_MIGRATION"
}
trap 'cleanup_migration; cleanup_multiline_statuses; cleanup_empty_statuses; cleanup' EXIT

(cd "$TMP_REPO_MIGRATION" && git init -q)
mkdir -p "$TMP_REPO_MIGRATION/.backlog"

# テンプレートの最後のキー（auto_merge_reviewed、コメント込み）が丸ごと欠けた
# 「旧バージョンの config.my.yml」を、テンプレートの先頭から max_redispatch の
# 値行までを切り出して作る。
migration_config="$TMP_REPO_MIGRATION/.backlog/config.my.yml"
max_redispatch_line="$(grep -n '^  max_redispatch:' "$SOURCE_CONFIG" | head -1 | cut -d: -f1)"
head -n "$max_redispatch_line" "$SOURCE_CONFIG" > "$migration_config"

if grep -q '^  auto_merge_reviewed:' "$migration_config"; then
  fail "テスト前提が壊れている: auto_merge_reviewed の除去に失敗した"
fi

# 既存キー（max_in_review）をユーザーが値・コメント付きで変更した状態を作る
# （AC#2 検証用）。sed -i は使わず、他の箇所と同じ mktemp+mv で書き換える。
migration_config_tmp="$(mktemp)"
sed 's/^  max_in_review: 3$/  max_in_review: 99  # ユーザーが変更した値/' \
  "$migration_config" > "$migration_config_tmp"
mv "$migration_config_tmp" "$migration_config"

# テンプレートに無いユーザー独自のキーを追記する（AC#3 検証用）。
printf '\n  # ユーザー独自の調整値。テンプレートには存在しない。\n  my_custom_key: "keep-me"\n' >> "$migration_config"

migration_output="$("$SETUP_SCRIPT" "$TMP_REPO_MIGRATION" 2>&1)"
migration_exit=$?
if [ "$migration_exit" -eq 0 ]; then
  pass "欠けたキーを持つ config.my.yml に対する setup-improvement-loop 実行が成功する（exit 0）"
else
  fail "欠けたキーを持つ config.my.yml に対する setup-improvement-loop 実行が失敗した（exit ${migration_exit}）:
$migration_output"
fi

# AC#1: 欠けていた auto_merge_reviewed が、テンプレート側の値・コメント付きで補われる
if grep -Fq '  auto_merge_reviewed: false' "$migration_config"; then
  pass "欠けていたキー auto_merge_reviewed がテンプレートの既定値付きで補われた"
else
  fail "欠けていたキー auto_merge_reviewed が補われなかった"
fi
if grep -Fq '  # Reviewed になったタスクを orchestrator が main に自動マージするかどうか。' "$migration_config"; then
  pass "補われた auto_merge_reviewed にテンプレート側のコメントが付いている"
else
  fail "補われた auto_merge_reviewed にテンプレート側のコメントが付いていない"
fi

# AC#2: 既にあったキー（ユーザーが値・コメントを変更した max_in_review）が変更されない
if grep -Fq '  max_in_review: 99  # ユーザーが変更した値' "$migration_config"; then
  pass "再実行後も既存キー max_in_review の値・コメントが変更されない"
else
  fail "再実行で既存キー max_in_review の値・コメントが変更された"
fi

# AC#3: テンプレートに無いユーザー独自のキーが保持される
if grep -Fq '  my_custom_key: "keep-me"' "$migration_config"; then
  pass "テンプレートに無いユーザー独自のキー my_custom_key が保持される"
else
  fail "テンプレートに無いユーザー独自のキー my_custom_key が失われた"
fi

# 全キーが揃った状態で再実行しても、キーが重複追加されない（冪等性）ことを確認する。
migration_output2="$("$SETUP_SCRIPT" "$TMP_REPO_MIGRATION" 2>&1)"
migration_exit2=$?
if [ "$migration_exit2" -eq 0 ]; then
  pass "全キーが揃った後の再実行も成功する（exit 0）"
else
  fail "全キーが揃った後の再実行が失敗した（exit ${migration_exit2}）:
$migration_output2"
fi
auto_merge_count="$(grep -Fc '  auto_merge_reviewed:' "$migration_config" || true)"
if [ "$auto_merge_count" = "1" ]; then
  pass "全キーが揃った後の再実行で auto_merge_reviewed が重複追加されない"
else
  fail "全キーが揃った後の再実行で auto_merge_reviewed が重複している（${auto_merge_count} 件）"
fi

echo ""
echo "=== 7. bin/create-worktree の動作確認 ==="
# claude-skills/improvement-dispatcher/SKILL.md 手順5から切り出したワークツリー
# 作成スクリプトを、実際に一時 git リポジトリに対して実行して検証する。
# git init の既定ブランチ名は環境（init.defaultBranch）によって異なりうるため、
# main を明示して作成し、bin/create-worktree 内のデフォルトブランチ判定
# （フェッチ不可時に main へフォールバック）と整合させる。

TMP_CW_REPO="$(mktemp -d)"
# macOS では mktemp -d が返すパス（/var/...）がシンボリックリンクであり、
# bin/create-worktree 内部の pwd -P による正規化後（/private/var/...）と
# 文字列比較が一致しない。ここでも同じ正規化をしておく。
TMP_CW_REPO="$(cd "$TMP_CW_REPO" && pwd -P)"
cleanup_cw_repo() {
  rm -rf "$TMP_CW_REPO"
}
trap 'cleanup_cw_repo; cleanup_migration; cleanup_multiline_statuses; cleanup_empty_statuses; cleanup' EXIT

(cd "$TMP_CW_REPO" && git init -q -b main && git commit -q --allow-empty -m init)

CW_TASK_ID="task-77-worktree-check"
CW_EXPECTED_WORKTREE_DIR="$(dirname "$TMP_CW_REPO")/.worktree/$(basename "$TMP_CW_REPO")/$CW_TASK_ID"
CW_EXPECTED_BRANCH="improvement/$CW_TASK_ID"

cw_output1="$(cd "$TMP_CW_REPO" && "$CREATE_WORKTREE_SCRIPT" "$CW_TASK_ID" 2>&1)"
cw_exit1=$?
if [ "$cw_exit1" -eq 0 ]; then
  pass "1回目の bin/create-worktree 実行が成功する（exit 0）"
else
  fail "1回目の bin/create-worktree 実行が失敗した（exit ${cw_exit1}）:
$cw_output1"
fi

if printf '%s\n' "$cw_output1" | grep -Fxq "WORKTREE_DIR=$CW_EXPECTED_WORKTREE_DIR"; then
  pass "既定の worktree_base_dir（リポジトリの親ディレクトリの .worktree/、リポジトリ名で名前空間分け）配下に想定通りのパスが出力される"
else
  fail "WORKTREE_DIR の出力が想定と異なる。期待: WORKTREE_DIR=$CW_EXPECTED_WORKTREE_DIR, 実際の出力:
$cw_output1"
fi

if printf '%s\n' "$cw_output1" | grep -Fxq "BRANCH=$CW_EXPECTED_BRANCH"; then
  pass "BRANCH が想定通り出力される（${CW_EXPECTED_BRANCH}）"
else
  fail "BRANCH の出力が想定と異なる。期待: BRANCH=$CW_EXPECTED_BRANCH, 実際の出力:
$cw_output1"
fi

if [ -d "$CW_EXPECTED_WORKTREE_DIR" ]; then
  pass "想定したパスにワークツリーディレクトリが実在する"
else
  fail "想定したパスにワークツリーディレクトリが存在しない: $CW_EXPECTED_WORKTREE_DIR"
fi

if git -C "$TMP_CW_REPO" worktree list --porcelain | grep -Fxq "worktree $CW_EXPECTED_WORKTREE_DIR"; then
  pass "git worktree list にワークツリーが登録されている"
else
  fail "git worktree list にワークツリーが登録されていない"
fi

if grep -Fxq ".backlog" "$TMP_CW_REPO/.git/info/exclude" 2>/dev/null; then
  pass ".git/info/exclude に .backlog が追記されている"
else
  fail ".git/info/exclude に .backlog が追記されていない"
fi

# ---- 冪等性（AC#3）: 同じ task-id で2回目を実行しても、エラーにならず
# 既存のワークツリー/ブランチを再利用する ----
cw_output2="$(cd "$TMP_CW_REPO" && "$CREATE_WORKTREE_SCRIPT" "$CW_TASK_ID" 2>&1)"
cw_exit2=$?
if [ "$cw_exit2" -eq 0 ]; then
  pass "2回目の bin/create-worktree 実行（同じ task-id）が成功する（exit 0、冪等性）"
else
  fail "2回目の bin/create-worktree 実行が失敗した（exit ${cw_exit2}）:
$cw_output2"
fi

if printf '%s\n' "$cw_output2" | grep -Fxq "WORKTREE_DIR=$CW_EXPECTED_WORKTREE_DIR" && \
   printf '%s\n' "$cw_output2" | grep -Fxq "BRANCH=$CW_EXPECTED_BRANCH"; then
  pass "2回目の実行でも同じ WORKTREE_DIR/BRANCH が出力される（既存のワークツリー/ブランチを再利用）"
else
  fail "2回目の実行で WORKTREE_DIR/BRANCH の出力が変わった:
$cw_output2"
fi

cw_worktree_count="$(git -C "$TMP_CW_REPO" worktree list --porcelain | grep -Fxc "worktree $CW_EXPECTED_WORKTREE_DIR")"
if [ "$cw_worktree_count" = "1" ]; then
  pass "2回目の実行後もワークツリーが重複登録されていない"
else
  fail "2回目の実行後、ワークツリーが重複登録されている（${cw_worktree_count} 件）"
fi

cw_exclude_count="$(grep -Fxc ".backlog" "$TMP_CW_REPO/.git/info/exclude" 2>/dev/null || true)"
if [ "$cw_exclude_count" = "1" ]; then
  pass "2回目の実行後も .git/info/exclude の .backlog 行が重複していない"
else
  fail "2回目の実行後、.git/info/exclude の .backlog 行が重複している（${cw_exclude_count} 件）"
fi

# ---- 復旧シナリオ: ワークツリーのディレクトリだけ消え、ブランチは残っている
# 場合、新規作成せず既存ブランチを割り当てて再作成する ----
rm -rf "$CW_EXPECTED_WORKTREE_DIR"
cw_output3="$(cd "$TMP_CW_REPO" && "$CREATE_WORKTREE_SCRIPT" "$CW_TASK_ID" 2>&1)"
cw_exit3=$?
if [ "$cw_exit3" -eq 0 ] && [ -d "$CW_EXPECTED_WORKTREE_DIR" ]; then
  pass "ワークツリーのディレクトリのみ消えた状態からの再実行が成功し、既存ブランチで再作成される"
else
  fail "ワークツリーのディレクトリのみ消えた状態からの再実行が失敗した（exit ${cw_exit3}）:
$cw_output3"
fi

cw_branch_count="$(git -C "$TMP_CW_REPO" branch --list "$CW_EXPECTED_BRANCH" | wc -l | tr -d ' ')"
if [ "$cw_branch_count" = "1" ]; then
  pass "復旧後もブランチ $CW_EXPECTED_BRANCH が重複作成されていない"
else
  fail "復旧後、ブランチ $CW_EXPECTED_BRANCH が重複している（${cw_branch_count} 件）"
fi

# ---- 引数の妥当性検証 ----
if "$CREATE_WORKTREE_SCRIPT" >/dev/null 2>&1; then
  fail "引数無しで bin/create-worktree を実行してもエラーにならない"
else
  pass "引数無しで bin/create-worktree を実行するとエラーになる"
fi

if "$CREATE_WORKTREE_SCRIPT" "Invalid_Task_ID!" >/dev/null 2>&1; then
  fail "不正な形式の task-id を渡してもエラーにならない"
else
  pass "不正な形式の task-id を渡すとエラーになる"
fi

echo ""
echo "=== 8. bin/create-worktree の worktree_base_dir カスタム設定での動作確認 ==="
# TASK-13 で導入された improvement_loop.worktree_base_dir の判定ロジック
# （リポジトリ内相対パスの解決・.git/info/exclude への追記）が、
# bin/create-worktree へ切り出した後も維持されていることを確認する。

TMP_CW_BASEDIR_REPO="$(mktemp -d)"
cleanup_cw_basedir_repo() {
  rm -rf "$TMP_CW_BASEDIR_REPO"
}
trap 'cleanup_cw_basedir_repo; cleanup_cw_repo; cleanup_migration; cleanup_multiline_statuses; cleanup_empty_statuses; cleanup' EXIT

(cd "$TMP_CW_BASEDIR_REPO" && git init -q -b main && git commit -q --allow-empty -m init)
mkdir -p "$TMP_CW_BASEDIR_REPO/.backlog"
cat > "$TMP_CW_BASEDIR_REPO/.backlog/config.my.yml" <<'YAML'
improvement_loop:
  worktree_base_dir: ".worktree-custom"
YAML

CW_BASEDIR_TASK_ID="task-88-custom-basedir"
CW_BASEDIR_EXPECTED_DIR="$TMP_CW_BASEDIR_REPO/.worktree-custom/$(basename "$TMP_CW_BASEDIR_REPO")/$CW_BASEDIR_TASK_ID"

cw_basedir_output="$(cd "$TMP_CW_BASEDIR_REPO" && "$CREATE_WORKTREE_SCRIPT" "$CW_BASEDIR_TASK_ID" 2>&1)"
cw_basedir_exit=$?
if [ "$cw_basedir_exit" -eq 0 ]; then
  pass "worktree_base_dir をリポジトリ内の相対パスに設定した状態での実行が成功する（exit 0）"
else
  fail "worktree_base_dir をリポジトリ内の相対パスに設定した状態での実行が失敗した（exit ${cw_basedir_exit}）:
$cw_basedir_output"
fi

if [ -d "$CW_BASEDIR_EXPECTED_DIR" ]; then
  pass "worktree_base_dir で指定したリポジトリ内相対パス配下にワークツリーが作成される"
else
  fail "worktree_base_dir で指定したパス配下にワークツリーが作成されていない: $CW_BASEDIR_EXPECTED_DIR"
fi

if grep -Fxq ".worktree-custom" "$TMP_CW_BASEDIR_REPO/.git/info/exclude" 2>/dev/null; then
  pass "リポジトリ内を指す worktree_base_dir が .git/info/exclude に追記される"
else
  fail "worktree_base_dir（.worktree-custom）が .git/info/exclude に追記されていない"
fi

echo ""
echo "=== サマリー ==="
printf 'PASS: %d, FAIL: %d, SKIP: %d\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
