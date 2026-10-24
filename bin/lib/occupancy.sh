# occupancy_write_file() と occupancy_read_epoch() の唯一の定義。実行されず、必ず
# source される前提のためシバンは付けない。
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

# 占有記録ファイルから ASSIGNED_AT_EPOCH の値だけを読む。読み手は check-progress-recovery
# （鮮度の判定）と observe-progress（前回の観測からハートビートが進んだかの比較）。
# ファイル全体を source しない（外部が書いたファイルを任意のシェルコードとして実行しないため）。
# ISO8601 の ASSIGNED_AT は GNU date と BSD date で解釈が割れるので読まない。
#
# 引数: <occupancy_file_path>
# 標準出力: ASSIGNED_AT_EPOCH の値（10 進の数字列）。
# 終了コード: 0 = 読めた。1 = ファイルが無い、行が無い、値が数字列でない（何も出さない）。
occupancy_read_epoch() {
  local occupancy_file="$1"
  local epoch
  [ -f "$occupancy_file" ] || return 1
  epoch="$(grep -m1 -E '^ASSIGNED_AT_EPOCH=' "$occupancy_file" 2>/dev/null | sed -E 's/^ASSIGNED_AT_EPOCH=//')"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$epoch"
}
