#!/usr/bin/env bash
# claude-code/skills/improvement-dispatch/scripts/observe-progress に対するテスト。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

DISPATCH_SKILL_FILE="$SOURCE_SKILLS_DIR/improvement-dispatch/SKILL.md"

# dispatch SKILL.md が RESULT: RECORD の出力から追記する本文を取り出すコマンド。テストも同じ
# コマンドで取り出して追記し、SKILL.md にこの文字列がそのまま書かれていることを 5 で確かめる。
EXTRACT_RECORD_COMMAND="sed -e '1,/^RECORD_BEGIN\$/d' -e '/^RECORD_END\$/,\$d'"

echo "=== 1. 準備: 一時 git リポジトリと backlog のスタブ ==="
# notes は backlog CLI から読むので、PATH の先頭に backlog のスタブを置く。スタブは
# `task view <ID> --plain` と `task edit <ID> --append-notes <本文> --plain` だけを受け付け、
# notes を OBSERVE_STUB_DIR/notes-<ID>.txt に保持する。view の出力は tests/test_notes_records.sh の
# TASK-3・TASK-4 のフィクスチャ（backlog CLI 1.48.0 と 1.53.0 の実出力。取得日 2026-09-27）と
# 同じ形で組み立てる。版の差は Modified files 行の位置だけで、1.48.0 はメタデータ部に、
# 1.53.0 は Implementation Notes 節の直後に出す。notes が空なら Implementation Notes 節を出さない。
# append-notes は既存の notes との間に空行を 1 行挟んで追記する（実 CLI の出力と同じ並び）。
# OBSERVE_STUB_VERSION（1.48.0 か 1.53.0）で出力の形を切り替え、両方を毎回検証する。

STUB_ROOT_OBSERVE="$(mktemp -d)"
register_tmp_cleanup "$STUB_ROOT_OBSERVE"
mkdir -p "$STUB_ROOT_OBSERVE/bin" "$STUB_ROOT_OBSERVE/data"
cat > "$STUB_ROOT_OBSERVE/bin/backlog" <<'STUB'
#!/usr/bin/env bash
set -u
dir="${OBSERVE_STUB_DIR:?}"
version="${OBSERVE_STUB_VERSION:?}"
if [ "$#" -eq 4 ] && [ "$1 $2 $4" = "task view --plain" ]; then
  id="$3"
  num="${id#TASK-}"
  notes_file="$dir/notes-$id.txt"
  [ -f "$dir/exists-$id" ] || { printf 'Task %s not found.\n' "$id" >&2; exit 1; }
  printf 'File: <一時リポジトリ>/.backlog/tasks/task-%s - Observe.md\n\n' "$num"
  printf 'Task %s - Observe\n' "$id"
  echo "=================================================="
  echo ""
  echo "Status: ◒ In Progress"
  echo "Ordinal: 1000"
  echo "Created: 2026-09-27 13:52 (UTC)"
  echo "Updated: 2026-09-27 13:52 (UTC)"
  [ "$version" = "1.48.0" ] && echo "Modified files: bin/lib/a.sh"
  echo ""
  echo "Description:"
  echo "--------------------------------------------------"
  echo "No description provided"
  echo ""
  echo "Acceptance Criteria:"
  echo "--------------------------------------------------"
  echo "No acceptance criteria defined"
  echo ""
  echo "Definition of Done:"
  echo "--------------------------------------------------"
  echo "No Definition of Done items defined"
  echo ""
  if [ -s "$notes_file" ]; then
    echo "Implementation Notes:"
    echo "--------------------------------------------------"
    cat "$notes_file"
    echo ""
  fi
  if [ "$version" = "1.53.0" ]; then
    echo "Modified files: bin/lib/a.sh"
    echo ""
  fi
  exit 0
fi
if [ "$#" -eq 6 ] && [ "$1 $2 $4 $6" = "task edit --append-notes --plain" ]; then
  notes_file="$dir/notes-$3.txt"
  if [ -s "$notes_file" ]; then
    printf '\n%s\n' "$5" >> "$notes_file"
  else
    printf '%s\n' "$5" > "$notes_file"
  fi
  exit 0
fi
printf 'backlog スタブ: 想定外の呼び出し: %s\n' "$*" >&2
exit 1
STUB
chmod +x "$STUB_ROOT_OBSERVE/bin/backlog"
: > "$STUB_ROOT_OBSERVE/data/exists-TASK-1"

TMP_OBS_REPO="$(mktemp -d)"
# macOS の mktemp -d はシンボリックリンク経由のパスを返す。スクリプト内部の pwd -P による
# 正規化後と比べるので、ここでも正規化しておく。
TMP_OBS_REPO="$(cd "$TMP_OBS_REPO" && pwd -P)"
OBS_WORKTREE_DIR="${TMP_OBS_REPO}-wt"
register_tmp_cleanup "$TMP_OBS_REPO" "$OBS_WORKTREE_DIR"
(cd "$TMP_OBS_REPO" && git init -q -b main && git commit -q --allow-empty -m init)
(cd "$TMP_OBS_REPO" && git worktree add -q -b feature-observe "$OBS_WORKTREE_DIR" main)
(cd "$OBS_WORKTREE_DIR" && printf 'one\n' > tracked-1.txt && printf 'two\n' > tracked-2.txt \
  && git add tracked-1.txt tracked-2.txt && git commit -q -m "in-progress work")
OBS_COMMIT_LINE="- commit: $(git -C "$OBS_WORKTREE_DIR" log -1 --format='%H (%cI)')"
pass "一時リポジトリとワークツリー、backlog のスタブを用意した"

STUB_VERSION=""
set_notes() {
  printf '%s\n' "$1" > "$STUB_ROOT_OBSERVE/data/notes-TASK-1.txt"
}
clear_notes() {
  rm -f "$STUB_ROOT_OBSERVE/data/notes-TASK-1.txt"
}
observe() {
  run_in "$TMP_OBS_REPO" env PATH="$STUB_ROOT_OBSERVE/bin:$PATH" \
    OBSERVE_STUB_DIR="$STUB_ROOT_OBSERVE/data" OBSERVE_STUB_VERSION="$STUB_VERSION" \
    "$OBSERVE_PROGRESS_SCRIPT" "${1:-TASK-1}" "${2:-$OBS_WORKTREE_DIR}" "${3:-feature-observe}"
}
# 直近の observe の出力から、SKILL.md と同じコマンドで本文を取り出す。
record_body() {
  printf '%s\n' "$RUN_OUT" | eval "$EXTRACT_RECORD_COMMAND"
}
# 直近の observe の本文を、SKILL.md と同じく backlog task edit --append-notes で追記する。
append_record() {
  local body
  body="$(record_body)"
  env PATH="$STUB_ROOT_OBSERVE/bin:$PATH" OBSERVE_STUB_DIR="$STUB_ROOT_OBSERVE/data" \
    OBSERVE_STUB_VERSION="$STUB_VERSION" backlog task edit TASK-1 --append-notes "$body" --plain
}
# 本文の最後の行（観測時刻）を、指定した秒数だけ過去の観測時刻に置き換えたものを出す。
# ISO 側は比較に使われないので、書式が正しい固定値でよい。
# 本文は notes を空にして observe した RECORD の出力から作る（直近の実行が CARRY_OVER だと本文が無いため）。
body_with_age() {
  local age="$1" epoch
  clear_notes
  observe
  epoch=$(( $(date -u +%s) - age ))
  record_body | sed '$d'
  printf -- '- 観測時刻: 2026-01-01T00:00:00Z (epoch %s)\n' "$epoch"
}
body_without_time() {
  record_body | sed '$d'
}

HANDOFF='### 引き渡し
- WORKTREE_DIR: x
- BRANCH: feature-observe'

for STUB_VERSION in 1.48.0 1.53.0; do
  echo ""
  echo "=== 2. [$STUB_VERSION] ワークツリーがある場合の記録・比較・経過判定 ==="
  git -C "$OBS_WORKTREE_DIR" checkout -q -- . 2>/dev/null
  rm -f "$OBS_WORKTREE_DIR/a b.txt"

  echo "--- 2a. 前回の記録が無い -> RECORD と本文（AC#2） ---"
  clear_notes
  observe
  assert "2a[$STUB_VERSION]: notes が無いと RESULT: RECORD（exit 0）・PREVIOUS_RECORD: none" \
    run_result 0 "PREVIOUS_RECORD: none" "RESULT: RECORD"
  assert "2a[$STUB_VERSION]: 本文の 1〜3 行目が見出し・commit・status: (clean)" \
    [ "$(record_body | sed -n '1,3p')" = "### 手順 2 観測記録
$OBS_COMMIT_LINE
- status: (clean)" ]
  assert "2a[$STUB_VERSION]: 本文の最後の行が観測時刻（ISO8601 と epoch）" \
    has_text "$(record_body | tail -n 1 | grep -E '^- 観測時刻: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z \(epoch [0-9]+\)$')" "観測時刻"
  assert "2a[$STUB_VERSION]: RESULT が最終行" last_lines_are "RECORD_END" "RESULT: RECORD"

  echo "--- 2b. 追記した直後に同じ状態で再実行 -> 変化なし・CARRY_OVER（AC#1・AC#2） ---"
  set_notes "$HANDOFF"
  observe
  append_record
  observe
  assert "2b[$STUB_VERSION]: 追記直後の再実行は PREVIOUS_RECORD: unchanged・RESULT: CARRY_OVER（exit 1）" \
    run_result 1 "PREVIOUS_RECORD: unchanged" "RESULT: CARRY_OVER"
  assert_not "2b[$STUB_VERSION]: CARRY_OVER では本文を出さない" has_line "$RUN_OUT" "RECORD_BEGIN"

  echo "--- 2c. 変化なしで 30 分以上経過 -> RUN_RECOVERY、30 分未満 -> CARRY_OVER（AC#1） ---"
  set_notes "$HANDOFF

$(body_with_age 1900)"
  observe
  assert "2c[$STUB_VERSION]: 記録から 1900 秒経過で RESULT: RUN_RECOVERY（exit 2）" \
    run_result 2 "PREVIOUS_RECORD: unchanged" "THRESHOLD_SECONDS: 1800" "RESULT: RUN_RECOVERY"
  set_notes "$HANDOFF

$(body_with_age 1790)"
  observe
  assert "2c[$STUB_VERSION]: 記録から 1790 秒経過では RESULT: CARRY_OVER（exit 1）" \
    run_result 1 "PREVIOUS_RECORD: unchanged" "RESULT: CARRY_OVER"
  set_notes "$HANDOFF

$(body_with_age 1800)"
  observe
  assert "2c[$STUB_VERSION]: ちょうど閾値（1800 秒）経過で RESULT: RUN_RECOVERY" \
    run_result 2 "RESULT: RUN_RECOVERY"

  echo "--- 2d. 最後の記録だけと比べる・引き渡しより前の記録は比べない ---"
  set_notes "$HANDOFF

### 手順 2 観測記録
- commit: 0000000000000000000000000000000000000000 (2026-01-01T00:00:00+09:00)
- status: (clean)
- 観測時刻: 2026-01-01T00:00:00Z (epoch 1)

$(body_with_age 60)"
  observe
  assert "2d[$STUB_VERSION]: 古い記録が残っていても最後の記録と比べる（CARRY_OVER）" \
    run_result 1 "RESULT: CARRY_OVER"
  set_notes "$(body_with_age 3600)

$HANDOFF"
  observe
  assert "2d[$STUB_VERSION]: 観測記録が最後の引き渡しより前にしか無ければ PREVIOUS_RECORD: none・RECORD" \
    run_result 0 "PREVIOUS_RECORD: none" "RESULT: RECORD"

  echo "--- 2e. 状態が変わった -> RECORD（AC#2） ---"
  set_notes "$HANDOFF"
  observe
  append_record
  printf 'changed\n' >> "$OBS_WORKTREE_DIR/tracked-1.txt"
  observe
  assert "2e[$STUB_VERSION]: 作業ツリーが変わると PREVIOUS_RECORD: changed・RESULT: RECORD" \
    run_result 0 "PREVIOUS_RECORD: changed" "RESULT: RECORD"
  assert "2e[$STUB_VERSION]: status に porcelain の行が 1 行ずつ出る" \
    [ "$(record_body | sed -n '3,4p')" = "- status:
  -  M tracked-1.txt" ]

  echo "--- 2f. 未コミットの変更が複数行・ファイル名に空白 -> 本文が毎回同一（AC#3） ---"
  printf 'changed\n' >> "$OBS_WORKTREE_DIR/tracked-2.txt"
  printf 'x\n' > "$OBS_WORKTREE_DIR/a b.txt"
  set_notes "$HANDOFF"
  observe
  first_body="$(body_without_time)"
  observe
  second_body="$(body_without_time)"
  assert "2f[$STUB_VERSION]: 同じ状態に対する本文（観測時刻を除く）が 2 回とも同一" \
    [ "$first_body" = "$second_body" ]
  assert "2f[$STUB_VERSION]: 本文に 3 件の変更がそれぞれ 1 行で出る（空白を含むパスは引用符付き）" \
    [ "$(printf '%s\n' "$first_body" | sed -n '4,$p')" = '  -  M tracked-1.txt
  -  M tracked-2.txt
  - ?? "a b.txt"' ]
  append_record
  observe
  assert "2f[$STUB_VERSION]: 複数行・空白入りの記録を追記した直後の再実行も CARRY_OVER" \
    run_result 1 "PREVIOUS_RECORD: unchanged" "RESULT: CARRY_OVER"

  echo "--- 2g. 書式の揺れた手書きの記録 -> エラーで止まらず RECORD（AC#4） ---"
  git -C "$OBS_WORKTREE_DIR" checkout -q -- .
  rm -f "$OBS_WORKTREE_DIR/a b.txt"
  printf 'changed\n' >> "$OBS_WORKTREE_DIR/tracked-1.txt"
  # TASK-78 の実記録と同じ形（status を引用符で囲み、補足行が付く）。
  set_notes "$HANDOFF

### 手順 2 観測記録
$OBS_COMMIT_LINE
- status: \" M tracked-1.txt\"
- 観測時刻: $(date -u +%FT%TZ)
- 補足: サブエージェントは running（12分経過）。"
  observe
  assert "2g[$STUB_VERSION]: TASK-78 形式（引用符付き・補足行）でも PREVIOUS_RECORD: changed・RECORD（exit 0）" \
    run_result 0 "PREVIOUS_RECORD: changed" "RESULT: RECORD"
  # TASK-100 の実記録と同じ形（複数行を ' / ' で連結）。
  printf 'changed\n' >> "$OBS_WORKTREE_DIR/tracked-2.txt"
  set_notes "$HANDOFF

### 手順 2 観測記録
$OBS_COMMIT_LINE
- status:  M tracked-1.txt /  M tracked-2.txt
- 観測時刻: $(date -u +%FT%TZ)"
  observe
  assert "2g[$STUB_VERSION]: TASK-100 形式（' / ' 連結）でも PREVIOUS_RECORD: changed・RECORD（exit 0）" \
    run_result 0 "PREVIOUS_RECORD: changed" "RESULT: RECORD"
  # 規定どおりの 3 行だが epoch が無い（このスクリプト導入前の書式）。状態は一致していても
  # 経過を計算できないので、新しい記録を残す側に倒れる。
  git -C "$OBS_WORKTREE_DIR" checkout -q -- .
  set_notes "$HANDOFF

### 手順 2 観測記録
$OBS_COMMIT_LINE
- status: (clean)
- 観測時刻: 2026-01-01T00:00:00Z"
  observe
  assert "2g[$STUB_VERSION]: epoch の無い旧書式の記録は状態が同じでも PREVIOUS_RECORD: changed・RECORD" \
    run_result 0 "PREVIOUS_RECORD: changed" "RESULT: RECORD"
done

echo ""
echo "=== 3. ワークツリーが無い場合（AC#5） ==="
(cd "$TMP_OBS_REPO" && git worktree remove "$OBS_WORKTREE_DIR")
OBS_BRANCH_COMMIT_LINE="- commit: $(git -C "$TMP_OBS_REPO" log -1 --format='%H (%cI)' feature-observe)"
for STUB_VERSION in 1.48.0 1.53.0; do
  set_notes "$HANDOFF"
  observe
  assert "3a[$STUB_VERSION]: ブランチだけ残る場合は WORKTREE_EXISTS: false・BRANCH_EXISTS: true・RECORD" \
    run_result 0 "WORKTREE_EXISTS: false" "BRANCH_EXISTS: true" "RESULT: RECORD"
  assert "3a[$STUB_VERSION]: ブランチの直近コミットを観測値にし、status は (ワークツリー無し)" \
    [ "$(record_body | sed -n '2,3p')" = "$OBS_BRANCH_COMMIT_LINE
- status: (ワークツリー無し)" ]
  append_record
  observe
  assert "3a[$STUB_VERSION]: ブランチだけ残る場合も同じ比較ロジックで、追記直後の再実行は CARRY_OVER" \
    run_result 1 "PREVIOUS_RECORD: unchanged" "RESULT: CARRY_OVER"
  set_notes "$HANDOFF

$(body_with_age 1900)"
  observe
  assert "3a[$STUB_VERSION]: ブランチだけ残り変化なしで 30 分以上なら RUN_RECOVERY" \
    run_result 2 "RESULT: RUN_RECOVERY"
done

STUB_VERSION=1.53.0
(cd "$TMP_OBS_REPO" && git branch -q -D feature-observe)
observe TASK-404
assert "3b: ワークツリーもブランチも無ければ、観測を待たず（notes を読まず）RUN_RECOVERY（exit 2）" \
  run_result 2 "WORKTREE_EXISTS: false" "BRANCH_EXISTS: false" "RESULT: RUN_RECOVERY"

echo ""
echo "=== 4. 引数・環境の誤り ==="
observe_args() {
  run_in "$TMP_OBS_REPO" env PATH="$STUB_ROOT_OBSERVE/bin:$PATH" \
    OBSERVE_STUB_DIR="$STUB_ROOT_OBSERVE/data" OBSERVE_STUB_VERSION="$STUB_VERSION" \
    "$OBSERVE_PROGRESS_SCRIPT" "$@"
}
observe_args TASK-1 "$OBS_WORKTREE_DIR"
assert "4a: 引数不足は RESULT: ERROR（exit 3）" run_result 3 "RESULT: ERROR"
observe_args TASK-1 "" feature-observe
assert "4a: 空の引数は RESULT: ERROR（exit 3）" run_result 3 "RESULT: ERROR"
(cd "$TMP_OBS_REPO" && git branch -q feature-observe main)
observe TASK-404
assert "4b: backlog task view が失敗すると RESULT: ERROR（exit 3）" run_result 3 "RESULT: ERROR"

echo ""
echo "=== 5. 閾値の共有（AC#6）と SKILL.md の置き換え（AC#7） ==="
threshold_value="$(bash -c 'source "$1"; printf "%s" "$IMPROVEMENT_STALE_THRESHOLD_SECONDS"' _ "$STALE_THRESHOLD_SCRIPT")"
assert "5a: bin/lib/stale_threshold.sh が閾値 1800 を定義する" [ "$threshold_value" = "1800" ]
for shared_script in "$OBSERVE_PROGRESS_SCRIPT" "$CHECK_RECOVERY_SCRIPT"; do
  shared_name="$(basename "$shared_script")"
  assert "5a: $shared_name は bin/lib/stale_threshold.sh を source する" \
    grep -Fxq "source \"\$DIST_REPO_ROOT/bin/lib/stale_threshold.sh\"" "$shared_script"
  assert_not "5a: $shared_name は閾値の数値を自分で持たない" grep -Eq '(^|[^0-9])1800([^0-9]|$)' "$shared_script"
done
ASSERT_DETAIL=""
assert "5b: SKILL.md 手順 2-3 が observe-progress を呼ぶ" \
  has_text "$(cat "$DISPATCH_SKILL_FILE")" ".claude/skills/improvement-dispatch/scripts/observe-progress"
assert "5b: SKILL.md の本文取り出しコマンドがテストの取り出しコマンドと同じ" \
  has_text "$(cat "$DISPATCH_SKILL_FILE")" "$EXTRACT_RECORD_COMMAND"
for result_value in RECORD CARRY_OVER RUN_RECOVERY ERROR; do
  assert "5b: SKILL.md の対応表に RESULT $result_value の行がある" \
    grep -Eq "^\| \`$result_value\`（[0-9]）" "$DISPATCH_SKILL_FILE"
done
assert_not "5b: SKILL.md から散文の経過判定（経過が 30 分未満）が消えている" \
  has_text "$(cat "$DISPATCH_SKILL_FILE")" "経過が 30 分未満"

finish_tests
