#!/usr/bin/env bash
# claude-code/skills/improvement-dispatch/scripts/check-review-records（dispatch 手順 6 の
# レビュー記録の照合）と、その書式の正本 claude-code/skills/improvement-work/review-record-format.md に対するテスト。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

FORMAT_REL="claude-code/skills/improvement-work/review-record-format.md"
FORMAT_FILE="$REPO_ROOT/$FORMAT_REL"
WORK_SKILL_FILE="$SOURCE_SKILLS_DIR/improvement-work/SKILL.md"

# ---- backlog のスタブ ----
# スクリプトは `backlog task view <ID> --plain` を自分で呼ぶ。notes の周辺の出力は CLI の
# バージョンで違う（1.48.0 は「Modified files: ...」行をメタデータ部に、1.53.0 は Implementation
# Notes 節の直後に出す。tests/test_notes_records.sh の実出力のフィクスチャを参照）。実行環境の
# CLI のバージョンによらず両側を毎回検証するため、PATH の先頭にスタブを置き、同じ notes を
# 両バージョンの並びで包んだ出力を返させる。各ケースは両バージョンで同じ結果にならなければならない。
STUB_ROOT="$(mktemp -d)"
register_tmp_cleanup "$STUB_ROOT"
mkdir -p "$STUB_ROOT/bin" "$STUB_ROOT/1.48.0" "$STUB_ROOT/1.53.0" "$STUB_ROOT/notes"
cat > "$STUB_ROOT/bin/backlog" <<'STUB'
#!/usr/bin/env bash
set -u
dir="${REVIEW_STUB_FIXTURE_DIR:?}"
if [ "$#" -eq 4 ] && [ "$1 $2 $4" = "task view --plain" ] && [ -f "$dir/view-$3.txt" ]; then
  # 成功時にも標準エラーへ警告を出す。照合がこれを notes の行として読まないことを毎回確かめる。
  printf -- '- 警告: スタブの標準エラー出力\n' >&2
  cat "$dir/view-$3.txt"
  exit 0
fi
printf 'Task %s not found.\n' "$3" >&2
exit 1
STUB
chmod +x "$STUB_ROOT/bin/backlog"

# build_view <タスク ID>: $STUB_ROOT/notes/<タスク ID>.txt の notes を、1.48.0 と 1.53.0 の
# task view --plain の並びで包んだフィクスチャを作る。並びは TASK-117 の実出力（1.53.0、
# Implementation Plan・Modified files・Comments・Final Summary あり）と、それを 1.48.0 の
# 並び（Modified files 行がメタデータ部）に置き換えたものである。
build_view() {
  local id="$1" notes_file="$STUB_ROOT/notes/$1.txt" ver
  for ver in 1.48.0 1.53.0; do
    {
      printf 'File: <一時リポジトリ>/.backlog/tasks/%s - Fixture.md\n\n' "$id"
      printf 'Task %s - Fixture\n' "$id"
      printf '==================================================\n\n'
      printf 'Status: ◒ In Progress\nPriority: High\nAssignee: @improvement-work\n'
      printf 'Created: 2026-09-27 12:27 (UTC)\nUpdated: 2026-09-27 13:04 (UTC)\n'
      if [ "$ver" = "1.48.0" ]; then
        printf 'Modified files: claude-code/skills/improvement-work/SKILL.md\n'
      fi
      printf '\nDescription:\n--------------------------------------------------\n'
      printf '### レビュー 9 巡目\n- 方法: 自己レビュー\n\n'
      printf 'Acceptance Criteria:\n--------------------------------------------------\n'
      printf -- '- [x] #1 fixture\n\n'
      printf 'Definition of Done:\n--------------------------------------------------\n'
      printf 'No Definition of Done items defined\n\n'
      printf 'Implementation Plan:\n--------------------------------------------------\n'
      printf '1. plan\n\n'
      printf 'Implementation Notes:\n--------------------------------------------------\n'
      cat "$notes_file"
      printf '\n'
      if [ "$ver" = "1.53.0" ]; then
        printf 'Modified files: claude-code/skills/improvement-work/SKILL.md\n\n'
      fi
      printf 'Comments:\n--------------------------------------------------\n'
      printf '#1 - @dispatch - 2026-09-27 13:04 (UTC)\n### レビュー 8 巡目\n- 結果: P0 1 / P1 0 / P2 0 / P3 0\n\n'
      printf 'Final Summary:\n--------------------------------------------------\n'
      printf 'summary\n'
    } > "$STUB_ROOT/$ver/view-$id.txt"
  done
}

# write_notes <タスク ID>: 標準入力を notes としてフィクスチャを作る。
write_notes() {
  cat > "$STUB_ROOT/notes/$1.txt"
  build_view "$1"
}

# check_both <ラベル> <タスク ID> <期待する終了コード> [出力に含まれるべき行 | !出力に含まれてはならない文字列 ...]
#   両バージョンのスタブで check-review-records を実行し、終了コードと最終行の RESULT、
#   指定した行の完全一致を検証する。`!` で始まる引数は、その後ろの文字列が出力のどこにも
#   含まれないことを検証する。期待する RESULT は終了コードから決める。
check_both() {
  local label="$1" id="$2" code="$3" ver expect arg absent_ok
  local -a present=() absent=()
  shift 3
  for arg in "$@"; do
    case "$arg" in
      '!'*) absent+=("${arg#!}") ;;
      *) present+=("$arg") ;;
    esac
  done
  case "$code" in
    0) expect="RESULT: OK" ;;
    1) expect="RESULT: NOT_CONVERGED" ;;
    2) expect="RESULT: ERROR" ;;
    3) expect="RESULT: NO_RECORDS" ;;
    5) expect="RESULT: NEEDS_REVIEW" ;;
  esac
  for ver in 1.48.0 1.53.0; do
    run_in "$STUB_ROOT" env PATH="$STUB_ROOT/bin:$PATH" REVIEW_STUB_FIXTURE_DIR="$STUB_ROOT/$ver" \
      "$CHECK_REVIEW_RECORDS_SCRIPT" "$id"
    assert "[$ver] $label" run_result "$code" ${present[@]+"${present[@]}"}
    assert "[${ver}] ${label}（最終行が ${expect}）" last_lines_are "$expect"
    if [ "${#absent[@]}" -gt 0 ]; then
      absent_ok=1
      for arg in "${absent[@]}"; do
        if has_text "$RUN_OUT" "$arg"; then absent_ok=0; fi
      done
      assert "[${ver}] ${label}（出力に含まれない: ${absent[*]}）" [ "$absent_ok" -eq 1 ]
    fi
  done
}

echo "=== 1. TASK-117 の実記録 ==="
# notes は `backlog task view TASK-117 --plain`（CLI 1.53.0、2026-09-27 取得）の Implementation Notes 節を
# そのまま写したものである。4 巡の記録が 4 行の書式どおりに並び、最終巡の後に見出し無しの「検証:」の
# 記録（`- ` で始まる行を含む）が連なっている。
write_notes TASK-117 <<'NOTES'
### 引き渡し
- WORKTREE_DIR: /Users/hirotoni/Documents/GitHub/improvement-loop/.worktree/improvement-loop/task-117-protect-shared-backlog-config
- BRANCH: improvement/task-117-protect-shared-backlog-config
- BASE: main 84b9f63
- 引き渡し先: improvement-work サブエージェント（general-purpose、背景実行）

### Collected Findings
- code: create-worktree が $REPO_ROOT/.backlog へのシンボリックリンクをワークツリーに作る（config.yml の複製・検知は無い）。改変検知の仕組みは scripts/ 配下に無い。
- docs: improvement-work/SKILL.md 手順1 に「シンボリックリンクを削除・置換しない」規定のみ。config.yml を書き換えない・cd 失敗で止める規定は無い。dispatch/SKILL.md 手順6 に config.yml の確認項目は無い。
- tests: tests/test_create_worktree.sh（.backlog リンクの検証あり）、tests/test_skill_script_lookup.sh（improvement-work 手順1/8 の「X=\"\" の次行が MAIN_WORKTREE_ROOT=」形の探索ブロックがちょうど2つであることを検査）、tests/test_syntax.sh（CHECK_SCRIPTS に列挙したスクリプトを bash -n/shellcheck）。
- 既存の記録: TASK-93（touch-occupancy は MAIN_WORKTREE_ROOT を先に書く形で lookup テストの対象外）、TASK-76。
- 一時リポジトリでの実測: backlog task create/edit/list/view/search は config.yml を1バイトも変えない（cmp 一致）。通常のタスク操作で誤検知は起きない。
- ローカル規約: CLAUDE.md 無し。検証は bash tests/run.sh。

### Working Plan Context
- 目的: 共有 config.yml の改変を規定・検知・復元の3面で防ぐ。
- 確定している前提: 変更範囲は SKILL.md 2つ・claude-code/skills 配下スクリプト・対応テスト。tests/test_setup_improvement_loop.sh には触らない。
- 壊してはいけない制約: create-worktree の標準出力契約（RESULT 1行目、WORKTREE_DIR/BRANCH が最後の2行）、lookup テストの2ブロック前提。

### 自己解決した判断
- 判断: 複製と検知・復元を1本のスクリプト claude-code/skills/improvement-dispatch/scripts/backlog-config-snapshot（save/check/restore）にまとめ、create-worktree が引き渡し時に save を呼ぶ。
  根拠: 保存先パスの決め方を1箇所に置くため。bin/lib に置くと変更範囲（claude-code/skills 配下）を外れる。
  採用しなかった選択肢: 検知ロジックを check-forbidden-allowed-paths に混ぜる（責務が違う）。
- 判断: 複製の置き場所は <git-common-dir>/improvement-loop/backlog-config-snapshots/<task-id>.yml。
  根拠: .git 内は追跡対象外なので .git/info/exclude の運用を変えずに済み、ワークツリー削除後も残り、サブエージェントの .backlog 経由の書き込みが届かない。
  採用しなかった選択肢: ワークツリー直下（exclude 追加が必要で、ワークツリー削除で消える）。
- 判断: 比較対象はメインの作業木（git worktree list の1行目）の .backlog/config.yml に固定する。
  根拠: ワークツリーのリンクが実ディレクトリに置き換わっていても、共有の実体を見るため。
- 判断: 検知しても自動では戻さない。restore は人間が明示的に実行する経路とし、上書き前の内容を .before-restore に退避する。improvement-work は検知したら報告・コメントのみでコミットは止めない。
  根拠: 変更が人間の意図的な設定変更である可能性を機械的に区別できない。コミット内容自体は config.yml と無関係。
  採用しなかった選択肢: 検知時に自動復元（人間の正当な変更を消しうる）。
- 判断: improvement-work の lookup は touch-occupancy と同じく MAIN_WORKTREE_ROOT を先に書く形にする。
  根拠: tests/test_skill_script_lookup.sh は手順1/8の2ブロックだけを対象にしている（TASK-93 と同じ扱い）。

実装: backlog-config-snapshot（save/check/restore/accept）追加、create-worktree から save、improvement-work/dispatch SKILL.md に規定・検知・復元手順、テスト追加。

### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: P0 0 / P1 1 / P2 2 / P3 3
- 対応: P1（再引き渡しで save が壊れた config.yml で複製を上書きしうる）→ save は内容の違う既存の複製を上書きせず KEPT_EXISTING を返すようにし、人間用の accept を追加。テスト追加。P2（RESTORE_COMMAND がワークツリー内の実体を指しマージ後に消える）→ メインの作業木の .claude/skills 経由の実体を優先。P2（複数タスク CHANGED 時にどの複製で戻すか）→ dispatch 手順7 に最も早く引き渡したタスクの複製を使う旨と diff の案内を追記。P3（見出し番号 16 重複）→ 17 に変更。P3（複製の累積）→ スクリプト冒頭と dispatch 手順7に自動で消えない旨を明記。P3（restore が非アトミック）→ inode・パーミッション維持のための意図的な選択で、退避済みなので見送り。

### レビュー 2 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: P0 0 / P1 0 / P2 2 / P3 3
- 対応: P2（improvement-work の確認節がコミットの作法の後にあり「コミットの前に」と矛盾）→ 節を commit の作法の前へ移し「### コミットの作法」見出しで区切った。P2（KEPT_EXISTING が stderr のみで dispatch に対処が無い／誤検知）→ create-worktree が標準出力に BACKLOG_CONFIG_SNAPSHOT=KEPT_EXISTING を WORKTREE_DIR の手前に出し、dispatch 手順5 に「引き渡しは進め、手順7で accept/restore を人間に案内」と、誤検知を許容する理由（見逃しより誤検知）を明記。テスト追加。P3（before-restore が上書きされる）→ .before-restore.<UTC時刻>.<PID> に変更。P3（dispatch で実体不在時 127）→ 126/127 は ERROR 扱いと明記。P3（3つ目の探索ブロックが lookup テスト対象外）→ touch-occupancy と同じ既存の扱いとして見送り。

### レビュー 3 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: P0 0 / P1 0 / P2 1 / P3 4
- 対応: P2（create-worktree が複製スクリプトの RESULT: 行を接頭辞なしで stderr に流し、dispatch が create-worktree 自身の RESULT: 行と取り違えうる）→ SAVED のときは何も出さず、それ以外は [backlog-config-snapshot] 接頭辞を付けて stderr へ。テスト2件追加。P3（手順8 の分岐0が「そのまま git commit」）→ 下の確認を経てコミットする文言に修正。P3（見出し前の空行）→ 修正。P3（引き渡し時に config.yml が無いと後から作られたものを検知しない）→ NO_SNAPSHOT の説明に明記。P3（config.yml が壊れると dispatch が手順6に到達する前に止まりうる）→ 受入基準の外（AC2 は満たす）なので見送り、残るリスクとして報告。なお、レビュー役は tests/run.sh の実行を権限で拒否され未実行、git diff main に出る test_setup_improvement_loop.sh の差分は main 側が TASK-114 で進んだためで、このブランチは触っていない（git diff HEAD で確認済み）。

### レビュー 4 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: P0 0 / P1 0 / P2 0 / P3 3
- 対応: P3 3件とも修正（KEPT_EXISTING の案内を err から warn に変更、save 失敗時の NO_SNAPSHOT の記述を「既存の複製が無ければ」に限定、dispatch の引き渡しで返す内容に config.yml 確認結果を追加）。修正後 bash tests/run.sh PASS 563 / FAIL 0。

検証:
- bash tests/run.sh → PASS 563 / FAIL 0 / SKIP 0（16ファイル）。実行前後で共有 config.yml の md5 は 05f72691… のまま。
- 一時リポジトリ（mktemp -d、backlog init --defaults で実ディレクトリの .backlog）での実演: create-worktree → RESULT: SAVED。ワークツリー直下から printf > .backlog/config.yml で事故を再現 → ワークツリーからの check と本体からの check がともに RESULT: CHANGED（exit 1）、差分と RESTORE_COMMAND を出力。restore → RESULT: RESTORED、BACKUP= に退避、その後 check は RESULT: OK。実演後に一時ディレクトリを削除。
- check-forbidden-allowed-paths → RESULT: OK。
- このタスク自身の backlog-config-snapshot check → RESULT: NO_SNAPSHOT（仕組み導入前に作られたワークツリーのため。想定どおり）。
NOTES

check_both "TASK-117 の実記録は OK になる" TASK-117 0 \
  "REVIEW_ROUNDS: 4" "FINAL_ROUND: レビュー 4 巡目" "FINAL_RESULT: P0 0 / P1 0 / P2 0 / P3 3"

echo ""
echo "=== 2. 記録が無い（受入基準 #1） ==="

write_notes NOREC <<'NOTES'
### 引き渡し
- BRANCH: improvement/task-1-x

### Collected Findings
- code: ...
NOTES
check_both "引き渡し以降にレビュー記録が無ければ NO_RECORDS" NOREC 3 "REVIEW_ROUNDS: 0"

# 前回の引き渡しの記録が OK でも、再引き渡し以降に 1 巡も無ければ未実施である（#1・#5）。
{ cat "$STUB_ROOT/notes/TASK-117.txt"; printf '\n### 引き渡し\n- BRANCH: 再引き渡し\n'; } > "$STUB_ROOT/notes/REDISPATCH_EMPTY.txt"
build_view REDISPATCH_EMPTY
check_both "TASK-117 の記録の後に再引き渡しがあり、その後に記録が無ければ NO_RECORDS" REDISPATCH_EMPTY 3 "REVIEW_ROUNDS: 0"

write_notes EMPTY_NOTES <<'NOTES'
メモだけで見出しが無い
NOTES
check_both "notes に見出しが無ければ NO_RECORDS" EMPTY_NOTES 3

echo ""
echo "=== 3. 最終巡の件数（受入基準 #2） ==="

write_notes REMAIN <<'NOTES'
### 引き渡し
- BRANCH: x

### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: P0 0 / P1 1 / P2 0 / P3 0
- 対応: P1 を直した。

### レビュー 2 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: P0 0 / P1 0 / P2 2 / P3 1
- 対応: P2 2 件を直した。
NOTES
check_both "最終巡に取り下げの記載の無い P2 があれば NOT_CONVERGED" REMAIN 1 \
  "FINAL_ROUND: レビュー 2 巡目" \
  "NOT_CONVERGED: レビュー 2 巡目: P0/P1/P2 が 2 件あり、対応に取り下げの記載が無い"

write_notes CLEAN <<'NOTES'
### 引き渡し
- BRANCH: x

### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: P0 1 / P1 1 / P2 1 / P3 0
- 対応: すべて直した。

### レビュー 2 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: No findings
- 対応: なし
NOTES
check_both "前の巡に指摘があっても最終巡が No findings なら OK" CLEAN 0 \
  "REVIEW_ROUNDS: 2" "FINAL_RESULT: No findings"

# 見出し無しで追記された後続の記録に「取り下げ」や項目行があっても、対応の続きとしては読まない。
write_notes TRAILING <<'NOTES'
### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: P0 0 / P1 0 / P2 1 / P3 0
- 対応: 直した。

検証:
- 前回の P2 はレビュー役が取り下げた、とは書いていない別の記録
- 結果: P0 0 / P1 0 / P2 0 / P3 0
NOTES
check_both "空行の後の見出し無しの記録は対応に含めない（引き渡しが無ければ notes 全体が対象）" TRAILING 1 \
  "NOT_CONVERGED: レビュー 1 巡目: P0/P1/P2 が 1 件あり、対応に取り下げの記載が無い"

write_notes NOTE_SUFFIX <<'NOTES'
### レビュー 1 巡目
- 方法: 独立サブエージェント（1 回目は停止したので再度呼び出した）
- 自己レビューにした理由: 該当なし
- 結果: P0 0 / P1 0 / P2 0 / P3 2（前巡の P2 は解消と評価）
- 対応: P3 は見送り。
NOTES
check_both "方法・結果の値の後ろの全角括弧の注記は除いて読む" NOTE_SUFFIX 0 \
  "FINAL_RESULT: P0 0 / P1 0 / P2 0 / P3 2"

echo ""
echo "=== 4. 書式の崩れ（受入基準 #3・#8・#9） ==="
# 書式の崩れは差し戻しの根拠にしない。巡を FORMAT_WARNING: で名指しし、RESULT は NEEDS_REVIEW（要確認）になる。

# format_case <ID> <期待する FORMAT_WARNING 行...> : 標準入力の 1 巡目を記録にして検証する。
format_case() {
  local id="$1"
  shift
  { printf '### 引き渡し\n- BRANCH: x\n\n'; cat; } > "$STUB_ROOT/notes/$id.txt"
  build_view "$id"
  check_both "書式の崩れを名指しし、要確認にする: $1" "$id" 5 "$@"
}

FINAL_UNREADABLE="FORMAT_WARNING: レビュー 1 巡目: 最終巡の結果の件数が読めないので、停止条件（P0/P1/P2 が残っていないこと）は確かめていない（未照合）"
METHOD_UNREADABLE="FORMAT_WARNING: レビュー 1 巡目: 方法が読めないので、自己レビューの巡かどうかは確かめていない（未照合）"

format_case FMT_NO_METHOD "FORMAT_WARNING: レビュー 1 巡目: 「- 方法: 」の行が無い" "$METHOD_UNREADABLE" <<'NOTES'
### レビュー 1 巡目
- 自己レビューにした理由: 該当なし
- 結果: No findings
- 対応: なし
NOTES

format_case FMT_NO_RESULT "FORMAT_WARNING: レビュー 1 巡目: 「- 結果: 」の行が無い" "$FINAL_UNREADABLE" <<'NOTES'
### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 対応: なし
NOTES

format_case FMT_FULLWIDTH_COLON "FORMAT_WARNING: レビュー 1 巡目: 「- 結果: 」の行が無い" "$FINAL_UNREADABLE" <<'NOTES'
### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果：No findings
- 対応: なし
NOTES

format_case FMT_UNREADABLE "FORMAT_WARNING: レビュー 1 巡目: 結果の件数が読めない（P0 0 / P1 0 / P2 0）" "$FINAL_UNREADABLE" <<'NOTES'
### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: P0 0 / P1 0 / P2 0
- 対応: なし
NOTES

# 最終巡の件数が読めなければ、指摘が残っていそうでも NOT_CONVERGED にはしない（#8）。
format_case FMT_WORDS "FORMAT_WARNING: レビュー 1 巡目: 結果の件数が読めない（指摘は P1 が 1 件）" "$FINAL_UNREADABLE" \
  '!NOT_CONVERGED' <<'NOTES'
### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: 指摘は P1 が 1 件
- 対応: 直した。
NOTES

format_case FMT_METHOD "FORMAT_WARNING: レビュー 1 巡目: 方法の値が「独立サブエージェント」「自己レビュー」のどちらでもない（サブエージェント）" "$METHOD_UNREADABLE" <<'NOTES'
### レビュー 1 巡目
- 方法: サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: No findings
- 対応: なし
NOTES

format_case FMT_HEADING "FORMAT_WARNING: レビュー1巡目: 見出しが「レビュー <巡数> 巡目」の形ではない" <<'NOTES'
### レビュー1巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: No findings
- 対応: なし
NOTES

format_case FMT_HEADING_PREFIX "FORMAT_WARNING: 再レビュー 1 巡目: 見出しが「レビュー <巡数> 巡目」の形ではない" <<'NOTES'
### 再レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: No findings
- 対応: なし
NOTES

format_case FMT_DUP "FORMAT_WARNING: レビュー 1 巡目: 「- 結果: 」の行が 2 行ある" "$FINAL_UNREADABLE" <<'NOTES'
### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: No findings
- 結果: P0 0 / P1 0 / P2 0 / P3 0
- 対応: なし
NOTES

# 自己レビューの巡で理由が無い・空なら、理由の妥当性は判断できないので要確認の報告に留める（#9）。
# NEEDS_REVIEW: の行（AI が判断して差し戻しうる行）は出さない。
format_case SELF_NO_REASON "FORMAT_WARNING: レビュー 1 巡目: 自己レビューの巡だが「自己レビューにした理由」が書かれておらず、理由の妥当性は確かめていない（未照合）" \
  '!NEEDS_REVIEW:' <<'NOTES'
### レビュー 1 巡目
- 方法: 自己レビュー
- 結果: No findings
- 対応: なし
NOTES

format_case SELF_EMPTY_REASON "FORMAT_WARNING: レビュー 1 巡目: 自己レビューの巡だが「自己レビューにした理由」が書かれておらず、理由の妥当性は確かめていない（未照合）" \
  '!NEEDS_REVIEW:' <<'NOTES'
### レビュー 1 巡目
- 方法: 自己レビュー
- 自己レビューにした理由:
- 結果: No findings
- 対応: なし
NOTES

# 方法が読めない最終巡で取り下げの記載があれば、独立サブエージェントの巡であることも確かめさせる。
format_case METHOD_UNKNOWN_WITHDRAWN "$METHOD_UNREADABLE" \
  "NEEDS_REVIEW: レビュー 1 巡目: 最終巡の P0/P1/P2 1 件のすべてに、レビュー役が取り下げたと指摘ごとに書かれているか（方法が読めないので、独立サブエージェントの巡であることも確かめる）" <<'NOTES'
### レビュー 1 巡目
- 方法: セルフレビュー
- 自己レビューにした理由: 差分が小さい
- 結果: P0 0 / P1 1 / P2 0 / P3 0
- 対応: P1 はレビュー役が取り下げた
NOTES

# 見出しの途中に「巡目」を含むだけの別の記録は、レビュー記録として数えない（実例: TASK-112）。
write_notes NOT_A_ROUND <<'NOTES'
### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: No findings
- 対応: なし

### 分岐一覧の訂正・補足（レビュー1巡目を受けて）
- S3 の訂正: ...
NOTES
check_both "途中に「巡目」を含むだけの見出しは数えない" NOT_A_ROUND 0 "REVIEW_ROUNDS: 1"

echo ""
echo "=== 4b. 必須でない行・順序は検査しない（受入基準 #9） ==="

# 必須は方法と結果の 2 行だけ。理由・対応の欠落、行の順序、項目名で始まらない行は書式の崩れにしない。
write_notes OPTIONAL_MISSING <<'NOTES'
### 引き渡し
- BRANCH: x

### レビュー 1 巡目
- 方法: 独立サブエージェント
- 結果: P0 0 / P1 1 / P2 0 / P3 0
- 対応: 直した。

### レビュー 2 巡目
- 方法: 独立サブエージェント
- 結果: No findings
NOTES
check_both "理由・対応の行が無くても書式の崩れにしない" OPTIONAL_MISSING 0 \
  "REVIEW_ROUNDS: 2" '!FORMAT_WARNING'

write_notes ORDER_STRAY <<'NOTES'
### レビュー 1 巡目
- 結果: No findings
- 指摘: なし
- 自己レビューにした理由: 該当なし
- 方法: 独立サブエージェント
- 対応: なし
NOTES
check_both "対応より前の行の順序と項目名で始まらない行は検査しない" ORDER_STRAY 0 \
  "FINAL_RESULT: No findings" '!FORMAT_WARNING'

# 対応より後の項目行は読まない（対応が最後の行）。結果を対応の後に書けば結果が無いものとして名指しする。
write_notes AFTER_TAIOU <<'NOTES'
### レビュー 1 巡目
- 方法: 独立サブエージェント
- 結果: P0 0 / P1 1 / P2 0 / P3 0
- 対応: 直した
- 結果: No findings
NOTES
check_both "対応より後の項目行は読まず、最終巡の指摘を打ち消さない" AFTER_TAIOU 1 \
  "NOT_CONVERGED: レビュー 1 巡目: P0/P1/P2 が 1 件あり、対応に取り下げの記載が無い" '!FORMAT_WARNING'

# 対応の行が無い記録も最初の空行で終わる。その後に見出し無しで追記された notes の項目行は読まない。
write_notes NO_TAIOU_TRAILING <<'NOTES'
### レビュー 1 巡目
- 方法: 独立サブエージェント
- 結果: P0 0 / P1 1 / P2 0 / P3 0

検証:
- 結果: bash tests/run.sh 全件 pass
- 対応: 取り下げは無し
NOTES
check_both "対応が無くても空行で記録が終わり、後続の notes は読まない" NO_TAIOU_TRAILING 1 \
  "NOT_CONVERGED: レビュー 1 巡目: P0/P1/P2 が 1 件あり、対応に取り下げの記載が無い" '!FORMAT_WARNING'

# 対応を `- ` の箇条書きで続けた場合は、箇条書きを対応の内容として読む（値が空でも、値があっても）。
# 取り下げの記載を捨てて NOT_CONVERGED にしない。
write_notes BULLET_TAIOU <<'NOTES'
### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: P0 0 / P1 1 / P2 0 / P3 0
- 対応:
- P1 → 却下の根拠を渡し、
  レビュー役が取り下げた

検証:
- 別の記録
NOTES
check_both "対応の値が空で箇条書きが続けば、それを対応として読む" BULLET_TAIOU 5 \
  "NEEDS_REVIEW: レビュー 1 巡目: 最終巡の P0/P1/P2 1 件のすべてに、レビュー役が取り下げたと指摘ごとに書かれているか" \
  '!FORMAT_WARNING'

# 空行の後の見出し無しの記録は、対応の箇条書きの続きとして読まない。
write_notes VALUED_TAIOU_BULLETS <<'NOTES'
### レビュー 1 巡目
- 方法: 独立サブエージェント
- 結果: P0 0 / P1 1 / P2 0 / P3 0
- 対応: 以下のとおり。
- P1（…）→ 却下の根拠を渡し、レビュー役が取り下げた
NOTES
check_both "値のある対応に続く箇条書きも対応として読む" VALUED_TAIOU_BULLETS 5 \
  "NEEDS_REVIEW: レビュー 1 巡目: 最終巡の P0/P1/P2 1 件のすべてに、レビュー役が取り下げたと指摘ごとに書かれているか" \
  '!NOT_CONVERGED'

write_notes BULLET_TAIOU_TRAILING <<'NOTES'
### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: P0 0 / P1 1 / P2 0 / P3 0
- 対応:
- P1 を直した

検証:
- レビュー役が取り下げた、とは書いていない別の記録
NOTES
check_both "対応の箇条書きも空行で終わる" BULLET_TAIOU_TRAILING 1 \
  "NOT_CONVERGED: レビュー 1 巡目: P0/P1/P2 が 1 件あり、対応に取り下げの記載が無い"

write_notes BULLET_TAIOU_KEY <<'NOTES'
### レビュー 1 巡目
- 方法: 独立サブエージェント
- 結果: P0 0 / P1 1 / P2 0 / P3 0
- 対応:
- P1 → 直した
- 結果: No findings
NOTES
check_both "対応の箇条書きも項目行で終わり、その項目行は読まない" BULLET_TAIOU_KEY 1 \
  "NOT_CONVERGED: レビュー 1 巡目: P0/P1/P2 が 1 件あり、対応に取り下げの記載が無い" '!FORMAT_WARNING'

echo ""
echo "=== 4c. 差し戻しの根拠は NO_RECORDS と NOT_CONVERGED だけ（受入基準 #8） ==="

# 書式の崩れがあっても、最終巡に指摘が残っていれば NOT_CONVERGED が優先する。崩れは併せて名指しする。
write_notes PRIORITY <<'NOTES'
### レビュー1巡目
- 方法: 独立サブエージェント
- 結果: P0 0 / P1 1 / P2 0 / P3 0
- 対応: 直した。

### レビュー 2 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: P0 0 / P1 1 / P2 0 / P3 0
- 対応: 直した。
NOTES
check_both "書式の崩れより NOT_CONVERGED を優先し、崩れも名指しする" PRIORITY 1 \
  "FORMAT_WARNING: レビュー1巡目: 見出しが「レビュー <巡数> 巡目」の形ではない" \
  "NOT_CONVERGED: レビュー 2 巡目: P0/P1/P2 が 1 件あり、対応に取り下げの記載が無い"

# 方法が読めなくても、件数が読めて取り下げの記載が無ければ NOT_CONVERGED（書式ではなく件数が根拠）。
write_notes NO_METHOD_REMAIN <<'NOTES'
### レビュー 1 巡目
- 結果: P0 0 / P1 0 / P2 1 / P3 0
- 対応: 直した。
NOTES
check_both "方法の行が無くても件数で停止条件を判定する" NO_METHOD_REMAIN 1 \
  "FORMAT_WARNING: レビュー 1 巡目: 「- 方法: 」の行が無い"

# 書式の崩れだけのケースは、差し戻しの根拠になる RESULT（NO_RECORDS・NOT_CONVERGED）にならない。
format4=0
for id in METHOD_UNKNOWN_WITHDRAWN FMT_NO_METHOD FMT_NO_RESULT FMT_FULLWIDTH_COLON FMT_UNREADABLE FMT_WORDS FMT_METHOD FMT_HEADING FMT_HEADING_PREFIX FMT_DUP SELF_NO_REASON SELF_EMPTY_REASON; do
  for ver in 1.48.0 1.53.0; do
    run_in "$STUB_ROOT" env PATH="$STUB_ROOT/bin:$PATH" REVIEW_STUB_FIXTURE_DIR="$STUB_ROOT/$ver" \
      "$CHECK_REVIEW_RECORDS_SCRIPT" "$id"
    if [ "$RUN_EXIT" -eq 1 ] || [ "$RUN_EXIT" -eq 3 ]; then
      format4=1
    fi
  done
done
ASSERT_DETAIL=""
assert "書式の崩れだけのケースは差し戻しの RESULT（NO_RECORDS・NOT_CONVERGED）にならない" [ "$format4" -eq 0 ]

echo ""
echo "=== 5. 要確認（受入基準 #4） ==="

write_notes SELF <<'NOTES'
### 引き渡し
- BRANCH: x

### レビュー 1 巡目
- 方法: 自己レビュー
- 自己レビューにした理由: Agent ツールの呼び出しが 2 回続けて失敗した（1 回目: timeout、2 回目: timeout）
- 結果: P0 0 / P1 1 / P2 0 / P3 0
- 対応: 直した。

### レビュー 2 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: No findings
- 対応: なし
NOTES
check_both "自己レビューの巡は合否を決めずに要確認として名指しする" SELF 5 \
  "NEEDS_REVIEW: レビュー 1 巡目: 自己レビューの巡。自己レビューにした理由が 2 条件のどちらかに当たるか"

write_notes WITHDRAWN <<'NOTES'
### 引き渡し
- BRANCH: x

### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: P0 0 / P1 0 / P2 1 / P3 0
- 対応: P2（ブランチ基点が古い）→ 却下の根拠を渡して再評価させる。

### レビュー 2 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: P0 0 / P1 0 / P2 1 / P3 0
- 対応: P2（ブランチ基点が古い）→ 前巡の却下の根拠を認め、
  レビュー役が取り下げた。
NOTES
check_both "最終巡の取り下げの記載がある指摘は要確認として名指しする（対応の続きの行も読む）" WITHDRAWN 5 \
  "NEEDS_REVIEW: レビュー 2 巡目: 最終巡の P0/P1/P2 1 件のすべてに、レビュー役が取り下げたと指摘ごとに書かれているか"

write_notes SELF_WITHDRAWN <<'NOTES'
### レビュー 1 巡目
- 方法: 自己レビュー
- 自己レビューにした理由: Agent ツールが自分のツール一覧に無い
- 結果: P0 0 / P1 0 / P2 1 / P3 0
- 対応: P2 は妥当でないので取り下げた。
NOTES
check_both "自己レビューの最終巡の取り下げは認めず NOT_CONVERGED" SELF_WITHDRAWN 1 \
  "NOT_CONVERGED: レビュー 1 巡目: 自己レビューの巡で P0/P1/P2 が 1 件ある（自己レビューの巡では取り下げを認めない）" \
  "NEEDS_REVIEW: レビュー 1 巡目: 自己レビューの巡。自己レビューにした理由が 2 条件のどちらかに当たるか"

echo ""
echo "=== 6. 最後の引き渡しより前の巡は使わない（受入基準 #5） ==="

write_notes OLD_BAD <<'NOTES'
### 引き渡し
- BRANCH: 1 回目

### レビュー 1 巡目
- 方法: 自己レビュー
- 自己レビューにした理由: 差分が小さい
- 結果: 指摘は P1 が 1 件
- 対応: 直した。

### 引き渡し
- BRANCH: 2 回目

### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: No findings
- 対応: なし
NOTES
check_both "前回の引き渡しの書式の崩れ・自己レビューは判定に使わない" OLD_BAD 0 "REVIEW_ROUNDS: 1"

write_notes OLD_GOOD <<'NOTES'
### 引き渡し
- BRANCH: 1 回目

### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: No findings
- 対応: なし

### 引き渡し
- BRANCH: 2 回目

### レビュー 1 巡目
- 方法: 独立サブエージェント
- 自己レビューにした理由: 該当なし
- 結果: P0 0 / P1 1 / P2 0 / P3 0
- 対応: 直した。
NOTES
check_both "前回の引き渡しの OK の巡は、今回の最終巡の指摘を打ち消さない" OLD_GOOD 1 "REVIEW_ROUNDS: 1"

echo ""
echo "=== 7. 引数の誤りと backlog の失敗 ==="

run_in "$STUB_ROOT" env PATH="$STUB_ROOT/bin:$PATH" REVIEW_STUB_FIXTURE_DIR="$STUB_ROOT/1.53.0" \
  "$CHECK_REVIEW_RECORDS_SCRIPT"
assert "引数が無ければ ERROR（exit 2）" run_result 2 "RESULT: ERROR"
run_in "$STUB_ROOT" env PATH="$STUB_ROOT/bin:$PATH" REVIEW_STUB_FIXTURE_DIR="$STUB_ROOT/1.53.0" \
  "$CHECK_REVIEW_RECORDS_SCRIPT" TASK-999
assert "backlog task view が失敗すれば ERROR（exit 2）" run_result 2 "RESULT: ERROR"
assert "ERROR の RESULT は最終行" last_lines_are "RESULT: ERROR"

# 導入先では .claude/skills/improvement-dispatch シンボリックリンク経由で呼ばれる。
# 自分の実パスから bin/lib/notes_records.sh を解決できること。
LINK_ROOT="$(mktemp -d)"
register_tmp_cleanup "$LINK_ROOT"
mkdir -p "$LINK_ROOT/.claude/skills"
ln -s "$SOURCE_SKILLS_DIR/improvement-dispatch" "$LINK_ROOT/.claude/skills/improvement-dispatch"
run_in "$STUB_ROOT" env PATH="$STUB_ROOT/bin:$PATH" REVIEW_STUB_FIXTURE_DIR="$STUB_ROOT/1.53.0" \
  "$LINK_ROOT/.claude/skills/improvement-dispatch/scripts/check-review-records" TASK-117
assert "シンボリックリンク経由でも同じ結果になる" run_result 0 "RESULT: OK"

# bin/lib/notes_records.sh を読み込めない配置では、記録が無い（NO_RECORDS）ではなく ERROR になる。
BROKEN_ROOT="$(mktemp -d)"
register_tmp_cleanup "$BROKEN_ROOT"
mkdir -p "$BROKEN_ROOT/claude-code/skills/improvement-dispatch/scripts"
cp "$CHECK_REVIEW_RECORDS_SCRIPT" "$BROKEN_ROOT/claude-code/skills/improvement-dispatch/scripts/"
run_in "$STUB_ROOT" env PATH="$STUB_ROOT/bin:$PATH" REVIEW_STUB_FIXTURE_DIR="$STUB_ROOT/1.53.0" \
  "$BROKEN_ROOT/claude-code/skills/improvement-dispatch/scripts/check-review-records" NOREC
assert "notes_records.sh を読み込めなければ NO_RECORDS ではなく ERROR（exit 2）" run_result 2 "RESULT: ERROR"

echo ""
echo "=== 8. 書式の正本と参照側（受入基準 #6） ==="

if [ -f "$FORMAT_FILE" ]; then
  pass "$FORMAT_REL が存在する"
else
  fail "$FORMAT_REL が存在しない"
fi

# 参照側の SKILL.md に正本を指す Markdown リンクがあり、導入先の配置で正本に届くこと。
# 導入先には claude-code/skills/ が無く、スキルはディレクトリごとに .claude/skills/<スキル名> の
# シンボリックリンクとして置かれる（bin/setup-improvement-loop）。Markdown の相対リンクは
# シンボリックリンクを辿らずに字面で解決されるので、その配置を一時ディレクトリに作り、
# <スキル名>/ 起点で `../` を字面で畳んだパスにファイルがあるかを見る。
# claude-code/skills/ 直下に置いた正本を `../<正本>` で指すと、ここで届かない。
INSTALL_ROOT="$(mktemp -d)"
register_tmp_cleanup "$INSTALL_ROOT"
mkdir -p "$INSTALL_ROOT/.claude/skills"
for skill_dir in "$SOURCE_SKILLS_DIR"/*/; do
  skill_name="$(basename "$skill_dir")"
  ln -s "$SOURCE_SKILLS_DIR/$skill_name" "$INSTALL_ROOT/.claude/skills/$skill_name"
done
check_format_link() {
  local skill="$1" file="$SOURCE_SKILLS_DIR/$1/SKILL.md" target base rest found=0 ok=1
  while IFS= read -r target; do
    target="${target#](}"
    target="${target%)}"
    [ "$(basename "$target")" = "review-record-format.md" ] || continue
    found=1
    base="$INSTALL_ROOT/.claude/skills/$skill"
    rest="$target"
    while [ "${rest#../}" != "$rest" ]; do
      base="$(dirname "$base")"
      rest="${rest#../}"
    done
    if [ ! -f "$base/$rest" ] || ! cmp -s "$base/$rest" "$FORMAT_FILE"; then
      ok=0
    fi
  done < <(grep -oE '\]\([^)]*\)' "$file")
  [ "$found" -eq 1 ] || ok=0
  assert "$skill/SKILL.md から正本へのリンクが導入先の配置（.claude/skills/${skill}）でも正本に届く" [ "$ok" -eq 1 ]
}
ASSERT_DETAIL=""
check_format_link improvement-work
check_format_link improvement-dispatch

# improvement-work 手順 6 の append-notes の例（5 行）が、正本の書式のブロックと一字一句同じこと。
# 書き手の例と正本がずれると、例どおりに書いた記録が照合で書式の崩れとして名指しされる。
WORK_TEMPLATE="$(awk -v q="'" '
  index($0, "--append-notes " q "### レビュー <巡数> 巡目") && !f {
    f = 1; print substr($0, index($0, q) + 1); next
  }
  f {
    line = $0; sub(/^ +/, "", line)
    if (substr(line, length(line) - length(q " --plain") + 1) == q " --plain") {
      print substr(line, 1, length(line) - length(q " --plain")); exit
    }
    print line
  }
' "$WORK_SKILL_FILE")"
FORMAT_TEMPLATE="$(awk '
  /^```text$/ { f = 1; next }
  f && /^```$/ { exit }
  f { print }
' "$FORMAT_FILE")"
ASSERT_DETAIL="improvement-work:
$WORK_TEMPLATE
正本:
$FORMAT_TEMPLATE"
templates_ok=0
if [ -n "$WORK_TEMPLATE" ] && [ "$WORK_TEMPLATE" = "$FORMAT_TEMPLATE" ]; then
  templates_ok=1
fi
assert "improvement-work 手順 6 の記録例が正本の書式と一致する" [ "$templates_ok" -eq 1 ]

finish_tests
