#!/usr/bin/env bash
# tests/test_setup_improvement_loop.sh
#
# bin/setup-improvement-loop（および install.zsh 経由でのシンボリックリンク
# 起動）に対するテスト。単体で実行すると、このファイルの検証だけが走る。
# tests/run.sh から全体実行の一部としても呼ばれる。
#
# 依存は bash/zsh・git・backlog のみ。いずれか欠けていれば、その旨を
# 報告してスキップする（テスト対象の不具合として失敗にはしない）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

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

echo "=== 1d. REQUIRED_STATUSES と状態遷移表の正本の一致 ==="
# REQUIRED_STATUSES（上で導出済み）と、TASK-30 で新設された状態遷移表の正本
# （claude-skills/status-table.md）の「## 状態遷移表」節に列挙されたステータス名の
# 集合が一致することを検証する。ステータス名の情報源が2箇所に分かれている以上、
# 将来どちらか一方だけが更新されて食い違う可能性が残るため、その食い違いを
# 検知する回帰テスト（TASK-32）。
STATUS_TABLE_FILE="$REPO_ROOT/claude-skills/status-table.md"
if [ ! -f "$STATUS_TABLE_FILE" ]; then
  fail "claude-skills/status-table.md が存在しない"
else
  table_statuses_raw="$(awk '
    /^## 状態遷移表/ { flag=1; next }
    /^## / { flag=0 }
    flag
  ' "$STATUS_TABLE_FILE" | grep -E '^\| `' | sed -E 's/^\| `([^`]*)`.*/\1/')"

  if [ -z "$table_statuses_raw" ]; then
    fail "claude-skills/status-table.md の「## 状態遷移表」節からステータス名を1件も抽出できなかった（見出しや表の書式が変わった可能性がある）"
  else
    TABLE_STATUSES=()
    while IFS= read -r line; do
      [ -n "$line" ] && TABLE_STATUSES+=("$line")
    done <<<"$table_statuses_raw"

    required_sorted="$(printf '%s\n' "${REQUIRED_STATUSES[@]}" | sort)"
    table_sorted="$(printf '%s\n' "${TABLE_STATUSES[@]}" | sort)"

    if [ "$required_sorted" = "$table_sorted" ]; then
      pass "REQUIRED_STATUSES と claude-skills/status-table.md の状態遷移表のステータス名一覧が一致する"
    else
      diff_out="$(diff <(printf '%s\n' "$required_sorted") <(printf '%s\n' "$table_sorted"))"
      fail "REQUIRED_STATUSES（bin/setup-improvement-loop）と claude-skills/status-table.md の状態遷移表のステータス名一覧が一致しない:
$diff_out"
    fi
  fi
fi

echo ""
echo "=== 2. 一時リポジトリへのセットアップ ==="

TMP_REPO="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
TMP_REPO_SYMLINK="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO" "$TMP_HOME" "$TMP_REPO_SYMLINK"

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
# improvement ループの4スキルが前提とする Proposed / In Review / Approved が無いと
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

# ---- .git/info/exclude の見出しコメントの検証 ----
EXCLUDE_HEADER="# improvement-loop"
if grep -Fxq "$EXCLUDE_HEADER" "$exclude_file" 2>/dev/null; then
  pass ".git/info/exclude に見出しコメント '$EXCLUDE_HEADER' がある"
else
  fail ".git/info/exclude に見出しコメント '$EXCLUDE_HEADER' が無い"
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

# 見出しコメントも再実行で重複して増えないことを確認する。
header_count="$(grep -Fxc "$EXCLUDE_HEADER" "$exclude_file" 2>/dev/null || true)"
if [ "$header_count" = "1" ]; then
  pass "再実行後も .git/info/exclude の見出しコメント '$EXCLUDE_HEADER' が重複していない"
else
  fail "再実行後、.git/info/exclude の見出しコメント '$EXCLUDE_HEADER' が重複している（${header_count} 行）"
fi

echo ""
echo "=== 4. statuses: [] (空配列) に対する回帰テスト ==="
# macOS の既定 /bin/bash は 3.2 系であり、set -u 下で空配列を
# "${arr[@]}" のように無条件展開すると unbound variable で落ちる
# （bash 4.4 で修正されたバグ）。.backlog/config.yml の statuses が
# 空配列（例: ユーザーが手動で `statuses: []` にした場合）でも
# setup-improvement-loop がクラッシュしないことを確認する。

TMP_REPO_EMPTY_STATUSES="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_EMPTY_STATUSES"

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
register_tmp_cleanup "$TMP_REPO_MULTILINE_STATUSES"

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
register_tmp_cleanup "$TMP_REPO_MIGRATION"

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
if grep -Fq '  # Reviewed になったタスクを dispatch が main に自動マージするかどうか。' "$migration_config"; then
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
# ensure_config_my_yml_keys は、既存キーの検出に "^  key:" という正規表現しか
# 使っていなかったため、ユーザーが値を一時的に無効化する目的で行頭に "#" を
# 付けてコメントアウトしたキー（例: "  # max_in_review: 3"）を「未設定」と
# 誤認し、次回実行時にテンプレート側の既定値付きで有効な形で再追記していた
# （同名キーがコメント化された行と有効な行の2箇所に重複する）。
# コメントアウトされたキーはユーザーが意図的に無効化した状態として扱い、
# 有効な重複キーとして再追記されないことを検証する。

TMP_REPO_COMMENTED="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_COMMENTED"

(cd "$TMP_REPO_COMMENTED" && git init -q)
mkdir -p "$TMP_REPO_COMMENTED/.backlog"

commented_config="$TMP_REPO_COMMENTED/.backlog/config.my.yml"
cp "$SOURCE_CONFIG" "$commented_config"

# 既存キー max_in_review を、ユーザーが一時的に無効化した想定でコメントアウトする。
commented_config_tmp="$(mktemp)"
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

finish_tests
