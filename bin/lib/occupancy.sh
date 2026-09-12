# occupancy_write_file() の唯一の定義。実行されず、必ず source される前提の
# ためシバンは付けない。
#
# 占有記録ファイル（.worktree-occupancy）を丸ごと上書きする（追記しない）。
# TASK_ID・ASSIGNED_AT（ISO8601, UTC）・ASSIGNED_AT_EPOCH（UNIX epoch秒）の3行を書く。
# ASSIGNED_AT_EPOCH を併記するのは、ISO8601 文字列の解析が GNU date と BSD date で
# 割れるためで、鮮度の数値比較にはそちらを使う（読み手は check-progress-recovery）。
#
# 呼び出し元の責務: 書き込み先のワークツリーが実在し、task_id が指す先と一致する
# ことの確認（＝存在しないワークツリーの占有記録を作らない、他タスクの占有記録を
# 誤って上書きしない）。この関数自身はファイルパスと task_id を渡された通りに
# 書くだけで、その妥当性は検証しない。
#
# 引数: <occupancy_file_path> <task_id>
occupancy_write_file() {
  local occupancy_file="$1"
  local task_id="$2"
  local assigned_at assigned_at_epoch
  assigned_at="$(date -u +%FT%TZ)"
  assigned_at_epoch="$(date -u +%s)"
  {
    printf 'TASK_ID=%s\n' "$task_id"
    printf 'ASSIGNED_AT=%s\n' "$assigned_at"
    printf 'ASSIGNED_AT_EPOCH=%s\n' "$assigned_at_epoch"
  } > "$occupancy_file"
}
