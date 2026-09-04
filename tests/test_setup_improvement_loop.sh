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

# SKILL_NAMES は claude-code/skills/ ディレクトリの実体を単一の情報源として動的に
# 列挙する。bin/setup-improvement-loop 側と同じ方式で導出することで、片方だけ
# 更新して他方が追随しないという実装依存の同期漏れを構造的に無くす。
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
# （claude-code/skills/status-table.md）の「## 状態遷移表」節に列挙されたステータス名の
# 集合が一致することを検証する。ステータス名の情報源が2箇所に分かれている以上、
# 将来どちらか一方だけが更新されて食い違う可能性が残るため、その食い違いを
# 検知する回帰テスト（TASK-32）。
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
      pass ".claude/skills/$name はリポジトリの claude-code/skills/$name への正しいシンボリックリンクである"
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
# ルートの算出を誤り「配布元の claude-code/skills ディレクトリが見つからない」で
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
echo "=== 5b. statuses のシングルクォート形式に対する回帰テスト（TASK-62） ==="
# parse_statuses_block はダブルクォートしか剥がさない不具合があった
# （claude-code/skills/improvement-dispatch/scripts/check-forbidden-allowed-paths の
# trim_and_unquote はシングル/ダブル両方を対称に剥がすのに、
# parse_statuses_block 側は非対称だった）。有効な YAML であるシングルクォートで
# statuses を書いた場合に、既存要素が空扱いになったり、引用符付きのまま
# 残って REQUIRED_STATUSES と文字列一致せず重複挿入されたりしないことを確認する。

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
default_status: "To Do"
statuses: ['Proposed', 'To Do', 'Done']
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
remote_operations: true
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
# 配布元テンプレート（backlog-md/config.my.yml）に新しいキーが
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
# ensure_config_my_yml_keys が補うのは「導入先に無いキー」だけなので、既にある
# キーの説明コメントは setup-improvement-loop を何度再実行しても更新されない。
# その結果、テンプレート側のコメントに入った重要な訂正が既存の導入先に永久に
# 届かなかった。実例は TASK-69 で、forbidden_paths/allowed_paths の説明に
# 「git 管理外のパスは機械的には止まらない」という限界を書き足したが、既存の
# 導入先には旧説明（「機械的に拒否・検知する仕組みではない」）が残り続けた。
#
# ユーザー所有ファイルを壊さないことを優先し、機械的な差し替えはしない
# （どちらが新しいかをスクリプトから区別できないため）。代わりに、差異がある
# ことと、テンプレート側の最新の説明そのものを利用者に示す。
# ここではその報告が出ること、および報告のためにファイルを一切書き換えない
# ことを検証する。

TMP_REPO_COMMENT_DRIFT="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_COMMENT_DRIFT"

(cd "$TMP_REPO_COMMENT_DRIFT" && git init -q)
mkdir -p "$TMP_REPO_COMMENT_DRIFT/.backlog"

drift_config="$TMP_REPO_COMMENT_DRIFT/.backlog/config.my.yml"
cp "$SOURCE_CONFIG" "$drift_config"

# 「TASK-69 より前のテンプレートで導入されたリポジトリ」を再現する。
# テンプレートの文面に依存しないよう、forbidden_paths のキー行の直前にある
# 連続コメント行（＝そのキーの説明ブロック）の先頭行だけを、旧テンプレートの
# 文言に差し替える。他のキー・値・ユーザー独自の記述には触れない。
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
# 説明コメントの差異検出を追加しても、既存の3つの保護（値の保持・独自キーの保持・
# コメントアウトされたキーを有効化しない）が崩れないことを、1つのファイルに
# 全部を同居させた状態で確認する。

TMP_REPO_DRIFT_USEREDIT="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_DRIFT_USEREDIT"

(cd "$TMP_REPO_DRIFT_USEREDIT" && git init -q)
mkdir -p "$TMP_REPO_DRIFT_USEREDIT/.backlog"

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
# （この限界は warn_config_my_yml_comment_drift の契約コメントに明記されている）。
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
TMP_REPO_FRESH_CONFIG="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_FRESH_CONFIG"

(cd "$TMP_REPO_FRESH_CONFIG" && git init -q)

fresh_output="$("$SETUP_SCRIPT" "$TMP_REPO_FRESH_CONFIG" 2>&1)"
fresh_exit=$?
if [ "$fresh_exit" -eq 0 ]; then
  pass "config.my.yml が無い新規導入の実行が成功する（exit 0）"
else
  fail "config.my.yml が無い新規導入の実行が失敗した（exit ${fresh_exit}）:
$fresh_output"
fi
if cmp -s "$SOURCE_CONFIG" "$TMP_REPO_FRESH_CONFIG/.backlog/config.my.yml"; then
  pass "新規導入の config.my.yml はテンプレートと完全に一致する"
else
  fail "新規導入の config.my.yml がテンプレートと一致しない"
fi
if printf '%s\n' "$fresh_output" | grep -Fq "説明コメントが配布元テンプレートと異なる"; then
  fail "新規導入で説明コメントの差異が報告された（差異検出は既存ファイルがある場合だけ動くべき）:
$fresh_output"
else
  pass "新規導入では説明コメントの差異検出が動かない"
fi

echo ""
echo "=== 7. 旧ステータス名 Reviewed が残る既存 consumer リポジトリの移行（TASK-48） ==="
# TASK-8 で Reviewed は Approved にリネームされたが、この移行は本リポジトリ自身の
# .backlog/config.yml のみを対象に行われ、setup-improvement-loop（配布ロジック）
# には反映されていなかった。TASK-8 以前にセットアップされた既存 consumer
# リポジトリを模擬した一時ディレクトリ環境（statuses に Reviewed と Approved が
# 両方残り、status: Reviewed の既存タスクがある状態）に対して setup-improvement-loop
# を実行し、(a) statuses の重複が解消され Reviewed が消えること（AC#1）、
# (b) 既存タスクが Approved へ移行されること（AC#2）を検証する。
# 実際の consumer リポジトリ（~/dotfiles 等）へは書き込まない。

TMP_REPO_REVIEWED_MIGRATION="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_REVIEWED_MIGRATION"

(cd "$TMP_REPO_REVIEWED_MIGRATION" && git init -q)
mkdir -p "$TMP_REPO_REVIEWED_MIGRATION/.backlog"

# TASK-48 の起票時に実機（~/dotfiles）で確認された statuses の並びをそのまま模擬する。
cat > "$TMP_REPO_REVIEWED_MIGRATION/.backlog/config.yml" <<'YAML'
project_name: "reviewed-migration-test"
default_status: "To Do"
statuses: ["Proposed", "To Do", "In Progress", "In Review", "Reviewed", "Approved", "Done"]
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

# status: Reviewed の既存タスク（TASK-1）と、影響を受けてはいけない別ステータスの
# タスク（TASK-2、To Do のまま）を backlog CLI 経由で用意する。
# TASK-1 のタイトルにわざと "TASK-999"（存在しないタスクID）という文字列を
# 含めておく。`backlog task list --status "Reviewed" --plain` の出力行から
# タスクIDを抽出する実装が、行のどこにでも現れる "TASK-[0-9]+" を素朴に拾うと、
# タイトル中のこの文字列を別タスクのIDと誤検出し、存在しない TASK-999 を
# 移行しようとして失敗する（回帰テスト）。
(cd "$TMP_REPO_REVIEWED_MIGRATION" && backlog task create "reviewed task fix TASK-999 regression" --plain >/dev/null)
(cd "$TMP_REPO_REVIEWED_MIGRATION" && backlog task edit TASK-1 -s "Reviewed" --plain >/dev/null)
(cd "$TMP_REPO_REVIEWED_MIGRATION" && backlog task create "still todo task" --plain >/dev/null)

reviewed_task_file="$(find "$TMP_REPO_REVIEWED_MIGRATION/.backlog/tasks" -name 'task-1 - *.md')"
todo_task_file="$(find "$TMP_REPO_REVIEWED_MIGRATION/.backlog/tasks" -name 'task-2 - *.md')"

if [ -z "$reviewed_task_file" ] || ! grep -Fxq 'status: Reviewed' "$reviewed_task_file"; then
  fail "テスト前提が壊れている: TASK-1 を status: Reviewed にできなかった"
fi

# AC#4 の証跡: 移行前の状態をログに残す（模擬環境での before）。
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

# AC#4 の証跡: 移行後の状態をログに残す（模擬環境での after）。
echo "--- 移行後（after） ---"
echo "config.yml statuses: $(grep -m1 '^statuses:' "$TMP_REPO_REVIEWED_MIGRATION/.backlog/config.yml")"
echo "TASK-1 status: $(grep -m1 '^status:' "$reviewed_task_file")"
echo "TASK-2 status: $(grep -m1 '^status:' "$todo_task_file")"

# ---- AC#1: statuses から旧名 Reviewed が消え、Approved の重複が解消される ----
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

# ---- AC#2: status: Reviewed だった既存タスクが Approved へ移行される ----
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

# タイトルに含まれる "TASK-999" という文字列が、存在しないタスクIDとして
# 誤検出・誤操作されていないことを確認する（回帰テスト）。誤検出されていれば
# 上の「setup-improvement-loop 実行が成功する」の時点で TASK-999 が存在しない
# ため既に失敗しているはずだが、念のためタスクファイルが作られていないことも
# 直接確認する。
fake_task_999_file="$(find "$TMP_REPO_REVIEWED_MIGRATION/.backlog/tasks" -name 'task-999*' 2>/dev/null)"
if [ -z "$fake_task_999_file" ]; then
  pass "タイトル中の 'TASK-999' という文字列が存在しないタスクIDとして誤検出されなかった"
else
  fail "タイトル中の 'TASK-999' が誤ってタスクIDとして扱われた形跡がある: $fake_task_999_file"
fi

echo ""
echo "=== 7b. 移行済みリポジトリへの再実行は何も変化させない（AC#3・冪等性） ==="
# 7. で Reviewed が完全に移行済みになった同じリポジトリに再度実行し、
# 「既に移行済みのリポジトリでは何も変化しない」（AC#3 の後半）ことを確認する。

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
# セクション2で通常セットアップ済みの $TMP_REPO（Reviewed を一度も含んだことが
# 無い）に対して setup-improvement-loop を再実行し、Reviewed 関連の移行処理が
# 両方ともスキップと報告されることを確認する（AC#3 の前半）。

no_reviewed_output="$("$SETUP_SCRIPT" "$TMP_REPO" 2>&1)"
no_reviewed_exit=$?
if [ "$no_reviewed_exit" -eq 0 ]; then
  pass "Reviewed が元から無いリポジトリへの実行が成功する（exit 0）"
else
  fail "Reviewed が元から無いリポジトリへの実行が失敗した（exit ${no_reviewed_exit}）:
$no_reviewed_output"
fi
if grep -Fq "status: Reviewed の既存タスクは見つからなかった" <<<"$no_reviewed_output" \
  && grep -Fq "旧名 'Reviewed' は残っていない" <<<"$no_reviewed_output"; then
  pass "AC#3: Reviewed が元から無い場合も、両方の移行処理がスキップと報告される"
else
  fail "AC#3: Reviewed が元から無い場合に期待するスキップ報告が出力されなかった:
$no_reviewed_output"
fi

echo ""
echo "=== 7d. task_prefix をカスタマイズしたリポジトリでの Reviewed タスク移行（回帰テスト） ==="
# backlog task list --plain が出力する ID は config.yml の task_prefix に応じて
# 変わる（既定は "TASK-<n>" だが、task_prefix: "issue" なら "ISSUE-<n>"）。
# ID 抽出パターンを "TASK-" 固定にすると、task_prefix をカスタマイズした
# リポジトリでは対象タスクを一切検出できず、config.yml の statuses からだけ
# "Reviewed" が消えて既存タスクが status: Reviewed のまま永久に取り残される
# （後続の再実行でも同じく検出できないため回復しない）。この不具合の回帰テスト。

TMP_REPO_CUSTOM_PREFIX="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_CUSTOM_PREFIX"

(cd "$TMP_REPO_CUSTOM_PREFIX" && git init -q)
mkdir -p "$TMP_REPO_CUSTOM_PREFIX/.backlog"
cat > "$TMP_REPO_CUSTOM_PREFIX/.backlog/config.yml" <<'YAML'
project_name: "custom-prefix-test"
default_status: "To Do"
statuses: ["Proposed", "To Do", "In Progress", "In Review", "Reviewed", "Approved", "Done"]
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
# improvement-loop は push を前提としない完全ローカル運用のため、backlog CLI の
# remote git 操作に依存させる理由がなく、backlog init --defaults の既定
# remoteOperations: true を false に収束させる。また、タスクの起票者を
# improvement-loop-bot に統一するため defaultAssignee も収束させる。どちらも
# ensure_backlog_statuses と同じ「未設定・既定値のままの箇所だけを安全に補正し、
# 既にユーザーが設定した値は上書きしない」パターンに従う（TASK番号未採番、
# ユーザー指示による追加）。

TMP_REPO_DEFAULTS="$(mktemp -d)"
register_tmp_cleanup "$TMP_REPO_DEFAULTS"
(cd "$TMP_REPO_DEFAULTS" && git init -q)

defaults_output="$("$SETUP_SCRIPT" "$TMP_REPO_DEFAULTS" 2>&1)"
defaults_exit=$?
if [ "$defaults_exit" -eq 0 ]; then
  pass "8a: 新規セットアップの実行が成功する（exit 0）"
else
  fail "8a: 新規セットアップの実行が失敗した（exit ${defaults_exit}）:
$defaults_output"
fi

remote_ops_after_setup="$(cd "$TMP_REPO_DEFAULTS" && backlog config get remoteOperations 2>/dev/null)"
if [ "$remote_ops_after_setup" = "false" ]; then
  pass "8a: 新規セットアップ後、remoteOperations が false に収束する"
else
  fail "8a: 新規セットアップ後の remoteOperations が false になっていない: '$remote_ops_after_setup'"
fi

defaults_config="$TMP_REPO_DEFAULTS/.backlog/config.yml"
if grep -m1 '^default_assignee:' "$defaults_config" | grep -Fq '@improvement-loop-bot'; then
  pass "8a: 新規セットアップ後、default_assignee が @improvement-loop-bot に収束する"
else
  fail "8a: 新規セットアップ後の default_assignee が @improvement-loop-bot になっていない: $(grep -m1 '^default_assignee:' "$defaults_config")"
fi

# ---- 8b. 冪等性: 再実行しても壊れず、両方とも [skip] と報告される ----
defaults_rerun_output="$("$SETUP_SCRIPT" "$TMP_REPO_DEFAULTS" 2>&1)"
defaults_rerun_exit=$?
if [ "$defaults_rerun_exit" -eq 0 ]; then
  pass "8b: remoteOperations/defaultAssignee が既に収束済みの状態への再実行が成功する（exit 0）"
else
  fail "8b: 再実行が失敗した（exit ${defaults_rerun_exit}）:
$defaults_rerun_output"
fi
if grep -Fq "remoteOperations は既に false" <<<"$defaults_rerun_output"; then
  pass "8b: 再実行時、remoteOperations の収束処理がスキップと報告される"
else
  fail "8b: 再実行時に remoteOperations のスキップ報告が出力されなかった:
$defaults_rerun_output"
fi
if grep -Fq "default_assignee は既に設定されている" <<<"$defaults_rerun_output"; then
  pass "8b: 再実行時、default_assignee の収束処理がスキップと報告される"
else
  fail "8b: 再実行時に default_assignee のスキップ報告が出力されなかった:
$defaults_rerun_output"
fi
assignee_dup_count="$(grep -Ec '^default_assignee:' "$defaults_config" || true)"
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
# --workspace は既定動作（フラグ無し）とは完全に別の経路である。git 判定を
# スキップし、claude-code/workspace-skills/ 配下のスキルだけを .claude/skills/ に
# シンボリックリンクとして配置する。backlog init や .backlog/ 配下の配置は
# 一切行わない（Scope参照）。

# WORKSPACE_SKILL_NAMES は claude-code/workspace-skills/ ディレクトリの実体を単一の
# 情報源として動的に列挙する。bin/setup-improvement-loop 側の
# SOURCE_WORKSPACE_SKILLS_DIR 動的列挙と同じ方式で導出する。
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

# 単一リポジトリ用の5スキルが誤って混入していないことも確認する（Decision 6）。
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

# 配置される .claude/skills/ の件数が、claude-code/workspace-skills/ の件数と厳密に一致することも確認する
# （想定外の余分なエントリが無いことの直接検証）。
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
  # .backlog は --workspace 経路では配置しないため、exclude にも追記されないことを確認する
  # （既定経路の EXCLUDE_LINES=(".backlog" ...) との違いの直接検証）。
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

# ---- 9f. --workspace 無しの既定動作は本セクションの追加後も影響を受けない ----
# 対象ディレクトリが git リポジトリでなければ、これまで通り --workspace 無しでは
# エラーで停止することを再確認する（既定動作の回帰防止の直接検証）。
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

# ---- 9g/9h. backlog が PATH に無い環境での回帰ガード（P2 fix: backlog は
# --workspace 経路では不要）----
# check_test_dependencies() はファイル冒頭で backlog の存在を前提にしている
# ため、ここでは呼び出しの瞬間だけ PATH から backlog の解決元ディレクトリを
# 除いた環境を作り、その中で実行することで「backlog が無い」状態を再現する。
# git は解決できたままにする必要がある（git は --workspace 経路でも常に必須）。
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
