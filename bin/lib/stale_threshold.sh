# IMPROVEMENT_STALE_THRESHOLD_SECONDS の唯一の定義。実行されず、必ず source される
# 前提のためシバンは付けない。
#
# improvement-dispatch 手順 2 が「引き渡し先が動いていない」とみなすまでの秒数（30 分）。
# 次の 2 か所がこの値を使う。値を変えるときはここだけを変える。
# - observe-progress: 手順 2 観測記録から状態が変わらないまま経過した時間が、この値以上なら
#   復旧診断（check-progress-recovery）を呼ぶべきと判定する。
# - check-progress-recovery: 占有記録（.worktree-occupancy）の ASSIGNED_AT_EPOCH からの経過が
#   この値未満なら OCCUPANCY_FRESH: true とする。
# 2 つは測る起点が違う（前者は最後に状態が変化したのを観測した時刻、後者は最後の引き渡し・
# ハートビート）。同じ値を使うのは、根拠が同じ手順 7 の起動間隔（概ね 20〜30 分）だからである。
# 根拠の説明の正本は claude-code/skills/improvement-dispatch/SKILL.md 手順 2。
IMPROVEMENT_STALE_THRESHOLD_SECONDS=1800
