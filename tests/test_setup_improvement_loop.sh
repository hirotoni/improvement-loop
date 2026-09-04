#!/usr/bin/env bash
# bin/setup-improvement-loop（および install.zsh 経由でのシンボリックリンク起動）
# に対するテスト。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

# claude-code/skills/ の実体を単一の情報源として動的に列挙する。setup 側と同じ方式で
# 導出することで、片方だけ更新して他方が追随しない同期漏れを構造的に無くす。
shopt -s nullglob
SKILL_NAMES=()
for skill_dir in "$SOURCE_SKILLS_DIR"/*/; do
  SKILL_NAMES+=("$(basename "$skill_dir")")
done
shopt -u nullglob
if [ "${#SKILL_NAMES[@]}" -eq 0 ]; then
  printf 'FAIL: claude-code/skills 配下にスキルディレクトリが1つも無い: %s\n' "$SOURCE_SKILLS_DIR"
  exit 1
fi

# bin/setup-improvement-loop 側の定義を単一の情報源として使う。配列リテラルを複製すると、
# 片方だけ更新されてテストが実体とズレたまま緑になるため、その1行を抽出して評価する。
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

# セクション2（新規導入）とセクション3（再実行）の両方が参照する定数。どちらかの
# セクション内で組み立てると実行順序に依存するので、セクションの外で一度だけ導出する。
EXCLUDE_HEADER="# improvement-loop"
EXPECTED_EXCLUDE_LINES=(".backlog")
for name in "${SKILL_NAMES[@]}"; do
  EXPECTED_EXCLUDE_LINES+=(".claude/skills/$name")
done

# 「improvement-loop の導入が既に済んでいるリポジトリ」の .backlog/config.yml を書き出す。
# statuses に6ステータスが揃い、remote_operations が false、default_assignee も設定済みという、
# setup-improvement-loop が既に一度収束させた後の状態である。
#
# config.yml 自体を検証対象にしていないセクション（config.my.yml のマイグレーションを見る
# 6・6b・6c 系）がこれを使う。前状態を空リポジトリにすると setup が backlog init と
# backlog config set を追加で起動し、backlog CLI は1回の起動で平均 170ms かかるためである。
# 検証対象でない収束処理を毎セクション走らせる必要はない。
#
# config.yml を自前の heredoc で書くセクション（4・5・5b・7・7d）も同じ理由で
# default_assignee と remote_operations: false を与えてある。statuses の書式や旧ステータス名の
# 残存はそれぞれの検証対象なので heredoc のまま残す。8c だけは remote_operations の収束
# そのものが検証対象なので収束前の値を保っている。
# 引数: 書き出す config.yml のパス, project_name
write_settled_backlog_config() {
  local config_file="$1"
  local project_name="$2"
  mkdir -p "$(dirname "$config_file")"
  cat > "$config_file" <<YAML
project_name: "$project_name"
default_assignee: ["@improvement-loop-bot"]
default_status: "To Do"
statuses: ["Proposed", "To Do", "In Progress", "In Review", "Approved", "Done"]
labels: []
date_format: yyyy-mm-dd
max_column_width: 20
auto_open_browser: true
default_port: 6420
remote_operations: false
auto_commit: false
filesystem_only: false
bypass_git_hooks: false
check_active_branches: true
active_branch_days: 30
task_prefix: "task"
YAML
}

echo "=== 共有フィクスチャの構築 ==="
# 一時リポジトリを作って $SETUP_SCRIPT を流し直す処理が、このファイルの所要時間のほぼ
# 全部を占める。同じ前状態に対して同じ実行をするセクションが複数あるので、ここで1回だけ
# 作り、各セクションは「読む」か「cp -a で複製する」かのどちらかだけを行う。
#
# ここで作るフィクスチャは構築後に誰も書き換えない。書き換えが要るセクションは必ず自分用の
# 複製を作る。これにより、セクションの実行順序を入れ替えても、あるセクションだけを抜き出して
# 実行しても結果が変わらない。実行結果に対するアサーションは各セクションの側に置いてある。

# FIXTURE_FRESH: git リポジトリに setup-improvement-loop を初めて実行した直後の状態。
# 「新規導入」を前提に検証するセクション 2・6c-4・8a が読み取り専用で共有する。
FIXTURE_FRESH_REPO="$(mktemp -d)"
register_tmp_cleanup "$FIXTURE_FRESH_REPO"
(cd "$FIXTURE_FRESH_REPO" && git init -q)
FIXTURE_FRESH_OUTPUT="$("$SETUP_SCRIPT" "$FIXTURE_FRESH_REPO" 2>&1)"
FIXTURE_FRESH_EXIT=$?

# FIXTURE_RERUN: FIXTURE_FRESH の複製に、ユーザーによる次の2つの変更
#   - .backlog/config.my.yml への $FIXTURE_RERUN_MARKER の追記
#   - .backlog/config.yml の statuses への $FIXTURE_RERUN_CUSTOM_STATUS の追加
# を加えたうえで setup-improvement-loop を2回目に実行した状態。「導入済みリポジトリ
# への再実行」を前提に検証するセクション 3・7c・8b が読み取り専用で共有する。
# この2つのユーザー変更はフィクスチャの契約の一部であり、消費側はこれを前提にしてよい。
FIXTURE_RERUN_REPO="$(mktemp -d)"
register_tmp_cleanup "$FIXTURE_RERUN_REPO"
FIXTURE_RERUN_MARKER="# TEST-MARKER-$$-$(date +%s)"
FIXTURE_RERUN_CUSTOM_STATUS="CustomStatus-$$"
cp -a "$FIXTURE_FRESH_REPO/." "$FIXTURE_RERUN_REPO/"
printf '\n%s\n' "$FIXTURE_RERUN_MARKER" >> "$FIXTURE_RERUN_REPO/.backlog/config.my.yml"
fixture_rerun_config_tmp="$(mktemp)"
register_tmp_cleanup "$fixture_rerun_config_tmp"
sed "s/^statuses: \[\(.*\)\]\$/statuses: [\1, \"$FIXTURE_RERUN_CUSTOM_STATUS\"]/" \
  "$FIXTURE_RERUN_REPO/.backlog/config.yml" > "$fixture_rerun_config_tmp"
mv "$fixture_rerun_config_tmp" "$FIXTURE_RERUN_REPO/.backlog/config.yml"
FIXTURE_RERUN_OUTPUT="$("$SETUP_SCRIPT" "$FIXTURE_RERUN_REPO" 2>&1)"
FIXTURE_RERUN_EXIT=$?

echo "FIXTURE_FRESH / FIXTURE_RERUN を構築した（それぞれ setup-improvement-loop 1回分）"

echo ""
echo "=== 1d. REQUIRED_STATUSES と状態遷移表の正本の一致 ==="
# REQUIRED_STATUSES と、状態遷移表の正本（claude-code/skills/status-table.md）の
# 「## 状態遷移表」節に列挙されたステータス名の集合が一致することを検証する。
# 情報源が2箇所に分かれている以上、片方だけが更新されて食い違いうるためである。
STATUS_TABLE_FILE="$REPO_ROOT/claude-code/skills/status-table.md"
if [ ! -f "$STATUS_TABLE_FILE" ]; then
  fail "claude-code/skills/status-table.md が存在しない"
else
  table_statuses_raw="$(awk '
    /^## 状態遷移表/ { flag=1; next }
    /^## / { flag=0 }
    flag
  ' "$STATUS_TABLE_FILE" | grep -E '^\| `' | sed -E 's/^\| `([^`]*)`.*/\1/')"

  if [ -z "$table_statuses_raw" ]; then
    fail "claude-code/skills/status-table.md の「## 状態遷移表」節からステータス名を1件も抽出できなかった（見出しや表の書式が変わった可能性がある）"
  else
    TABLE_STATUSES=()
    while IFS= read -r line; do
      [ -n "$line" ] && TABLE_STATUSES+=("$line")
    done <<<"$table_statuses_raw"

    required_sorted="$(printf '%s\n' "${REQUIRED_STATUSES[@]}" | sort)"
    table_sorted="$(printf '%s\n' "${TABLE_STATUSES[@]}" | sort)"

    if [ "$required_sorted" = "$table_sorted" ]; then
      pass "REQUIRED_STATUSES と claude-code/skills/status-table.md の状態遷移表のステータス名一覧が一致する"
    else
      diff_out="$(diff <(printf '%s\n' "$required_sorted") <(printf '%s\n' "$table_sorted"))"
      fail "REQUIRED_STATUSES（bin/setup-improvement-loop）と claude-code/skills/status-table.md の状態遷移表のステータス名一覧が一致しない:
$diff_out"
    fi
  fi
fi

echo ""
echo "=== 2. 一時リポジトリへのセットアップ ==="

# 検証対象は共有フィクスチャ FIXTURE_FRESH（新規導入直後の状態）である。
# このセクションはフィクスチャを読むだけで、書き換えない。

if [ "$FIXTURE_FRESH_EXIT" -eq 0 ]; then
  pass "1回目の setup-improvement-loop 実行が成功する（exit 0）"
else
  fail "1回目の setup-improvement-loop 実行が失敗した（exit ${FIXTURE_FRESH_EXIT}）:
$FIXTURE_FRESH_OUTPUT"
fi

# ---- シンボリックリンクの検証 ----
for name in "${SKILL_NAMES[@]}"; do
  link_path="$FIXTURE_FRESH_REPO/.claude/skills/$name"
  expected_target="$SOURCE_SKILLS_DIR/$name"
  if [ -L "$link_path" ]; then
    resolved="$(cd "$link_path" 2>/dev/null && pwd -P)"
    expected_resolved="$(cd "$expected_target" && pwd -P)"
    if [ "$resolved" = "$expected_resolved" ]; then
      pass ".claude/skills/$name はリポジトリの claude-code/skills/$name への正しいシンボリックリンクである"
    else
      fail ".claude/skills/$name のリンク先が誤っている（${resolved} != ${expected_resolved}）"
    fi
  else
    fail ".claude/skills/$name がシンボリックリンクとして存在しない"
  fi
done

# ---- .backlog/config.yml の statuses の検証 ----
# backlog init --defaults の既定 statuses は3種のみで、Proposed / In Review / Approved が
# 無いと improvement-work が In Review へ上げた時点で Invalid status で失敗する。
assert_statuses_present "$FIXTURE_FRESH_REPO/.backlog/config.yml" "1回目実行後"

# ---- config.my.yml の検証 ----
target_config="$FIXTURE_FRESH_REPO/.backlog/config.my.yml"
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
exclude_file="$FIXTURE_FRESH_REPO/.git/info/exclude"

if [ -f "$exclude_file" ]; then
  all_present=true
  for line in "${EXPECTED_EXCLUDE_LINES[@]}"; do
    if ! grep -Fxq "$line" "$exclude_file"; then
      all_present=false
      fail ".git/info/exclude に '$line' が無い"
    fi
  done
  if [ "$all_present" = true ]; then
    pass ".git/info/exclude に期待する ${#EXPECTED_EXCLUDE_LINES[@]} 行がすべて含まれる"
  fi
else
  fail ".git/info/exclude が存在しない"
fi

# ---- .git/info/exclude の見出しコメントの検証 ----
if grep -Fxq "$EXCLUDE_HEADER" "$exclude_file" 2>/dev/null; then
  pass ".git/info/exclude に見出しコメント '$EXCLUDE_HEADER' がある"
else
  fail ".git/info/exclude に見出しコメント '$EXCLUDE_HEADER' が無い"
fi

echo ""
echo "=== 2b. install.zsh 経由でシンボリックリンクされた状態での実行 ==="
# 実際にインストールされた環境では setup-improvement-loop は常にシンボリックリンク経由で
# 起動される。BASH_SOURCE をリンク解決せずに使うと配布元ルートの算出を誤り、
# 「配布元の claude-code/skills ディレクトリが見つからない」で落ちる。一時 $HOME に対して
# install.zsh を実行し、出来たリンク経由で起動して検証する。
TMP_HOME="$(mktemp -d)"
TMP_REPO_SYMLINK="$(mktemp -d)"
register_tmp_cleanup "$TMP_HOME" "$TMP_REPO_SYMLINK"

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
      pass "シンボリックリンク経由実行でも、本物のリポジトリの claude-code/skills/ を配布元として正しく使えている"
    fi
  else
    fail "install.zsh がシンボリックリンクを作成しなかった: $INSTALLED_SYMLINK"
  fi
else
  skip "zsh が PATH に無いため、シンボリックリンク経由の実行テストを行わなかった"
fi

echo ""
echo "=== 3. 冪等性・ユーザー所有ファイル保護の検証 ==="
# 検証対象は共有フィクスチャ FIXTURE_RERUN（ユーザー変更を加えたうえで2回目を実行した
# 状態）。変更が再実行で消えないこと（既存設定の保持）と、6ステータスが揃った状態が
# 維持されること（欠けている分だけ補う冪等性）を同時に検証できる。読むだけで書き換えない。
rerun_config="$FIXTURE_RERUN_REPO/.backlog/config.my.yml"
rerun_backlog_config="$FIXTURE_RERUN_REPO/.backlog/config.yml"
rerun_exclude_file="$FIXTURE_RERUN_REPO/.git/info/exclude"

if [ "$FIXTURE_RERUN_EXIT" -eq 0 ]; then
  pass "2回目の setup-improvement-loop 実行が成功する（exit 0）"
else
  fail "2回目の setup-improvement-loop 実行が失敗した（exit ${FIXTURE_RERUN_EXIT}）:
$FIXTURE_RERUN_OUTPUT"
fi

if grep -Fxq "$FIXTURE_RERUN_MARKER" "$rerun_config" 2>/dev/null; then
  pass "再実行後も .backlog/config.my.yml へのユーザー変更が保持されている（上書きされない）"
else
  fail "再実行で .backlog/config.my.yml のユーザー変更が失われた"
fi

# ---- .backlog/config.yml の statuses の冪等性・既存設定保持の検証 ----
assert_statuses_present "$rerun_backlog_config" "2回目実行後"
if grep -m1 '^statuses:' "$rerun_backlog_config" | grep -Fq "\"$FIXTURE_RERUN_CUSTOM_STATUS\""; then
  pass "再実行後もユーザー独自の statuses（${FIXTURE_RERUN_CUSTOM_STATUS}）が保持されている"
else
  fail "再実行でユーザー独自の statuses（${FIXTURE_RERUN_CUSTOM_STATUS}）が失われた"
fi

# シンボリックリンクが再実行後も壊れていないことも確認する。
links_ok=true
for name in "${SKILL_NAMES[@]}"; do
  link_path="$FIXTURE_RERUN_REPO/.claude/skills/$name"
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
for line in "${EXPECTED_EXCLUDE_LINES[@]}"; do
  count="$(grep -Fxc "$line" "$rerun_exclude_file" 2>/dev/null || true)"
  if [ "$count" != "1" ]; then
    no_dup=false
    fail "再実行後、.git/info/exclude の '$line' が重複している（$count 行）"
  fi
done
if [ "$no_dup" = true ]; then
  pass ".git/info/exclude に重複行が無い（再実行後も各行1回）"
fi

# 見出しコメントも再実行で重複して増えないことを確認する。
header_count="$(grep -Fxc "$EXCLUDE_HEADER" "$rerun_exclude_file" 2>/dev/null || true)"
if [ "$header_count" = "1" ]; then
  pass "再実行後も .git/info/exclude の見出しコメント '$EXCLUDE_HEADER' が重複していない"
else
  fail "再実行後、.git/info/exclude の見出しコメント '$EXCLUDE_HEADER' が重複している（${header_count} 行）"
fi

echo ""
echo "=== 4. statuses: [] (空配列) に対する回帰テスト ==="
# macOS 既定の bash 3.2 は set -u 下で空配列を "${arr[@]}" と展開すると unbound variable で
# 落ちる。statuses が空配列（ユーザーが手動で `statuses: []` にした場合）でも
# setup-improvement-loop がクラッシュしないことを確認する。

TMP_REPO_EMPTY_STATUSES="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_EMPTY_STATUSES"

(cd "$TMP_REPO_EMPTY_STATUSES" && git init -q)
mkdir -p "$TMP_REPO_EMPTY_STATUSES/.backlog"
cat > "$TMP_REPO_EMPTY_STATUSES/.backlog/config.yml" <<'YAML'
project_name: "empty-statuses-test"
default_assignee: ["@improvement-loop-bot"]
default_status: "To Do"
statuses: []
labels: []
date_format: yyyy-mm-dd
max_column_width: 20
auto_open_browser: true
default_port: 6420
remote_operations: false
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
# statuses を複数行YAMLリスト形式で手動編集するケースは想定されている（各 SKILL.md の
# 手順が config.yml の statuses への直接編集を案内している）。この形式で
# setup-improvement-loop を（再）実行しても、置換し損ねた "  - ..." 行が残るような
# 壊れた YAML を生成しないことを確認する。

TMP_REPO_MULTILINE_STATUSES="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_MULTILINE_STATUSES"

(cd "$TMP_REPO_MULTILINE_STATUSES" && git init -q)
mkdir -p "$TMP_REPO_MULTILINE_STATUSES/.backlog"
cat > "$TMP_REPO_MULTILINE_STATUSES/.backlog/config.yml" <<'YAML'
project_name: "multiline-statuses-test"
default_assignee: ["@improvement-loop-bot"]
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
remote_operations: false
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
echo "=== 5b. statuses のシングルクォート形式に対する回帰テスト（TASK-62） ==="
# 引用符除去がダブルクォートしか剥がさないと、有効な YAML であるシングルクォートで
# statuses を書いた場合に既存要素が空扱いになったり、引用符付きのまま残って
# REQUIRED_STATUSES と文字列一致せず重複挿入されたりする。その回帰テストである。

# 与えた config.yml の statuses に、REQUIRED_STATUSES の各要素が「ちょうど1回」
# ダブルクォート付きで含まれること（重複挿入されていないこと）を検証する。
assert_no_duplicate_status_insertion() {
  local config_file="$1"
  local label="$2"
  local status_line
  status_line="$(grep -m1 '^statuses:' "$config_file" || true)"
  local status count dup_found=0
  for status in "${REQUIRED_STATUSES[@]}"; do
    count="$(grep -o "\"${status}\"" <<<"$status_line" | wc -l | tr -d '[:space:]')"
    if [ "$count" -ne 1 ]; then
      fail "$label: '${status}' の出現回数が1ではない（${count}回）: $status_line"
      dup_found=1
    fi
  done
  if [ "$dup_found" -eq 0 ]; then
    pass "$label: REQUIRED_STATUSES の各要素がちょうど1回だけ含まれる（重複挿入されていない）"
  fi
}

echo ""
echo "--- 5b-1. statuses をシングルクォートのインライン配列で書いた場合（AC#3） ---"
TMP_REPO_SINGLEQUOTE_INLINE="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_SINGLEQUOTE_INLINE"

(cd "$TMP_REPO_SINGLEQUOTE_INLINE" && git init -q)
mkdir -p "$TMP_REPO_SINGLEQUOTE_INLINE/.backlog"
cat > "$TMP_REPO_SINGLEQUOTE_INLINE/.backlog/config.yml" <<'YAML'
project_name: "singlequote-inline-test"
default_assignee: ["@improvement-loop-bot"]
default_status: "To Do"
statuses: ['Proposed', 'To Do', 'Done']
labels: []
date_format: yyyy-mm-dd
max_column_width: 20
auto_open_browser: true
default_port: 6420
remote_operations: false
auto_commit: false
filesystem_only: false
bypass_git_hooks: false
check_active_branches: true
active_branch_days: 30
task_prefix: "task"
YAML

singlequote_inline_output="$("$SETUP_SCRIPT" "$TMP_REPO_SINGLEQUOTE_INLINE" 2>&1)"
singlequote_inline_exit=$?
if [ "$singlequote_inline_exit" -eq 0 ]; then
  pass "statuses がシングルクォートのインライン配列な config.yml に対しても setup-improvement-loop が成功する（exit 0）"
else
  fail "statuses がシングルクォートのインライン配列な config.yml で setup-improvement-loop が失敗した（exit ${singlequote_inline_exit}）:
$singlequote_inline_output"
fi

singlequote_inline_config="$TMP_REPO_SINGLEQUOTE_INLINE/.backlog/config.yml"
assert_statuses_present "$singlequote_inline_config" "シングルクォートのインライン配列からの補完後（AC#3: 空扱いになっていない）"
assert_no_duplicate_status_insertion "$singlequote_inline_config" "シングルクォートのインライン配列からの補完後（AC#3）"

echo ""
echo "--- 5b-2. statuses をシングルクォートの複数行YAMLリストで書いた場合（AC#1） ---"
TMP_REPO_SINGLEQUOTE_MULTILINE="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_SINGLEQUOTE_MULTILINE"

(cd "$TMP_REPO_SINGLEQUOTE_MULTILINE" && git init -q)
mkdir -p "$TMP_REPO_SINGLEQUOTE_MULTILINE/.backlog"
cat > "$TMP_REPO_SINGLEQUOTE_MULTILINE/.backlog/config.yml" <<'YAML'
project_name: "singlequote-multiline-test"
default_assignee: ["@improvement-loop-bot"]
default_status: "To Do"
statuses:
  - 'Proposed'
  - 'To Do'
  - 'Done'
labels: []
date_format: yyyy-mm-dd
max_column_width: 20
auto_open_browser: true
default_port: 6420
remote_operations: false
auto_commit: false
filesystem_only: false
bypass_git_hooks: false
check_active_branches: true
active_branch_days: 30
task_prefix: "task"
YAML

singlequote_multiline_output="$("$SETUP_SCRIPT" "$TMP_REPO_SINGLEQUOTE_MULTILINE" 2>&1)"
singlequote_multiline_exit=$?
if [ "$singlequote_multiline_exit" -eq 0 ]; then
  pass "statuses がシングルクォートの複数行YAMLリストな config.yml に対しても setup-improvement-loop が成功する（exit 0）"
else
  fail "statuses がシングルクォートの複数行YAMLリストな config.yml で setup-improvement-loop が失敗した（exit ${singlequote_multiline_exit}）:
$singlequote_multiline_output"
fi

singlequote_multiline_config="$TMP_REPO_SINGLEQUOTE_MULTILINE/.backlog/config.yml"
assert_statuses_present "$singlequote_multiline_config" "シングルクォートの複数行YAMLリストからの補完後（AC#1: 要素に引用符が残ったまま比較されていない）"
assert_no_duplicate_status_insertion "$singlequote_multiline_config" "シングルクォートの複数行YAMLリストからの補完後（AC#1）"

if grep -m1 '^statuses:' "$singlequote_multiline_config" | grep -Fq "'"; then
  fail "5b-2: 補完後の statuses 行にシングルクォートの文字が残っている（引用符が剥がれていない）: $(grep -m1 '^statuses:' "$singlequote_multiline_config")"
else
  pass "5b-2: 補完後の statuses 行にシングルクォートの文字が残っていない（正しく引用符除去された）"
fi

echo ""
echo "=== 6. config.my.yml の不足キー補完（マイグレーション）の回帰テスト ==="
# テンプレートに新しいキーが追加された状況を「導入先の config.my.yml に一部キーが
# 欠けている」状態として再現する。欠けているキーだけがテンプレート側のコメント・既定値
# 付きで補われ、既存のキーの値・コメントとユーザー独自のキーは残ることを確認する。

TMP_REPO_MIGRATION="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_MIGRATION"

(cd "$TMP_REPO_MIGRATION" && git init -q)
mkdir -p "$TMP_REPO_MIGRATION/.backlog"
# 収束済みの config.yml を先に置き、backlog init と backlog config set を走らせない
# （このセクションが見るのは config.my.yml だけである）。
write_settled_backlog_config "$TMP_REPO_MIGRATION/.backlog/config.yml" "migration-test"

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
register_tmp_cleanup "$migration_config_tmp"
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
if grep -Fq '  # Approved になったタスクを dispatch が main に自動マージするかどうか。' "$migration_config"; then
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
echo "=== 6b. コメントアウトされたキーの誤認・重複追記の回帰テスト（TASK-37） ==="
# 既存キーの検出が "^  key:" だけだと、ユーザーが一時的に無効化する目的で行頭に "#" を
# 付けたキー（例: "  # max_in_review: 3"）を「未設定」と誤認し、有効な形で再追記して
# しまう（同名キーが2箇所に重複する）。コメントアウトされたキーは意図的な無効化として
# 扱い、重複追記されないことを検証する。

TMP_REPO_COMMENTED="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_COMMENTED"

(cd "$TMP_REPO_COMMENTED" && git init -q)
mkdir -p "$TMP_REPO_COMMENTED/.backlog"
# 収束済みの config.yml を先に置き、backlog init と backlog config set を走らせない
# （このセクションが見るのは config.my.yml だけである）。
write_settled_backlog_config "$TMP_REPO_COMMENTED/.backlog/config.yml" "commented-key-test"

commented_config="$TMP_REPO_COMMENTED/.backlog/config.my.yml"
cp "$SOURCE_CONFIG" "$commented_config"

# 既存キー max_in_review を、ユーザーが一時的に無効化した想定でコメントアウトする。
commented_config_tmp="$(mktemp)"
register_tmp_cleanup "$commented_config_tmp"
sed -E 's/^(  )max_in_review: 3$/\1# max_in_review: 3/' "$commented_config" > "$commented_config_tmp"
mv "$commented_config_tmp" "$commented_config"

if ! grep -Fq '  # max_in_review: 3' "$commented_config"; then
  fail "テスト前提が壊れている: max_in_review のコメントアウトに失敗した"
fi

commented_output="$("$SETUP_SCRIPT" "$TMP_REPO_COMMENTED" 2>&1)"
commented_exit=$?
if [ "$commented_exit" -eq 0 ]; then
  pass "コメントアウトされたキーを含む config.my.yml に対する setup-improvement-loop 実行が成功する（exit 0）"
else
  fail "コメントアウトされたキーを含む config.my.yml に対する setup-improvement-loop 実行が失敗した（exit ${commented_exit}）:
$commented_output"
fi

# AC#1: コメントアウトされたキーが有効な形で重複追記されない
commented_active_count="$(grep -Ec '^  max_in_review:' "$commented_config" || true)"
if [ "$commented_active_count" = "0" ]; then
  pass "コメントアウトされたキー max_in_review が有効な形で重複追記されない"
else
  fail "コメントアウトされたキー max_in_review が有効な形で重複追記された（${commented_active_count} 件）:
$(grep -n 'max_in_review' "$commented_config")"
fi

if grep -Fq '  # max_in_review: 3' "$commented_config"; then
  pass "コメントアウトされた max_in_review の行がそのまま保持されている"
else
  fail "コメントアウトされた max_in_review の行が変更・消失した"
fi

# 再実行しても結果が変わらない（冪等性）ことを確認する。
commented_output2="$("$SETUP_SCRIPT" "$TMP_REPO_COMMENTED" 2>&1)"
commented_exit2=$?
if [ "$commented_exit2" -eq 0 ]; then
  pass "コメントアウトされたキーを含む config.my.yml への再実行も成功する（exit 0）"
else
  fail "コメントアウトされたキーを含む config.my.yml への再実行が失敗した（exit ${commented_exit2}）:
$commented_output2"
fi
commented_active_count2="$(grep -Ec '^  max_in_review:' "$commented_config" || true)"
if [ "$commented_active_count2" = "0" ]; then
  pass "再実行後もコメントアウトされたキー max_in_review が有効な形で重複追記されない"
else
  fail "再実行後にコメントアウトされたキー max_in_review が有効な形で重複追記された（${commented_active_count2} 件）"
fi

echo ""
echo "=== 6c. 既存キーの説明コメントがテンプレートから取り残された場合の検出（TASK-74） ==="
# ensure_config_my_yml_keys が補うのは「導入先に無いキー」だけなので、既にあるキーの
# 説明コメントは再実行しても更新されず、テンプレート側の重要な訂正が既存の導入先に届かない。
# ユーザー所有ファイルを壊さないことを優先して機械的な差し替えはせず、差異があることと
# テンプレート側の最新の説明を利用者に示すにとどめる。ここではその報告が出ること、および
# 報告のためにファイルを一切書き換えないことを検証する。

TMP_REPO_COMMENT_DRIFT="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_COMMENT_DRIFT"

(cd "$TMP_REPO_COMMENT_DRIFT" && git init -q)
mkdir -p "$TMP_REPO_COMMENT_DRIFT/.backlog"
# 収束済みの config.yml を先に置き、backlog init と backlog config set を走らせない
# （このセクションが見るのは config.my.yml だけである）。
write_settled_backlog_config "$TMP_REPO_COMMENT_DRIFT/.backlog/config.yml" "comment-drift-test"

drift_config="$TMP_REPO_COMMENT_DRIFT/.backlog/config.my.yml"
cp "$SOURCE_CONFIG" "$drift_config"

# 「古いテンプレートで導入されたリポジトリ」を再現する。テンプレートの文面に依存しないよう、
# forbidden_paths のキー行の直前にある連続コメント行（＝そのキーの説明ブロック）の
# 先頭行だけを旧文言に差し替える。他のキー・値・ユーザー独自の記述には触れない。
drift_config_tmp="$(mktemp)"
register_tmp_cleanup "$drift_config_tmp"
awk '
  { lines[NR] = $0 }
  END {
    keyline = 0
    for (i = 1; i <= NR; i++) {
      if (lines[i] ~ /^  forbidden_paths:/) { keyline = i; break }
    }
    if (keyline == 0) { exit 1 }
    start = keyline
    for (i = keyline - 1; i >= 1; i--) {
      if (lines[i] ~ /^  #/) { start = i } else { break }
    }
    lines[start] = "  # これはAIエージェントへの指示にとどまり、変更を機械的に拒否・検知する仕組みではない。"
    for (i = 1; i <= NR; i++) { print lines[i] }
  }
' "$drift_config" > "$drift_config_tmp"
mv "$drift_config_tmp" "$drift_config"

if ! grep -Fq '  # これはAIエージェントへの指示にとどまり、変更を機械的に拒否・検知する仕組みではない。' "$drift_config"; then
  fail "テスト前提が壊れている: forbidden_paths の説明コメントを旧文言に差し替えられなかった"
fi

# テンプレート側の説明ブロックの先頭行（＝導入先では旧文言に置き換わっている行）。
# 警告出力にテンプレート側の最新の説明そのものが載ることの検証に使う。
template_first_comment_line="$(awk '
  { lines[NR] = $0 }
  END {
    keyline = 0
    for (i = 1; i <= NR; i++) {
      if (lines[i] ~ /^  forbidden_paths:/) { keyline = i; break }
    }
    if (keyline == 0) { exit 1 }
    start = keyline
    for (i = keyline - 1; i >= 1; i--) {
      if (lines[i] ~ /^  #/) { start = i } else { break }
    }
    print lines[start]
  }
' "$SOURCE_CONFIG")"

# 実行前のファイル内容を控え、実行後に1バイトも変わっていないことを確かめる。
drift_config_before="$(mktemp)"
register_tmp_cleanup "$drift_config_before"
cp "$drift_config" "$drift_config_before"

drift_output="$("$SETUP_SCRIPT" "$TMP_REPO_COMMENT_DRIFT" 2>&1)"
drift_exit=$?
if [ "$drift_exit" -eq 0 ]; then
  pass "説明コメントが古い config.my.yml に対する setup-improvement-loop 実行が成功する（exit 0）"
else
  fail "説明コメントが古い config.my.yml に対する setup-improvement-loop 実行が失敗した（exit ${drift_exit}）:
$drift_output"
fi

# AC#1: 差異があることが利用者に分かる形で報告される
if printf '%s\n' "$drift_output" | grep -Fq "[warn] .backlog/config.my.yml のキー 'forbidden_paths' の説明コメントが配布元テンプレートと異なる。"; then
  pass "説明コメントがテンプレートと異なるキー forbidden_paths が [warn] として報告される"
else
  fail "説明コメントがテンプレートと異なるキー forbidden_paths が報告されない:
$drift_output"
fi
if printf '%s\n' "$drift_output" | grep -Fq "人手での確認が要る項目"; then
  pass "説明コメントの差異が最後のサマリーにも現れる"
else
  fail "説明コメントの差異がサマリーに現れない:
$drift_output"
fi
# 差異の報告だけでなく、テンプレート側の最新の説明そのものが出力に載ること
# （キー名だけでは「何がどう変わったか」が利用者に届かないため）。
if printf '%s\n' "$drift_output" | grep -Fq "$template_first_comment_line"; then
  pass "テンプレート側の最新の説明そのものが警告に出力される"
else
  fail "テンプレート側の最新の説明が警告に出力されない（期待した行: ${template_first_comment_line}）:
$drift_output"
fi
# 差異が無いキーまで報告しない（過剰報告の回避）
if printf '%s\n' "$drift_output" | grep -Fq "キー 'allowed_paths' の説明コメントが"; then
  fail "テンプレートと一致している allowed_paths まで差異として報告された:
$drift_output"
else
  pass "テンプレートと一致しているキー allowed_paths は報告されない"
fi

# AC#2: 報告のためにユーザー所有ファイルを1バイトも書き換えない
if cmp -s "$drift_config_before" "$drift_config"; then
  pass "説明コメントの差異を報告しても config.my.yml は一切書き換えられない"
else
  fail "説明コメントの差異の報告で config.my.yml が書き換えられた:
$(diff "$drift_config_before" "$drift_config" || true)"
fi
rm -f "$drift_config_before"

echo ""
echo "--- 6c-2. ユーザーが変更した値・独自キー・コメントアウトしたキーは壊れない（TASK-74 AC#2） ---"
# 説明コメントの差異検出があっても、既存の3つの保護（値の保持・独自キーの保持・
# コメントアウトされたキーを有効化しない）が崩れないことを、全部を同居させて確認する。

TMP_REPO_DRIFT_USEREDIT="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_DRIFT_USEREDIT"

(cd "$TMP_REPO_DRIFT_USEREDIT" && git init -q)
mkdir -p "$TMP_REPO_DRIFT_USEREDIT/.backlog"
# 収束済みの config.yml を先に置き、backlog init と backlog config set を走らせない
# （このセクションが見るのは config.my.yml だけである）。
write_settled_backlog_config "$TMP_REPO_DRIFT_USEREDIT/.backlog/config.yml" "drift-useredit-test"

useredit_config="$TMP_REPO_DRIFT_USEREDIT/.backlog/config.my.yml"
cp "$drift_config" "$useredit_config"

useredit_config_tmp="$(mktemp)"
register_tmp_cleanup "$useredit_config_tmp"
sed -E \
  -e 's/^  max_in_review: 3$/  max_in_review: 99  # ユーザーが変更した値/' \
  -e 's/^  max_in_progress: 1$/  # max_in_progress: 1/' \
  "$useredit_config" > "$useredit_config_tmp"
mv "$useredit_config_tmp" "$useredit_config"
printf '\n  # ユーザー独自の調整値。テンプレートには存在しない。\n  my_custom_key: "keep-me"\n' >> "$useredit_config"

if ! grep -Fq '  max_in_review: 99  # ユーザーが変更した値' "$useredit_config" \
  || ! grep -Fq '  # max_in_progress: 1' "$useredit_config"; then
  fail "テスト前提が壊れている: ユーザー変更・コメントアウトの再現に失敗した"
fi

useredit_output="$("$SETUP_SCRIPT" "$TMP_REPO_DRIFT_USEREDIT" 2>&1)"
useredit_exit=$?
if [ "$useredit_exit" -eq 0 ]; then
  pass "ユーザー変更を含む config.my.yml に対する setup-improvement-loop 実行が成功する（exit 0）"
else
  fail "ユーザー変更を含む config.my.yml に対する setup-improvement-loop 実行が失敗した（exit ${useredit_exit}）:
$useredit_output"
fi
if grep -Fq '  max_in_review: 99  # ユーザーが変更した値' "$useredit_config"; then
  pass "説明コメントの差異検出を経てもユーザーが変更した値・行末コメントが保たれる"
else
  fail "説明コメントの差異検出でユーザーが変更した値・行末コメントが失われた"
fi
if grep -Fq '  my_custom_key: "keep-me"' "$useredit_config"; then
  pass "説明コメントの差異検出を経てもテンプレートに無い独自キーが保たれる"
else
  fail "説明コメントの差異検出でテンプレートに無い独自キーが失われた"
fi
useredit_active_count="$(grep -Ec '^  max_in_progress:' "$useredit_config" || true)"
if [ "$useredit_active_count" = "0" ] && grep -Fq '  # max_in_progress: 1' "$useredit_config"; then
  pass "説明コメントの差異検出を経てもコメントアウトされたキーが有効化・重複追記されない"
else
  fail "説明コメントの差異検出でコメントアウトされたキー max_in_progress が有効化された（${useredit_active_count} 件）"
fi
# コメントアウトされたキーは有効なキー行として存在しないため、差異検出の対象外である
# （この限界は warn_config_my_yml_comment_drift のコメントに明記されている）。
if printf '%s\n' "$useredit_output" | grep -Fq "キー 'max_in_progress' の説明コメントが"; then
  fail "コメントアウトされたキー max_in_progress が差異検出の対象になった:
$useredit_output"
else
  pass "コメントアウトされたキー max_in_progress は差異検出の対象にならない"
fi

echo ""
echo "--- 6c-3. テンプレートと一致していれば警告は出ない（TASK-74 AC#1 の裏側） ---"
TMP_REPO_NO_DRIFT="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_NO_DRIFT"

(cd "$TMP_REPO_NO_DRIFT" && git init -q)
mkdir -p "$TMP_REPO_NO_DRIFT/.backlog"
# 収束済みの config.yml を先に置き、backlog init と backlog config set を走らせない
# （このセクションが見るのは config.my.yml だけである）。
write_settled_backlog_config "$TMP_REPO_NO_DRIFT/.backlog/config.yml" "no-drift-test"
cp "$SOURCE_CONFIG" "$TMP_REPO_NO_DRIFT/.backlog/config.my.yml"

no_drift_output="$("$SETUP_SCRIPT" "$TMP_REPO_NO_DRIFT" 2>&1)"
no_drift_exit=$?
if [ "$no_drift_exit" -eq 0 ]; then
  pass "テンプレートと同一の config.my.yml に対する実行が成功する（exit 0）"
else
  fail "テンプレートと同一の config.my.yml に対する実行が失敗した（exit ${no_drift_exit}）:
$no_drift_output"
fi
if printf '%s\n' "$no_drift_output" | grep -Fq "説明コメントが配布元テンプレートと異なる"; then
  fail "テンプレートと同一なのに説明コメントの差異が報告された:
$no_drift_output"
else
  pass "テンプレートと同一なら説明コメントの差異は報告されない"
fi
if printf '%s\n' "$no_drift_output" | grep -Fq "人手での確認が要る項目"; then
  fail "警告が無いのにサマリーへ「人手での確認が要る項目」の節が出力された:
$no_drift_output"
else
  pass "警告が無ければサマリーの出力は従来どおり（余分な節を出さない）"
fi

echo ""
echo "--- 6c-4. 新規導入（config.my.yml が無い状態）は従来どおりテンプレートのコピー（TASK-74 AC#3） ---"
# 「config.my.yml が無い git リポジトリへの1回目の実行」は FIXTURE_FRESH がまさに
# その状態なので、専用の一時リポジトリを作らず読み取りで共有する。
if [ "$FIXTURE_FRESH_EXIT" -eq 0 ]; then
  pass "config.my.yml が無い新規導入の実行が成功する（exit 0）"
else
  fail "config.my.yml が無い新規導入の実行が失敗した（exit ${FIXTURE_FRESH_EXIT}）:
$FIXTURE_FRESH_OUTPUT"
fi
if cmp -s "$SOURCE_CONFIG" "$FIXTURE_FRESH_REPO/.backlog/config.my.yml"; then
  pass "新規導入の config.my.yml はテンプレートと完全に一致する"
else
  fail "新規導入の config.my.yml がテンプレートと一致しない"
fi
if printf '%s\n' "$FIXTURE_FRESH_OUTPUT" | grep -Fq "説明コメントが配布元テンプレートと異なる"; then
  fail "新規導入で説明コメントの差異が報告された（差異検出は既存ファイルがある場合だけ動くべき）:
$FIXTURE_FRESH_OUTPUT"
else
  pass "新規導入では説明コメントの差異検出が動かない"
fi

echo ""
echo "=== 7. 旧ステータス名 Reviewed が残る既存 consumer リポジトリの移行（TASK-48） ==="
# 旧ステータス名 Reviewed が残ったままの既存 consumer リポジトリ（statuses に Reviewed と
# Approved が両方あり、status: Reviewed の既存タスクもある状態）を一時ディレクトリで模擬し、
# (a) statuses の重複が解消され Reviewed が消えること、(b) 既存タスクが Approved へ
# 移行されることを検証する。実際の consumer リポジトリへは書き込まない。

TMP_REPO_REVIEWED_MIGRATION="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_REVIEWED_MIGRATION"

(cd "$TMP_REPO_REVIEWED_MIGRATION" && git init -q)
mkdir -p "$TMP_REPO_REVIEWED_MIGRATION/.backlog"

# 実機で確認された statuses の並びをそのまま模擬する。
cat > "$TMP_REPO_REVIEWED_MIGRATION/.backlog/config.yml" <<'YAML'
project_name: "reviewed-migration-test"
default_assignee: ["@improvement-loop-bot"]
default_status: "To Do"
statuses: ["Proposed", "To Do", "In Progress", "In Review", "Reviewed", "Approved", "Done"]
labels: []
date_format: yyyy-mm-dd
max_column_width: 20
auto_open_browser: true
default_port: 6420
remote_operations: false
auto_commit: false
filesystem_only: false
bypass_git_hooks: false
check_active_branches: true
active_branch_days: 30
task_prefix: "task"
YAML

# status: Reviewed の既存タスク（TASK-1）と、影響を受けてはいけない別ステータスのタスク
# （TASK-2、To Do のまま）を backlog CLI 経由で用意する。TASK-1 のタイトルにわざと
# "TASK-999"（存在しないタスクID）を含める。ID 抽出が行のどこにでも現れる
# "TASK-[0-9]+" を素朴に拾うと、これを別タスクの ID と誤検出して失敗する。
(cd "$TMP_REPO_REVIEWED_MIGRATION" && backlog task create "reviewed task fix TASK-999 regression" --plain >/dev/null)
(cd "$TMP_REPO_REVIEWED_MIGRATION" && backlog task edit TASK-1 -s "Reviewed" --plain >/dev/null)
(cd "$TMP_REPO_REVIEWED_MIGRATION" && backlog task create "still todo task" --plain >/dev/null)

reviewed_task_file="$(find "$TMP_REPO_REVIEWED_MIGRATION/.backlog/tasks" -name 'task-1 - *.md')"
todo_task_file="$(find "$TMP_REPO_REVIEWED_MIGRATION/.backlog/tasks" -name 'task-2 - *.md')"

if [ -z "$reviewed_task_file" ] || ! grep -Fxq 'status: Reviewed' "$reviewed_task_file"; then
  fail "テスト前提が壊れている: TASK-1 を status: Reviewed にできなかった"
fi

# 移行前の状態をログに残す（模擬環境での before）。
echo "--- 移行前（before） ---"
echo "config.yml statuses: $(grep -m1 '^statuses:' "$TMP_REPO_REVIEWED_MIGRATION/.backlog/config.yml")"
echo "TASK-1 status: $(grep -m1 '^status:' "$reviewed_task_file")"
echo "TASK-2 status: $(grep -m1 '^status:' "$todo_task_file")"

reviewed_migration_output="$("$SETUP_SCRIPT" "$TMP_REPO_REVIEWED_MIGRATION" 2>&1)"
reviewed_migration_exit=$?
if [ "$reviewed_migration_exit" -eq 0 ]; then
  pass "Reviewed が残る一時リポジトリに対する setup-improvement-loop 実行が成功する（exit 0）"
else
  fail "Reviewed が残る一時リポジトリに対する setup-improvement-loop 実行が失敗した（exit ${reviewed_migration_exit}）:
$reviewed_migration_output"
fi

# 移行後の状態をログに残す（模擬環境での after）。
echo "--- 移行後（after） ---"
echo "config.yml statuses: $(grep -m1 '^statuses:' "$TMP_REPO_REVIEWED_MIGRATION/.backlog/config.yml")"
echo "TASK-1 status: $(grep -m1 '^status:' "$reviewed_task_file")"
echo "TASK-2 status: $(grep -m1 '^status:' "$todo_task_file")"

# ---- statuses から旧名 Reviewed が消え、Approved の重複が解消される ----
result_status_line="$(grep -m1 '^statuses:' "$TMP_REPO_REVIEWED_MIGRATION/.backlog/config.yml")"
if ! grep -Fq '"Reviewed"' <<<"$result_status_line"; then
  pass "AC#1: statuses から旧名 'Reviewed' が除去された"
else
  fail "AC#1: statuses に旧名 'Reviewed' が残っている: $result_status_line"
fi
approved_count="$(grep -o '"Approved"' <<<"$result_status_line" | wc -l | tr -d ' ')"
if [ "$approved_count" = "1" ]; then
  pass "AC#1: statuses に 'Approved' がちょうど1つだけ残る（重複していない）"
else
  fail "AC#1: statuses の 'Approved' の件数が想定と異なる（${approved_count} 件）: $result_status_line"
fi

# ---- status: Reviewed だった既存タスクが Approved へ移行される ----
if grep -Fxq 'status: Approved' "$reviewed_task_file"; then
  pass "AC#2: status: Reviewed だった TASK-1 が Approved へ移行された"
else
  fail "AC#2: TASK-1 が Approved へ移行されなかった: $(grep -m1 '^status:' "$reviewed_task_file")"
fi

# 影響を受けてはいけないタスク（To Do のまま）が変更されていないことも確認する。
if grep -Fxq 'status: To Do' "$todo_task_file"; then
  pass "移行対象外のタスク（To Do）が変更されずに保持されている"
else
  fail "移行対象外のタスク（To Do）の status が意図せず変更された: $(grep -m1 '^status:' "$todo_task_file")"
fi

# タイトル中の "TASK-999" が存在しないタスクIDとして誤検出・誤操作されていないことを
# 確認する。誤検出されていれば上の実行の時点で既に失敗しているはずだが、念のため
# タスクファイルが作られていないことも直接確認する。
fake_task_999_file="$(find "$TMP_REPO_REVIEWED_MIGRATION/.backlog/tasks" -name 'task-999*' 2>/dev/null)"
if [ -z "$fake_task_999_file" ]; then
  pass "タイトル中の 'TASK-999' という文字列が存在しないタスクIDとして誤検出されなかった"
else
  fail "タイトル中の 'TASK-999' が誤ってタスクIDとして扱われた形跡がある: $fake_task_999_file"
fi

echo ""
echo "=== 7b. 移行済みリポジトリへの再実行は何も変化させない（AC#3・冪等性） ==="
# 7. で移行済みになった同じリポジトリに再度実行し、何も変化しないことを確認する。

reviewed_task_status_before_rerun="$(cat "$reviewed_task_file")"
config_before_rerun="$(cat "$TMP_REPO_REVIEWED_MIGRATION/.backlog/config.yml")"

reviewed_rerun_output="$("$SETUP_SCRIPT" "$TMP_REPO_REVIEWED_MIGRATION" 2>&1)"
reviewed_rerun_exit=$?
if [ "$reviewed_rerun_exit" -eq 0 ]; then
  pass "移行済みリポジトリへの再実行が成功する（exit 0）"
else
  fail "移行済みリポジトリへの再実行が失敗した（exit ${reviewed_rerun_exit}）:
$reviewed_rerun_output"
fi

if grep -Fq "status: Reviewed の既存タスクは見つからなかった" <<<"$reviewed_rerun_output" \
  && grep -Fq "旧名 'Reviewed' は残っていない" <<<"$reviewed_rerun_output"; then
  pass "AC#3: 再実行時、Reviewed 関連の移行処理が両方ともスキップと報告される"
else
  fail "AC#3: 再実行時に期待するスキップ報告が出力されなかった:
$reviewed_rerun_output"
fi

if [ "$(cat "$reviewed_task_file")" = "$reviewed_task_status_before_rerun" ]; then
  pass "AC#3: 移行済みタスクファイルは再実行後も変化しない"
else
  fail "AC#3: 移行済みタスクファイルが再実行で変化した"
fi
if [ "$(cat "$TMP_REPO_REVIEWED_MIGRATION/.backlog/config.yml")" = "$config_before_rerun" ]; then
  pass "AC#3: config.yml は再実行後も変化しない"
else
  fail "AC#3: config.yml が再実行で変化した"
fi

echo ""
echo "=== 7c. Reviewed が元から存在しないリポジトリでは何も変化しない（AC#3） ==="
# FIXTURE_RERUN（Reviewed を一度も含んだことが無いリポジトリへの再実行）の出力を読み、
# Reviewed 関連の移行処理が両方ともスキップと報告されることを確認する。

if [ "$FIXTURE_RERUN_EXIT" -eq 0 ]; then
  pass "Reviewed が元から無いリポジトリへの実行が成功する（exit 0）"
else
  fail "Reviewed が元から無いリポジトリへの実行が失敗した（exit ${FIXTURE_RERUN_EXIT}）:
$FIXTURE_RERUN_OUTPUT"
fi
if grep -Fq "status: Reviewed の既存タスクは見つからなかった" <<<"$FIXTURE_RERUN_OUTPUT" \
  && grep -Fq "旧名 'Reviewed' は残っていない" <<<"$FIXTURE_RERUN_OUTPUT"; then
  pass "AC#3: Reviewed が元から無い場合も、両方の移行処理がスキップと報告される"
else
  fail "AC#3: Reviewed が元から無い場合に期待するスキップ報告が出力されなかった:
$FIXTURE_RERUN_OUTPUT"
fi

echo ""
echo "=== 7d. task_prefix をカスタマイズしたリポジトリでの Reviewed タスク移行（回帰テスト） ==="
# ID は config.yml の task_prefix に応じて変わる（task_prefix: "issue" なら "ISSUE-<n>"）。
# 抽出パターンを "TASK-" 固定にすると、prefix をカスタマイズしたリポジトリでは対象タスクを
# 一切検出できず、statuses からだけ "Reviewed" が消えて既存タスクが取り残される
# （再実行でも検出できないので回復しない）。その回帰テストである。

TMP_REPO_CUSTOM_PREFIX="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_CUSTOM_PREFIX"

(cd "$TMP_REPO_CUSTOM_PREFIX" && git init -q)
mkdir -p "$TMP_REPO_CUSTOM_PREFIX/.backlog"
cat > "$TMP_REPO_CUSTOM_PREFIX/.backlog/config.yml" <<'YAML'
project_name: "custom-prefix-test"
default_assignee: ["@improvement-loop-bot"]
default_status: "To Do"
statuses: ["Proposed", "To Do", "In Progress", "In Review", "Reviewed", "Approved", "Done"]
labels: []
date_format: yyyy-mm-dd
max_column_width: 20
auto_open_browser: true
default_port: 6420
remote_operations: false
auto_commit: false
filesystem_only: false
bypass_git_hooks: false
check_active_branches: true
active_branch_days: 30
task_prefix: "issue"
YAML

(cd "$TMP_REPO_CUSTOM_PREFIX" && backlog task create "custom prefix reviewed task" --plain >/dev/null)
(cd "$TMP_REPO_CUSTOM_PREFIX" && backlog task edit ISSUE-1 -s "Reviewed" --plain >/dev/null)

custom_prefix_task_file="$(find "$TMP_REPO_CUSTOM_PREFIX/.backlog/tasks" -name 'issue-1 - *.md')"
if [ -z "$custom_prefix_task_file" ] || ! grep -Fxq 'status: Reviewed' "$custom_prefix_task_file"; then
  fail "テスト前提が壊れている: ISSUE-1 を status: Reviewed にできなかった"
fi

custom_prefix_output="$("$SETUP_SCRIPT" "$TMP_REPO_CUSTOM_PREFIX" 2>&1)"
custom_prefix_exit=$?
if [ "$custom_prefix_exit" -eq 0 ]; then
  pass "task_prefix をカスタマイズしたリポジトリへの実行が成功する（exit 0）"
else
  fail "task_prefix をカスタマイズしたリポジトリへの実行が失敗した（exit ${custom_prefix_exit}）:
$custom_prefix_output"
fi

if grep -Fxq 'status: Approved' "$custom_prefix_task_file"; then
  pass "task_prefix をカスタマイズしたリポジトリでも、status: Reviewed だった ISSUE-1 が Approved へ移行された"
else
  fail "task_prefix をカスタマイズしたリポジトリで ISSUE-1 が Approved へ移行されなかった（'TASK-' 固定のID抽出パターンによる検出漏れの疑い）: $(grep -m1 '^status:' "$custom_prefix_task_file")"
fi

custom_prefix_status_line="$(grep -m1 '^statuses:' "$TMP_REPO_CUSTOM_PREFIX/.backlog/config.yml")"
if ! grep -Fq '"Reviewed"' <<<"$custom_prefix_status_line"; then
  pass "task_prefix をカスタマイズしたリポジトリでも statuses から旧名 'Reviewed' が除去された"
else
  fail "task_prefix をカスタマイズしたリポジトリで statuses に旧名 'Reviewed' が残っている: $custom_prefix_status_line"
fi

echo ""
echo "=== 8. remoteOperations / defaultAssignee の既定値収束の検証 ==="
# remoteOperations と defaultAssignee は「未設定・既定値のままの箇所だけを安全に補正し、
# 既にユーザーが設定した値は上書きしない」パターンで収束させる。

# 8a の前状態は FIXTURE_FRESH と同一なので読み取りで共有する
# （backlog config get は読み取り専用でフィクスチャを変更しない）。
if [ "$FIXTURE_FRESH_EXIT" -eq 0 ]; then
  pass "8a: 新規セットアップの実行が成功する（exit 0）"
else
  fail "8a: 新規セットアップの実行が失敗した（exit ${FIXTURE_FRESH_EXIT}）:
$FIXTURE_FRESH_OUTPUT"
fi

remote_ops_after_setup="$(cd "$FIXTURE_FRESH_REPO" && backlog config get remoteOperations 2>/dev/null)"
if [ "$remote_ops_after_setup" = "false" ]; then
  pass "8a: 新規セットアップ後、remoteOperations が false に収束する"
else
  fail "8a: 新規セットアップ後の remoteOperations が false になっていない: '$remote_ops_after_setup'"
fi

fresh_defaults_config="$FIXTURE_FRESH_REPO/.backlog/config.yml"
if grep -m1 '^default_assignee:' "$fresh_defaults_config" | grep -Fq '@improvement-loop-bot'; then
  pass "8a: 新規セットアップ後、default_assignee が @improvement-loop-bot に収束する"
else
  fail "8a: 新規セットアップ後の default_assignee が @improvement-loop-bot になっていない: $(grep -m1 '^default_assignee:' "$fresh_defaults_config")"
fi

# ---- 8b. 冪等性: 再実行しても壊れず、両方とも [skip] と報告される ----
# 前状態は FIXTURE_RERUN と同一なので読み取りで共有する。
rerun_defaults_config="$FIXTURE_RERUN_REPO/.backlog/config.yml"
if [ "$FIXTURE_RERUN_EXIT" -eq 0 ]; then
  pass "8b: remoteOperations/defaultAssignee が既に収束済みの状態への再実行が成功する（exit 0）"
else
  fail "8b: 再実行が失敗した（exit ${FIXTURE_RERUN_EXIT}）:
$FIXTURE_RERUN_OUTPUT"
fi
if grep -Fq "remoteOperations は既に false" <<<"$FIXTURE_RERUN_OUTPUT"; then
  pass "8b: 再実行時、remoteOperations の収束処理がスキップと報告される"
else
  fail "8b: 再実行時に remoteOperations のスキップ報告が出力されなかった:
$FIXTURE_RERUN_OUTPUT"
fi
if grep -Fq "default_assignee は既に設定されている" <<<"$FIXTURE_RERUN_OUTPUT"; then
  pass "8b: 再実行時、default_assignee の収束処理がスキップと報告される"
else
  fail "8b: 再実行時に default_assignee のスキップ報告が出力されなかった:
$FIXTURE_RERUN_OUTPUT"
fi
assignee_dup_count="$(grep -Ec '^default_assignee:' "$rerun_defaults_config" || true)"
if [ "$assignee_dup_count" = "1" ]; then
  pass "8b: 再実行後も default_assignee が重複追記されない"
else
  fail "8b: 再実行後、default_assignee が重複している（${assignee_dup_count} 件）"
fi

# ---- 8c. 既に remote_operations: true を明示している既存 consumer リポジトリでも false に収束すること ----
TMP_REPO_REMOTE_OPS="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_REMOTE_OPS"
(cd "$TMP_REPO_REMOTE_OPS" && git init -q)
mkdir -p "$TMP_REPO_REMOTE_OPS/.backlog"
cat > "$TMP_REPO_REMOTE_OPS/.backlog/config.yml" <<'YAML'
project_name: "remote-ops-test"
default_status: "To Do"
statuses: ["Proposed", "To Do", "In Progress", "In Review", "Approved", "Done"]
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

remote_ops_output="$("$SETUP_SCRIPT" "$TMP_REPO_REMOTE_OPS" 2>&1)"
remote_ops_exit=$?
if [ "$remote_ops_exit" -eq 0 ]; then
  pass "8c: remote_operations: true な既存 config.yml に対する実行が成功する（exit 0）"
else
  fail "8c: remote_operations: true な既存 config.yml に対する実行が失敗した（exit ${remote_ops_exit}）:
$remote_ops_output"
fi
remote_ops_result="$(cd "$TMP_REPO_REMOTE_OPS" && backlog config get remoteOperations 2>/dev/null)"
if [ "$remote_ops_result" = "false" ]; then
  pass "8c: 既存の remote_operations: true が false へ収束した"
else
  fail "8c: 既存の remote_operations: true が false へ収束しなかった: '$remote_ops_result'"
fi

# ---- 8d. defaultAssignee が既にユーザー独自の値で設定されている場合、上書きしない ----
TMP_REPO_CUSTOM_ASSIGNEE="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_CUSTOM_ASSIGNEE"
(cd "$TMP_REPO_CUSTOM_ASSIGNEE" && git init -q)
mkdir -p "$TMP_REPO_CUSTOM_ASSIGNEE/.backlog"
cat > "$TMP_REPO_CUSTOM_ASSIGNEE/.backlog/config.yml" <<'YAML'
project_name: "custom-assignee-test"
default_assignee: ["@someone-else"]
default_status: "To Do"
statuses: ["Proposed", "To Do", "In Progress", "In Review", "Approved", "Done"]
labels: []
date_format: yyyy-mm-dd
max_column_width: 20
auto_open_browser: true
default_port: 6420
remote_operations: false
auto_commit: false
filesystem_only: false
bypass_git_hooks: false
check_active_branches: true
active_branch_days: 30
task_prefix: "task"
YAML

custom_assignee_output="$("$SETUP_SCRIPT" "$TMP_REPO_CUSTOM_ASSIGNEE" 2>&1)"
custom_assignee_exit=$?
if [ "$custom_assignee_exit" -eq 0 ]; then
  pass "8d: default_assignee をユーザーが独自設定済みの config.yml に対する実行が成功する（exit 0）"
else
  fail "8d: default_assignee をユーザーが独自設定済みの config.yml に対する実行が失敗した（exit ${custom_assignee_exit}）:
$custom_assignee_output"
fi
custom_assignee_config="$TMP_REPO_CUSTOM_ASSIGNEE/.backlog/config.yml"
if grep -Fxq 'default_assignee: ["@someone-else"]' "$custom_assignee_config"; then
  pass "8d: ユーザー独自の default_assignee が上書きされずに保持される"
else
  fail "8d: ユーザー独自の default_assignee が上書きされた: $(grep -m1 '^default_assignee:' "$custom_assignee_config")"
fi
custom_assignee_count="$(grep -Ec '^default_assignee:' "$custom_assignee_config" || true)"
if [ "$custom_assignee_count" = "1" ]; then
  pass "8d: default_assignee が重複追記されない"
else
  fail "8d: default_assignee が重複している（${custom_assignee_count} 件）"
fi

echo ""
echo "=== 9. --workspace フラグの検証 ==="
# --workspace はフラグ無しの既定動作とは完全に別の経路で、git 判定をスキップし、
# claude-code/workspace-skills/ 配下のスキルだけを .claude/skills/ に配置する。
# backlog init や .backlog/ 配下の配置は一切行わない。

# WORKSPACE_SKILL_NAMES は setup 側と同じく実体を単一の情報源として動的に列挙する。
shopt -s nullglob
WORKSPACE_SKILL_NAMES=()
for skill_dir in "$SOURCE_WORKSPACE_SKILLS_DIR"/*/; do
  WORKSPACE_SKILL_NAMES+=("$(basename "$skill_dir")")
done
shopt -u nullglob
if [ "${#WORKSPACE_SKILL_NAMES[@]}" -eq 0 ]; then
  fail "claude-code/workspace-skills 配下にスキルディレクトリが1つも無い: $SOURCE_WORKSPACE_SKILLS_DIR"
fi

# ---- 9a. 対象が git リポジトリでなくても成功する ----
TMP_WORKSPACE_PLAIN="$(mktemp -d)"
register_tmp_cleanup "$TMP_WORKSPACE_PLAIN"

workspace_plain_output="$("$SETUP_SCRIPT" --workspace "$TMP_WORKSPACE_PLAIN" 2>&1)"
workspace_plain_exit=$?
if [ "$workspace_plain_exit" -eq 0 ]; then
  pass "9a: git リポジトリでない対象ディレクトリに対しても --workspace は成功する（exit 0）"
else
  fail "9a: git リポジトリでない対象ディレクトリへの --workspace 実行が失敗した（exit ${workspace_plain_exit}）:
$workspace_plain_output"
fi

# ---- claude-code/workspace-skills/ の2スキルだけが配置される ----
workspace_plain_links_ok=true
for name in "${WORKSPACE_SKILL_NAMES[@]}"; do
  link_path="$TMP_WORKSPACE_PLAIN/.claude/skills/$name"
  expected_target="$SOURCE_WORKSPACE_SKILLS_DIR/$name"
  if [ -L "$link_path" ]; then
    resolved="$(cd "$link_path" 2>/dev/null && pwd -P)"
    expected_resolved="$(cd "$expected_target" && pwd -P)"
    if [ "$resolved" != "$expected_resolved" ]; then
      workspace_plain_links_ok=false
      fail "9a: .claude/skills/$name のリンク先が誤っている（${resolved} != ${expected_resolved}）"
    fi
  else
    workspace_plain_links_ok=false
    fail "9a: .claude/skills/$name がシンボリックリンクとして存在しない"
  fi
done
if [ "$workspace_plain_links_ok" = true ]; then
  pass "9a: claude-code/workspace-skills/ 配下の全スキル（${WORKSPACE_SKILL_NAMES[*]}）が正しくシンボリックリンクされる"
fi

# 単一リポジトリ用のスキルが誤って混入していないことも確認する。
workspace_plain_no_repo_skills=true
for name in "${SKILL_NAMES[@]}"; do
  if [ -e "$TMP_WORKSPACE_PLAIN/.claude/skills/$name" ]; then
    workspace_plain_no_repo_skills=false
    fail "9a: --workspace 経路で単一リポジトリ用スキル '$name' が誤って配置された"
  fi
done
if [ "$workspace_plain_no_repo_skills" = true ]; then
  pass "9a: --workspace 経路では単一リポジトリ用の5スキルが混入しない"
fi

# 件数が厳密に一致すること（想定外の余分なエントリが無いこと）も確認する。
workspace_plain_actual_count="$(find "$TMP_WORKSPACE_PLAIN/.claude/skills" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
if [ "$workspace_plain_actual_count" = "${#WORKSPACE_SKILL_NAMES[@]}" ]; then
  pass "9a: .claude/skills/ 配下のエントリ数が claude-code/workspace-skills/ の件数（${#WORKSPACE_SKILL_NAMES[@]}）と一致する"
else
  fail "9a: .claude/skills/ 配下のエントリ数が想定と異なる（実際: ${workspace_plain_actual_count}、期待: ${#WORKSPACE_SKILL_NAMES[@]}）"
fi

# backlog init・.backlog/ 配下の配置は一切行われない
if [ -e "$TMP_WORKSPACE_PLAIN/.backlog" ]; then
  fail "9a: --workspace 経路で .backlog/ が作られてしまった（backlog init が実行された疑い）"
else
  pass "9a: --workspace 経路では .backlog/ が作られない"
fi

# git リポジトリでない対象では .git/info/exclude への追記もスキップされる（エラーにはしない）
if [ -e "$TMP_WORKSPACE_PLAIN/.git" ]; then
  fail "9a: --workspace 経路で対象に .git が作られてしまった"
else
  pass "9a: git リポジトリでない対象では .git が作られない（exclude 追記もスキップされる）"
fi

# ---- 9b. 冪等性: 再実行しても壊れず、[skip] と報告される ----
workspace_plain_rerun_output="$("$SETUP_SCRIPT" --workspace "$TMP_WORKSPACE_PLAIN" 2>&1)"
workspace_plain_rerun_exit=$?
if [ "$workspace_plain_rerun_exit" -eq 0 ]; then
  pass "9b: --workspace の再実行が成功する（exit 0）"
else
  fail "9b: --workspace の再実行が失敗した（exit ${workspace_plain_rerun_exit}）:
$workspace_plain_rerun_output"
fi
if grep -Fq "は既に正しいリンク先を指している" <<<"$workspace_plain_rerun_output"; then
  pass "9b: 再実行時、既存の正しいシンボリックリンクが [skip] と報告される"
else
  fail "9b: 再実行時に期待する [skip] 報告が出力されなかった:
$workspace_plain_rerun_output"
fi
workspace_plain_rerun_links_ok=true
for name in "${WORKSPACE_SKILL_NAMES[@]}"; do
  link_path="$TMP_WORKSPACE_PLAIN/.claude/skills/$name"
  if [ -L "$link_path" ] && [ -d "$link_path" ]; then
    : # ok
  else
    workspace_plain_rerun_links_ok=false
    fail "9b: 再実行後、.claude/skills/$name が正しいシンボリックリンクでなくなっている"
  fi
done
if [ "$workspace_plain_rerun_links_ok" = true ]; then
  pass "9b: 再実行後もすべてのシンボリックリンクが健全である"
fi

# ---- 9c. 対象パスが git リポジトリでもある場合、.git/info/exclude に追記される ----
TMP_WORKSPACE_GIT="$(mktemp -d)"
register_tmp_cleanup "$TMP_WORKSPACE_GIT"
(cd "$TMP_WORKSPACE_GIT" && git init -q)

workspace_git_output="$("$SETUP_SCRIPT" --workspace "$TMP_WORKSPACE_GIT" 2>&1)"
workspace_git_exit=$?
if [ "$workspace_git_exit" -eq 0 ]; then
  pass "9c: 対象が git リポジトリでもある場合の --workspace 実行が成功する（exit 0）"
else
  fail "9c: 対象が git リポジトリでもある場合の --workspace 実行が失敗した（exit ${workspace_git_exit}）:
$workspace_git_output"
fi

workspace_git_exclude_file="$TMP_WORKSPACE_GIT/.git/info/exclude"
if [ -f "$workspace_git_exclude_file" ]; then
  workspace_git_exclude_ok=true
  for name in "${WORKSPACE_SKILL_NAMES[@]}"; do
    if ! grep -Fxq ".claude/skills/$name" "$workspace_git_exclude_file"; then
      workspace_git_exclude_ok=false
      fail "9c: .git/info/exclude に '.claude/skills/$name' が無い"
    fi
  done
  if [ "$workspace_git_exclude_ok" = true ]; then
    pass "9c: 対象が git リポジトリでもある場合、配置したワークスペーススキルが .git/info/exclude に追記される"
  fi
  # .backlog は --workspace 経路では配置しないので、exclude にも追記されないことを確認する。
  if grep -Fxq ".backlog" "$workspace_git_exclude_file"; then
    fail "9c: --workspace 経路なのに .git/info/exclude に '.backlog' が追記されている"
  else
    pass "9c: --workspace 経路では .git/info/exclude に '.backlog' が追記されない"
  fi
else
  fail "9c: .git/info/exclude が作られなかった"
fi

# ---- 9d. 衝突検知: シンボリックリンクではない実体が既にある場合はエラーで停止する ----
TMP_WORKSPACE_COLLISION="$(mktemp -d)"
register_tmp_cleanup "$TMP_WORKSPACE_COLLISION"
collision_skill_name="${WORKSPACE_SKILL_NAMES[0]}"
mkdir -p "$TMP_WORKSPACE_COLLISION/.claude/skills/$collision_skill_name"
touch "$TMP_WORKSPACE_COLLISION/.claude/skills/$collision_skill_name/dummy-file"

collision_output="$("$SETUP_SCRIPT" --workspace "$TMP_WORKSPACE_COLLISION" 2>&1)"
collision_exit=$?
if [ "$collision_exit" -ne 0 ]; then
  pass "9d: シンボリックリンクではない実体との衝突がエラーで停止する（exit ${collision_exit}）"
else
  fail "9d: シンボリックリンクではない実体との衝突がエラーにならなかった:
$collision_output"
fi
if grep -Fq "にはシンボリックリンクではない実体が既に存在する" <<<"$collision_output"; then
  pass "9d: 衝突時のエラーメッセージが期待通り出力される"
else
  fail "9d: 衝突時に期待するエラーメッセージが出力されなかった:
$collision_output"
fi

# ---- 9e. --workspace フラグの位置は任意（位置引数の前後どちらでもよい） ----
TMP_WORKSPACE_FLAG_ORDER="$(mktemp -d)"
register_tmp_cleanup "$TMP_WORKSPACE_FLAG_ORDER"

flag_order_output="$("$SETUP_SCRIPT" "$TMP_WORKSPACE_FLAG_ORDER" --workspace 2>&1)"
flag_order_exit=$?
if [ "$flag_order_exit" -eq 0 ]; then
  pass "9e: '<パス> --workspace' の順でもフラグが正しく解釈される（exit 0）"
else
  fail "9e: '<パス> --workspace' の順での実行が失敗した（exit ${flag_order_exit}）:
$flag_order_output"
fi
if [ -e "$TMP_WORKSPACE_FLAG_ORDER/.claude/skills/${WORKSPACE_SKILL_NAMES[0]}" ]; then
  pass "9e: 位置引数がフラグより前にあっても正しい対象ディレクトリにスキルが配置される"
else
  fail "9e: 位置引数がフラグより前にある場合に、対象ディレクトリへスキルが配置されなかった"
fi

# ---- 9f. --workspace 無しの既定動作が影響を受けていないこと ----
# 対象ディレクトリが git リポジトリでなければ --workspace 無しではエラーで停止する。
TMP_NON_GIT_NO_FLAG="$(mktemp -d)"
register_tmp_cleanup "$TMP_NON_GIT_NO_FLAG"
no_flag_output="$("$SETUP_SCRIPT" "$TMP_NON_GIT_NO_FLAG" 2>&1)"
no_flag_exit=$?
if [ "$no_flag_exit" -ne 0 ] && grep -Fq "対象ディレクトリは git リポジトリではない" <<<"$no_flag_output"; then
  pass "9f: --workspace を渡さなければ、これまで通り git リポジトリでない対象はエラーで停止する"
else
  fail "9f: --workspace 無しの既定動作が変化している（exit ${no_flag_exit}）:
$no_flag_output"
fi

# ---- 9g/9h. backlog が PATH に無い環境での回帰ガード（--workspace 経路では不要）----
# 冒頭の check_test_dependencies() は backlog の存在を前提にしているので、ここでは
# 呼び出しの瞬間だけ PATH から backlog の解決元ディレクトリを除いた環境を作る。
# git は --workspace 経路でも常に必須なので解決できたままにする。
BACKLOG_BIN_DIR="$(dirname "$(command -v backlog)")"
STRIPPED_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -Fxv "$BACKLOG_BIN_DIR" | tr '\n' ':')"
STRIPPED_PATH="${STRIPPED_PATH%:}"

if PATH="$STRIPPED_PATH" command -v backlog >/dev/null 2>&1; then
  skip "9g/9h: PATH から backlog の解決元ディレクトリ（$BACKLOG_BIN_DIR）を除いても backlog が別の場所から解決できてしまうため、backlog 不在環境の検証をスキップした"
elif ! PATH="$STRIPPED_PATH" command -v git >/dev/null 2>&1; then
  skip "9g/9h: backlog の解決元ディレクトリを PATH から除くと git も解決できなくなるため、backlog 不在環境の検証をスキップした"
else
  # ---- 9g. backlog が PATH に無くても --workspace は成功する ----
  TMP_WORKSPACE_NO_BACKLOG="$(mktemp -d)"
  register_tmp_cleanup "$TMP_WORKSPACE_NO_BACKLOG"

  workspace_no_backlog_output="$(PATH="$STRIPPED_PATH" "$SETUP_SCRIPT" --workspace "$TMP_WORKSPACE_NO_BACKLOG" 2>&1)"
  workspace_no_backlog_exit=$?
  if [ "$workspace_no_backlog_exit" -eq 0 ]; then
    pass "9g: backlog が PATH に無くても --workspace は成功する（P2 fix の回帰防止）"
  else
    fail "9g: backlog が PATH に無いと --workspace が失敗した（exit ${workspace_no_backlog_exit}）:
$workspace_no_backlog_output"
  fi

  workspace_no_backlog_links_ok=true
  for name in "${WORKSPACE_SKILL_NAMES[@]}"; do
    if [ ! -L "$TMP_WORKSPACE_NO_BACKLOG/.claude/skills/$name" ]; then
      workspace_no_backlog_links_ok=false
      fail "9g: backlog が PATH に無い状態で .claude/skills/$name が配置されなかった"
    fi
  done
  if [ "$workspace_no_backlog_links_ok" = true ]; then
    pass "9g: backlog が PATH に無い状態でもワークスペーススキルが正しく配置される"
  fi

  # ---- 9h. 対照: 同じ backlog 不在環境で、--workspace を渡さなければ従来通り
  # backlog 不在エラーで停止する（P2 fix が逆方向に回帰していないことのガード）----
  TMP_NO_BACKLOG_NO_FLAG="$(mktemp -d)"
  register_tmp_cleanup "$TMP_NO_BACKLOG_NO_FLAG"
  no_backlog_no_flag_output="$(PATH="$STRIPPED_PATH" "$SETUP_SCRIPT" "$TMP_NO_BACKLOG_NO_FLAG" 2>&1)"
  no_backlog_no_flag_exit=$?
  if [ "$no_backlog_no_flag_exit" -ne 0 ] && grep -Fq "コマンド 'backlog' が見つからない" <<<"$no_backlog_no_flag_output"; then
    pass "9h: backlog が PATH に無い同じ環境で、--workspace を渡さなければ backlog 不在エラーで停止する（回帰ガード）"
  else
    fail "9h: backlog が PATH に無い状態での --workspace 無し実行の挙動が想定と異なる（exit ${no_backlog_no_flag_exit}）:
$no_backlog_no_flag_output"
  fi
fi

finish_tests
