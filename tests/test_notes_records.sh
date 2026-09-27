#!/usr/bin/env bash
# bin/lib/notes_records.sh（notes_section・notes_records）に対するテスト。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=../bin/lib/notes_records.sh
source "$NOTES_RECORDS_SCRIPT"

check_test_dependencies

echo "=== 1. backlog CLI 1.48.0・1.53.0 の task view --plain の出力から notes の記録を取り出す ==="
# notes の周辺の出力は CLI のバージョンで違う。1.48.0 は「Modified files: ...」行をメタデータ部に、
# 1.53.0 は Implementation Notes 節の直後に出す。実行環境の CLI のバージョンによらず両側を毎回
# 検証するため、PATH の先頭に backlog のスタブを置き、各バージョンの実出力を写したフィクスチャを
# 返させて、`backlog task view <ID> --plain | notes_records ...` の形で読む。
#
# フィクスチャは実 CLI の stdout を写したものである（取得日 2026-09-27。File: 行の一時リポジトリの
# パスだけ "<一時リポジトリ>" に置き換えた）。一時リポジトリで次の操作をしてから view した。
#   TASK-1: Description・Implementation Plan・Comments・Final Summary に `### ` 行を書き（Description には
#           「Implementation Notes:」とハイフン 50 個の節見出しと同じ見た目の組も書き）、notes に
#           見出しより前の行、同じ見出しの重複、`### 引き渡し` 2 回、`#### ` 行を追記し、
#           --modified-file を 2 件設定した。
#   TASK-2: `### 引き渡し` を含まない notes だけを追記した。
#   TASK-3: notes を書かず、--modified-file と `### 引き渡し` を含むコメントだけを設定した。
#   TASK-4: notes と --modified-file だけを設定した（Comments・Final Summary 無し）。1.53.0 では
#           Modified files 行と空行が出力の末尾に来る。ID を 4 にそろえるため TASK-1〜3 を先に作った。
# TASK-2 の出力は両バージョンで同じだった。TASK-1・TASK-3・TASK-4 は Modified files 行の位置だけが違う。
#
# スタブは NOTES_STUB_FIXTURE_DIR 配下の view-<ID>.txt を返す（無ければ exit 1）。

STUB_ROOT_NOTES="$(mktemp -d)"
register_tmp_cleanup "$STUB_ROOT_NOTES"
mkdir -p "$STUB_ROOT_NOTES/bin" "$STUB_ROOT_NOTES/1.48.0" "$STUB_ROOT_NOTES/1.53.0"
cat > "$STUB_ROOT_NOTES/bin/backlog" <<'STUB'
#!/usr/bin/env bash
set -u
dir="${NOTES_STUB_FIXTURE_DIR:?}"
if [ "$#" -eq 4 ] && [ "$1 $2 $4" = "task view --plain" ] && [ -f "$dir/view-$3.txt" ]; then
  cat "$dir/view-$3.txt"
  exit 0
fi
printf 'backlog スタブ: 想定外の呼び出し: %s\n' "$*" >&2
exit 1
STUB
chmod +x "$STUB_ROOT_NOTES/bin/backlog"

# backlog CLI 1.48.0 の実出力（TASK-1）。
cat > "$STUB_ROOT_NOTES/1.48.0/view-TASK-1.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-1 - Notes-fixture.md

Task TASK-1 - Notes fixture
==================================================

Status: ○ To Do
Ordinal: 1000
Created: 2026-09-27 13:46 (UTC)
Updated: 2026-09-27 13:46 (UTC)
Modified files: bin/lib/a.sh, tests/b.sh

Description:
--------------------------------------------------
## 現状
### 引き渡し
- description 中の見出し

Implementation Notes:
--------------------------------------------------
### 手順 2 観測記録
- description 中

Acceptance Criteria:
--------------------------------------------------
- [ ] #1 first criterion

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

Implementation Plan:
--------------------------------------------------
1. plan
### 手順 2 観測記録
- plan 中

Implementation Notes:
--------------------------------------------------
見出しより前の行

### 手順 2 観測記録
- commit: old

### 引き渡し
- BRANCH: first

### レビュー 1 巡目
- 結果: P1 1（前回分）

### 手順 2 観測記録
- commit: mid

- 空行を挟んだ本文

### 引き渡し
- BRANCH: second

### レビュー 1 巡目
- 結果: P1 1

### レビュー 2 巡目
- 結果: No findings
#### 小見出しは区切りにしない

### 手順 2 観測記録
- commit: new

Comments:
--------------------------------------------------
#1 - @x - 2026-09-27 13:46 (UTC)
### レビュー 9 巡目
- comment 中

Final Summary:
--------------------------------------------------
### 手順 2 観測記録
- summary 中

VIEW

# backlog CLI 1.48.0 の実出力（TASK-2）。
cat > "$STUB_ROOT_NOTES/1.48.0/view-TASK-2.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-2 - No-handoff.md

Task TASK-2 - No handoff
==================================================

Status: ○ To Do
Ordinal: 2000
Created: 2026-09-27 13:42 (UTC)
Updated: 2026-09-27 13:42 (UTC)

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

Implementation Notes:
--------------------------------------------------
### 手順 2 観測記録
- commit: a

### 手順 2 観測記録
- commit: b

VIEW

# backlog CLI 1.48.0 の実出力（TASK-3）。
cat > "$STUB_ROOT_NOTES/1.48.0/view-TASK-3.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-3 - No-notes.md

Task TASK-3 - No notes
==================================================

Status: ○ To Do
Ordinal: 3000
Created: 2026-09-27 13:42 (UTC)
Updated: 2026-09-27 13:42 (UTC)
Modified files: x.sh

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

Comments:
--------------------------------------------------
#1 - @x - 2026-09-27 13:42 (UTC)
### 引き渡し
- c

VIEW

# backlog CLI 1.48.0 の実出力（TASK-4）。
cat > "$STUB_ROOT_NOTES/1.48.0/view-TASK-4.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-4 - Notes-then-modified-files.md

Task TASK-4 - Notes then modified files
==================================================

Status: ○ To Do
Ordinal: 4000
Created: 2026-09-27 13:52 (UTC)
Updated: 2026-09-27 13:52 (UTC)
Modified files: bin/lib/a.sh

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

Implementation Notes:
--------------------------------------------------
### 引き渡し
- BRANCH: only

### 手順 2 観測記録
- commit: last

VIEW

# backlog CLI 1.53.0 の実出力（TASK-1）。
cat > "$STUB_ROOT_NOTES/1.53.0/view-TASK-1.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-1 - Notes-fixture.md

Task TASK-1 - Notes fixture
==================================================

Status: ○ To Do
Ordinal: 1000
Created: 2026-09-27 13:46 (UTC)
Updated: 2026-09-27 13:46 (UTC)

Description:
--------------------------------------------------
## 現状
### 引き渡し
- description 中の見出し

Implementation Notes:
--------------------------------------------------
### 手順 2 観測記録
- description 中

Acceptance Criteria:
--------------------------------------------------
- [ ] #1 first criterion

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

Implementation Plan:
--------------------------------------------------
1. plan
### 手順 2 観測記録
- plan 中

Implementation Notes:
--------------------------------------------------
見出しより前の行

### 手順 2 観測記録
- commit: old

### 引き渡し
- BRANCH: first

### レビュー 1 巡目
- 結果: P1 1（前回分）

### 手順 2 観測記録
- commit: mid

- 空行を挟んだ本文

### 引き渡し
- BRANCH: second

### レビュー 1 巡目
- 結果: P1 1

### レビュー 2 巡目
- 結果: No findings
#### 小見出しは区切りにしない

### 手順 2 観測記録
- commit: new

Modified files: bin/lib/a.sh, tests/b.sh

Comments:
--------------------------------------------------
#1 - @x - 2026-09-27 13:46 (UTC)
### レビュー 9 巡目
- comment 中

Final Summary:
--------------------------------------------------
### 手順 2 観測記録
- summary 中

VIEW

# backlog CLI 1.53.0 の実出力（TASK-2）。
cat > "$STUB_ROOT_NOTES/1.53.0/view-TASK-2.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-2 - No-handoff.md

Task TASK-2 - No handoff
==================================================

Status: ○ To Do
Ordinal: 2000
Created: 2026-09-27 13:42 (UTC)
Updated: 2026-09-27 13:42 (UTC)

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

Implementation Notes:
--------------------------------------------------
### 手順 2 観測記録
- commit: a

### 手順 2 観測記録
- commit: b

VIEW

# backlog CLI 1.53.0 の実出力（TASK-3）。
cat > "$STUB_ROOT_NOTES/1.53.0/view-TASK-3.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-3 - No-notes.md

Task TASK-3 - No notes
==================================================

Status: ○ To Do
Ordinal: 3000
Created: 2026-09-27 13:42 (UTC)
Updated: 2026-09-27 13:42 (UTC)

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

Modified files: x.sh

Comments:
--------------------------------------------------
#1 - @x - 2026-09-27 13:42 (UTC)
### 引き渡し
- c

VIEW

# backlog CLI 1.53.0 の実出力（TASK-4）。
cat > "$STUB_ROOT_NOTES/1.53.0/view-TASK-4.txt" <<'VIEW'
File: <一時リポジトリ>/.backlog/tasks/task-4 - Notes-then-modified-files.md

Task TASK-4 - Notes then modified files
==================================================

Status: ○ To Do
Ordinal: 4000
Created: 2026-09-27 13:52 (UTC)
Updated: 2026-09-27 13:52 (UTC)

Description:
--------------------------------------------------
No description provided

Acceptance Criteria:
--------------------------------------------------
No acceptance criteria defined

Definition of Done:
--------------------------------------------------
No Definition of Done items defined

Implementation Notes:
--------------------------------------------------
### 引き渡し
- BRANCH: only

### 手順 2 観測記録
- commit: last

Modified files: bin/lib/a.sh

VIEW

# notes_view <バージョン> <ID> <notes_records の引数...>: スタブ経由で view し、notes_records に渡す。
# 結果は RUN_OUT・RUN_EXIT に入れる。UTF-8 のロケールで呼ぶのは、macOS 同梱の awk が
# そのロケールで異なる日本語の見出しを等しいと判定する問題（notes_records.sh の冒頭を参照）を
# 部品の側で防げていることも毎回確かめるためである。en_US.UTF-8 が無い環境では awk が C ロケールに
# 戻るので、この確認は実質的に行われない（macOS には常にある）。
notes_view() {
  local version="$1" id="$2"
  shift 2
  RUN_OUT="$(PATH="$STUB_ROOT_NOTES/bin:$PATH" NOTES_STUB_FIXTURE_DIR="$STUB_ROOT_NOTES/$version" LC_ALL=en_US.UTF-8 \
    bash -c 'set -o pipefail; source "$1"; shift; id="$1"; shift; backlog task view "$id" --plain | notes_records "$@"' \
    _ "$NOTES_RECORDS_SCRIPT" "$id" "$@" 2>&1)"
  RUN_EXIT=$?
  ASSERT_DETAIL="exit ${RUN_EXIT}:
$RUN_OUT"
}

# expect_out <ラベル> <期待する出力の各行...>: 直近の notes_view の終了コードが 0 で、RUN_OUT が
# 引数の行の並びと完全に一致すれば PASS、そうでなければ FAIL を1件計上する。
expect_out() {
  local label="$1"
  shift
  if [ "$RUN_EXIT" -eq 0 ] && [ "$RUN_OUT" = "$(printf '%s\n' "$@")" ]; then
    pass "$label"
  else
    fail "$label
$ASSERT_DETAIL"
  fi
}

for version in 1.48.0 1.53.0; do
  echo ""
  echo "--- backlog CLI $version の出力 ---"

  # --- 1a. AC#1: 同じ見出しを含む notes のすべての記録を、出現順に元の形で取り出す ---
  # 見出しより前の行は記録に含めず、`#### ` 行は区切りにせず本文に含め、本文の途中の空行は残す。
  # 1.53.0 で notes の直後に出る Modified files 行を、最後の記録の本文に含めない。
  notes_view "$version" TASK-1
  expect_out "$version: notes のすべての記録を出現順に取り出す" \
    '### 手順 2 観測記録' '- commit: old' \
    '### 引き渡し' '- BRANCH: first' \
    '### レビュー 1 巡目' '- 結果: P1 1（前回分）' \
    '### 手順 2 観測記録' '- commit: mid' '' '- 空行を挟んだ本文' \
    '### 引き渡し' '- BRANCH: second' \
    '### レビュー 1 巡目' '- 結果: P1 1' \
    '### レビュー 2 巡目' '- 結果: No findings' '#### 小見出しは区切りにしない' \
    '### 手順 2 観測記録' '- commit: new'

  # --- 1b. AC#1: 見出しで絞ると、同じ見出しの記録を出現順にすべて取り出す ---
  notes_view "$version" TASK-1 --heading '手順 2 観測記録'
  expect_out "$version: 同じ見出しの記録 3 件を出現順にすべて取り出す" \
    '### 手順 2 観測記録' '- commit: old' \
    '### 手順 2 観測記録' '- commit: mid' '' '- 空行を挟んだ本文' \
    '### 手順 2 観測記録' '- commit: new'

  # --- 1c. AC#1: --last で最後の 1 件だけを選ぶ ---
  notes_view "$version" TASK-1 --heading '手順 2 観測記録' --last
  expect_out "$version: 同じ見出しの記録のうち最後の 1 件だけを選ぶ" \
    '### 手順 2 観測記録' '- commit: new'

  # --- 1c2. AC#1: --heading を付けない --last は notes 全体の最後の記録を選ぶ ---
  notes_view "$version" TASK-1 --last
  expect_out "$version: 見出しで絞らない --last は notes 全体の最後の記録を選ぶ" \
    '### 手順 2 観測記録' '- commit: new'

  # --- 1d. AC#2: 最後の `### 引き渡し` より後の記録だけに絞る（`### 引き渡し` 自身は含めない） ---
  notes_view "$version" TASK-1 --after-last-handoff
  expect_out "$version: 最後の ### 引き渡し より後の記録だけを取り出す" \
    '### レビュー 1 巡目' '- 結果: P1 1' \
    '### レビュー 2 巡目' '- 結果: No findings' '#### 小見出しは区切りにしない' \
    '### 手順 2 観測記録' '- commit: new'

  # --- 1e. AC#2: 引き渡し以降への絞り込みの後で見出しを絞るので、前回分の同じ見出しは出さない ---
  notes_view "$version" TASK-1 --after-last-handoff --heading 'レビュー 1 巡目'
  expect_out "$version: 前回の引き渡し分の同じ見出しの記録を除いて取り出す" \
    '### レビュー 1 巡目' '- 結果: P1 1'

  # --- 1f. AC#2: `### 引き渡し` が無い notes では notes 全体が対象になる ---
  notes_view "$version" TASK-2 --after-last-handoff
  expect_out "$version: ### 引き渡し が無い notes では notes 全体を対象にする" \
    '### 手順 2 観測記録' '- commit: a' \
    '### 手順 2 観測記録' '- commit: b'
  notes_view "$version" TASK-2 --after-last-handoff --heading '手順 2 観測記録' --last
  expect_out "$version: ### 引き渡し が無い notes でも最後の 1 件を選べる" \
    '### 手順 2 観測記録' '- commit: b'

  # --- 1g. AC#3: Description・Plan・Comments・Final Summary の中の `### ` 行を記録として取り出さない ---
  # 1a の完全一致でも確かめているが、どの節から漏れたのかを FAIL の表示で分かるようにする。
  notes_view "$version" TASK-1
  for leaked in 'description 中' 'plan 中' 'レビュー 9 巡目' 'comment 中' 'summary 中' 'Modified files'; do
    assert_not "$version: notes 節の外の「${leaked}」を記録に含めない" has_text "$RUN_OUT" "$leaked"
  done

  # --- 1h. AC#3: notes が無ければ、Comments の中に `### 引き渡し` があっても何も出さない ---
  notes_view "$version" TASK-3
  expect_out "$version: notes が無いタスクでは何も出さない" ''
  notes_view "$version" TASK-3 --after-last-handoff
  expect_out "$version: notes が無いタスクでは --after-last-handoff でも何も出さない" ''

  # --- 1h2. notes の後に Modified files 行だけが続き、Comments・Final Summary が無い出力でも
  # Modified files 行を最後の記録の本文に含めない（1.53.0 ではこの行が出力の末尾に来る） ---
  notes_view "$version" TASK-4 --after-last-handoff --heading '手順 2 観測記録' --last
  expect_out "$version: 出力の末尾の Modified files 行を最後の記録の本文に含めない" \
    '### 手順 2 観測記録' '- commit: last'

  # --- 1i. notes_section は notes 節の本文だけを出す（見出しより前の行を含み、Modified files 行を含まない） ---
  RUN_OUT="$(NOTES_STUB_FIXTURE_DIR="$STUB_ROOT_NOTES/$version" "$STUB_ROOT_NOTES/bin/backlog" task view TASK-1 --plain | notes_section)"
  RUN_EXIT=$?
  ASSERT_DETAIL="exit ${RUN_EXIT}:
$RUN_OUT"
  assert "$version: notes_section の 1 行目は notes の先頭行" first_line_is '見出しより前の行'
  assert "$version: notes_section の末尾は最後の記録の本文で、Modified files 行を含まない" last_lines_are \
    '### 手順 2 観測記録' '- commit: new'
done

echo ""
echo "=== 2. 引数の誤り ==="
# 不明な引数や値の無い --heading は、黙って全件を返さずに終了コード 2 で失敗する。
notes_view 1.53.0 TASK-1 --heading
assert "--heading の値が無ければ終了コード 2" run_result_text 2 '--heading には見出しを渡す'
notes_view 1.53.0 TASK-1 --bogus
assert "不明な引数は終了コード 2" run_result_text 2 '不明な引数: --bogus'

finish_tests
