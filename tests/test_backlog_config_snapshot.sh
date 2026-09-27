#!/usr/bin/env bash
# claude-code/skills/improvement-dispatch/scripts/backlog-config-snapshot に対するテスト（TASK-117）。
# 一時リポジトリの中に実ディレクトリの .backlog を置き、ワークツリーの .backlog を
# それへのシンボリックリンクにして、2026-09-27 の事故（ワークツリー直下から
# リンク越しに共有 config.yml を上書きした）を再現したうえで、検知と復元を確かめる。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 17. claude-code/skills/improvement-dispatch/scripts/backlog-config-snapshot の動作確認 ==="

BC_REPO="$(mktemp -d)"
# macOS の mktemp -d はシンボリックリンク経由のパスを返す。スクリプトが出すパスは
# git worktree list 由来の実パスなので、ここでも正規化しておく。
BC_REPO="$(cd "$BC_REPO" && pwd -P)"
BC_WORKTREE="${BC_REPO}-wt"
register_tmp_cleanup "$BC_REPO" "$BC_WORKTREE"

BC_TASK_ID="task-117-snapshot-test"
(cd "$BC_REPO" && git init -q -b main && git commit -q --allow-empty -m init \
  && git worktree add -q -b "improvement/$BC_TASK_ID" "$BC_WORKTREE" main)
mkdir -p "$BC_REPO/.backlog"
echo ".backlog" >> "$BC_REPO/.git/info/exclude"
BC_CONFIG="$BC_REPO/.backlog/config.yml"
BC_GOOD_CONTENT='project_name: "real"
statuses: ["Proposed", "To Do", "In Progress", "In Review", "Approved", "Done"]'
printf '%s\n' "$BC_GOOD_CONTENT" > "$BC_CONFIG"
chmod 600 "$BC_CONFIG"
ln -s "$BC_REPO/.backlog" "$BC_WORKTREE/.backlog"
BC_SNAPSHOT="$BC_REPO/.git/improvement-loop/backlog-config-snapshots/$BC_TASK_ID.yml"

bc_run() {
  run_in "$1" "$BACKLOG_CONFIG_SNAPSHOT_SCRIPT" "${@:2}"
}

echo ""
echo "--- 17a. save: 共有 config.yml を git-common-dir の中へ複製する ---"
bc_run "$BC_REPO" save "$BC_TASK_ID"
assert "17a: save は RESULT: SAVED（exit 0）で、CONFIG= と SNAPSHOT= を出す" \
  run_result 0 "CONFIG=$BC_CONFIG" "SNAPSHOT=$BC_SNAPSHOT" "RESULT: SAVED"
assert "17a: 複製の内容が共有 config.yml と一致する" cmp -s "$BC_SNAPSHOT" "$BC_CONFIG"
assert "17a: 複製を置いても git status が汚れない" [ -z "$(git -C "$BC_REPO" status --porcelain)" ]

echo ""
echo "--- 17b. check: 変更が無ければ RESULT: OK ---"
bc_run "$BC_WORKTREE" check "$BC_TASK_ID"
assert "17b: ワークツリーから check しても、変更が無ければ RESULT: OK（exit 0）" run_result 0 "RESULT: OK"

echo ""
echo "--- 17c. 事故の再現: ワークツリー直下からリンク越しに上書きすると CHANGED で検知する ---"
(cd "$BC_WORKTREE" || exit 1; printf 'project_name: "p"\nstatuses: ["To Do", "Done"]\n' > .backlog/config.yml)
bc_run "$BC_WORKTREE" check "$BC_TASK_ID"
assert "17c: ワークツリーからの check が RESULT: CHANGED（exit 1）を返す" run_result 1 "RESULT: CHANGED"
assert "17c: 差分（書き換わった行）が出力に含まれる" has_text "$RUN_OUT" 'project_name: "p"'
assert "17c: RESTORE_COMMAND= に restore の呼び出しが出る" has_text "$RUN_OUT" "restore $BC_TASK_ID"
bc_run "$BC_REPO" check "$BC_TASK_ID"
assert "17c: メインの作業木からの check（dispatch の完了検証）でも RESULT: CHANGED（exit 1）" \
  run_result 1 "RESULT: CHANGED"
assert "17c: check は共有 config.yml を書き換えない" has_line "$(cat "$BC_CONFIG")" 'project_name: "p"'

echo ""
echo "--- 17d. restore: 複製の内容へ戻し、上書き前の内容を退避する ---"
bc_run "$BC_REPO" restore "$BC_TASK_ID"
assert "17d: restore は RESULT: RESTORED（exit 0）で BACKUP= に .before-restore.<時刻> の退避先を出す" \
  run_result_text 0 "BACKUP=$BC_SNAPSHOT.before-restore." "RESULT: RESTORED"
BC_BACKUP="$(sed -n 's/^BACKUP=//p' <<<"$RUN_OUT")"
assert "17d: 共有 config.yml が引き渡し時点の内容に戻る" [ "$(cat "$BC_CONFIG")" = "$BC_GOOD_CONTENT" ]
assert "17d: 上書き前の（壊れた）内容が .before-restore に退避される" \
  has_line "$(cat "$BC_BACKUP" 2>/dev/null)" 'project_name: "p"'
assert "17d: restore は config.yml のパーミッションを変えない（0600 のまま）" \
  [ -z "$(find "$BC_CONFIG" -perm 600 -prune -o -print)" ]
bc_run "$BC_WORKTREE" check "$BC_TASK_ID"
assert "17d: restore 後の check は RESULT: OK" run_result 0 "RESULT: OK"
bc_run "$BC_REPO" restore "$BC_TASK_ID"
assert "17d: 既に一致していれば restore は何もせず RESULT: OK" run_result 0 "RESULT: OK"

echo ""
echo "--- 17e. config.yml が消えた場合も CHANGED で検知し、restore で作り直せる ---"
rm -f "$BC_CONFIG"
bc_run "$BC_WORKTREE" check "$BC_TASK_ID"
assert "17e: config.yml が消えると RESULT: CHANGED（exit 1）" run_result 1 "RESULT: CHANGED"
bc_run "$BC_REPO" restore "$BC_TASK_ID"
assert "17e: restore が RESULT: RESTORED（exit 0）" run_result 0 "RESULT: RESTORED"
assert "17e: 消えた config.yml が複製から作り直される" [ "$(cat "$BC_CONFIG" 2>/dev/null)" = "$BC_GOOD_CONTENT" ]

echo ""
echo "--- 17f. ワークツリーの .backlog が実ディレクトリに置き換わっていても共有の実体を見る ---"
rm "$BC_WORKTREE/.backlog"
mkdir "$BC_WORKTREE/.backlog"
printf 'project_name: "local"\n' > "$BC_WORKTREE/.backlog/config.yml"
bc_run "$BC_WORKTREE" check "$BC_TASK_ID"
assert "17f: 比較対象はメインの作業木の config.yml（CONFIG= が本体を指し、RESULT: OK）" \
  run_result 0 "CONFIG=$BC_CONFIG" "RESULT: OK"
rm -rf "$BC_WORKTREE/.backlog"
ln -s "$BC_REPO/.backlog" "$BC_WORKTREE/.backlog"

echo ""
echo "--- 17g. 再引き渡し: 内容の違う既存の複製は save で上書きせず、accept でだけ取り直す ---"
(cd "$BC_WORKTREE" || exit 1; printf 'project_name: "p"\n' > .backlog/config.yml)
bc_run "$BC_REPO" save "$BC_TASK_ID"
assert "17g: 内容の違う既存の複製があると save は RESULT: KEPT_EXISTING（exit 0）" run_result 0 "RESULT: KEPT_EXISTING"
assert "17g: KEPT_EXISTING のとき複製は引き渡し時点の内容のまま" [ "$(cat "$BC_SNAPSHOT")" = "$BC_GOOD_CONTENT" ]
bc_run "$BC_REPO" check "$BC_TASK_ID"
assert "17g: 再引き渡し後も check が改変を CHANGED として検知し続ける" run_result 1 "RESULT: CHANGED"
bc_run "$BC_REPO" accept "$BC_TASK_ID"
assert "17g: accept は RESULT: SAVED（exit 0）" run_result 0 "RESULT: SAVED"
assert "17g: accept で複製が現在の内容に取り直される" has_line "$(cat "$BC_SNAPSHOT")" 'project_name: "p"'
bc_run "$BC_REPO" check "$BC_TASK_ID"
assert "17g: accept 後の check は RESULT: OK" run_result 0 "RESULT: OK"
bc_run "$BC_REPO" save "$BC_TASK_ID"
assert "17g: 同じ内容の複製がある save は RESULT: SAVED" run_result 0 "RESULT: SAVED"
printf '%s\n' "$BC_GOOD_CONTENT" > "$BC_CONFIG"
bc_run "$BC_REPO" accept "$BC_TASK_ID"

echo ""
echo "--- 17h. RESTORE_COMMAND はメインの作業木の .claude/skills 経由の実体を優先する ---"
mkdir -p "$BC_REPO/.claude/skills"
ln -s "$(dirname "$(dirname "$BACKLOG_CONFIG_SNAPSHOT_SCRIPT")")" "$BC_REPO/.claude/skills/improvement-dispatch"
printf 'project_name: "p"\n' > "$BC_CONFIG"
bc_run "$BC_WORKTREE" check "$BC_TASK_ID"
assert "17h: RESTORE_COMMAND がメインの作業木の .claude/skills 配下の実体を指す" \
  has_text "$RUN_OUT" "$BC_REPO/.claude/skills/improvement-dispatch/scripts/backlog-config-snapshot restore $BC_TASK_ID"
printf '%s\n' "$BC_GOOD_CONTENT" > "$BC_CONFIG"
rm -rf "$BC_REPO/.claude"

echo ""
echo "--- 17i. 複製が無い・config.yml が無い・引数不正 ---"
bc_run "$BC_REPO" check "task-999-no-snapshot"
assert "17i: 複製が無いタスクの check は RESULT: NO_SNAPSHOT（exit 3）" run_result 3 "RESULT: NO_SNAPSHOT"
bc_run "$BC_REPO" restore "task-999-no-snapshot"
assert "17i: 複製が無いタスクの restore は RESULT: NO_SNAPSHOT（exit 3）で何も書かない" \
  run_result 3 "RESULT: NO_SNAPSHOT"
assert "17i: 複製が無い restore の後も config.yml は変わらない" [ "$(cat "$BC_CONFIG")" = "$BC_GOOD_CONTENT" ]

BC_NOCONFIG_REPO="$(mktemp -d)"
register_tmp_cleanup "$BC_NOCONFIG_REPO"
(cd "$BC_NOCONFIG_REPO" && git init -q -b main && git commit -q --allow-empty -m init)
bc_run "$BC_NOCONFIG_REPO" save "$BC_TASK_ID"
assert "17i: config.yml が無ければ save は RESULT: NO_CONFIG（exit 0）で複製を作らない" \
  run_result 0 "RESULT: NO_CONFIG"
assert "17i: NO_CONFIG のとき複製ファイルは作られない" \
  [ ! -e "$BC_NOCONFIG_REPO/.git/improvement-loop/backlog-config-snapshots/$BC_TASK_ID.yml" ]

bc_run "$BC_REPO" check "TASK-117"
assert "17i: task-id の形式が不正なら RESULT: ERROR（exit 2）" run_result 2 "RESULT: ERROR"
bc_run "$BC_REPO" overwrite "$BC_TASK_ID"
assert "17i: 不明なサブコマンドは RESULT: ERROR（exit 2）" run_result 2 "RESULT: ERROR"
bc_run "$BC_REPO" check
assert "17i: 引数が足りなければ RESULT: ERROR（exit 2）" run_result 2 "RESULT: ERROR"
BC_NOT_REPO="$(mktemp -d)"
register_tmp_cleanup "$BC_NOT_REPO"
bc_run "$BC_NOT_REPO" check "$BC_TASK_ID"
assert "17i: git リポジトリの外では RESULT: ERROR（exit 2）" run_result 2 "RESULT: ERROR"

finish_tests
