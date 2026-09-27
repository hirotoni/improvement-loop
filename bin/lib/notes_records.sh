# notes_section() と notes_records() の唯一の定義。実行されず、必ず source される
# 前提のためシバンは付けない。
#
# `backlog task view <ID> --plain` の出力から、Implementation Notes 節に `### ` 見出しで
# 残した記録（`### 引き渡し`・`### 手順 2 観測記録`・`### レビュー <巡数> 巡目` 等）を
# 取り出す。notes を読むスクリプトはこの 2 関数だけを使い、節の境界や見出しの区切りを
# 各自で解析しない（別々に実装すると、片方だけを直したときにもう片方が無音で食い違った結果を返す）。
#
# 入力の前提（backlog CLI 1.48.0 と 1.53.0 の実出力で確認した。tests/test_notes_records.sh）:
# - 本文の節は Description / Acceptance Criteria / Definition of Done / Implementation Plan /
#   Implementation Notes / Comments / Final Summary の順に出る。節の見出しは「<名前>:」の行と
#   ハイフン 50 個の行の組で、各節の本文の後には空行が 1 行入る。
# - Acceptance Criteria 節は項目が無くても（"No acceptance criteria defined" として）必ず出る。
#   notes 節はこの節見出しより後だけで探すので、この前提は必須である。崩れると notes 節を
#   見つけられず、記録が無い場合と同じく何も出さない。
# - notes 節の周辺での版の差は Modified files の位置だけである（Dependencies 行と Dependency Graph 節の差は
#   Description より前なので、この解析には関係しない）。1.48.0 はメタデータ部（Description より前）に
#   「Modified files: ...」行を出す。1.53.0 は Implementation Notes 節の直後（空行の後、
#   Comments 節の前）に「Modified files: ...」行と空行を出す。
#
# 解析しないもの（既知の限界）:
# - Implementation Plan の本文に「Implementation Notes:」とハイフン 50 個の組がそのまま
#   書かれていると、そこを notes 節の始まりとみなす。Description の本文の同じ組は拾わないが、
#   Description に「Acceptance Criteria:」の組が先に書かれていれば同じく拾う。
# - notes の本文に、空行に続けて Comments / Final Summary の節見出しの組や、1.53.0 の
#   Modified files 行と同じ並びが書かれていると、そこを notes 節の終わりとみなす。
# - コードフェンスは解釈しない。フェンスの中の `### ` 行も見出しとして扱う。
#
# awk は必ず LC_ALL=C で動かす。macOS 同梱の awk（20200816 版）は UTF-8 のロケールで
# 文字列の == を照合順序で比べ、「レビュー 2 巡目」と「手順 2 観測記録」のような
# 異なる日本語の文字列を等しいと判定する。C ロケールならバイト列で比べる。

# notes_section
#   標準入力: task view --plain の出力。
#   標準出力: Implementation Notes 節の本文（節見出しの 2 行と、末尾の空行を除く）。
#   notes 節が無ければ何も出さない。終了コードは常に 0。
#
# 節の始まりは、Acceptance Criteria 節の見出しより後に現れる最初の「Implementation Notes:」
# 見出しとする。利用者の自由記述である Description の中の同じ見た目の行を拾わないためである
# （Acceptance Criteria 節は CLI が項目から生成する）。
# 節の終わりは、空行の直後に来る次のどちらか（無ければ出力の末尾）とする。
# - Comments / Final Summary の節見出し。
# - 「Modified files: 」で始まり、空行が続き、その後が出力の末尾か Comments / Final Summary の
#   節見出しである行（1.53.0）。
notes_section() {
  LC_ALL=C awk '
    { line[NR] = $0 }
    function is_header(i, name) {
      return i < NR && line[i] == name && line[i + 1] == sep
    }
    function is_tail_header(i) {
      return is_header(i, "Comments:") || is_header(i, "Final Summary:")
    }
    END {
      sep = "--------------------------------------------------"
      seen_ac = 0
      start = 0
      for (i = 1; i < NR; i++) {
        if (!seen_ac) {
          if (is_header(i, "Acceptance Criteria:")) { seen_ac = 1 }
          continue
        }
        if (is_header(i, "Implementation Notes:")) { start = i + 2; break }
      }
      if (!start) { exit }
      stop = NR + 1
      for (i = start + 1; i <= NR; i++) {
        if (line[i - 1] != "") { continue }
        if (is_tail_header(i)) { stop = i; break }
        if (index(line[i], "Modified files: ") == 1 && i < NR && line[i + 1] == "" \
            && (i + 2 > NR || is_tail_header(i + 2))) { stop = i; break }
      }
      last = stop - 1
      while (last >= start && line[last] == "") { last-- }
      for (i = start; i <= last; i++) { print line[i] }
    }
  '
}

# notes_records [--after-last-handoff] [--heading <見出し>] [--last]
#   標準入力: task view --plain の出力。
#   標準出力: notes 節の記録を出現順に、元の形のまま出す。記録は「### <見出し>」の行と、
#   次の `### ` 行（または notes の末尾）までの本文からなる。本文の末尾の空行は除く。
#   本文に `### ` で始まる行は無いので、呼び出し側は `### ` 行で記録を区切って読める。
#   notes の最初の `### ` 行より前の行は、どの記録にも属さないので出さない。
#   `#### ` など `### ` で始まらない行は見出しとして扱わない（本文に含める）。
#   該当する記録が無ければ何も出さない。終了コードは 0（引数の誤りだけ 2）。
#
#   --after-last-handoff  最後の `### 引き渡し` より後の記録だけを対象にする（`### 引き渡し`
#                         自身は含めない）。`### 引き渡し` が無ければ notes 全体が対象になる。
#   --heading <見出し>     見出しが一致する記録だけを対象にする。`### ` の後ろ（行末の空白を
#                         除く）との完全一致で比べる。
#   --last                対象のうち最後の 1 件だけを出す。
#   絞り込みは --after-last-handoff、--heading、--last の順に適用する。
#
#   例: 今回の引き渡し以降の最後の観測記録の本文だけを得る。
#     backlog task view TASK-1 --plain \
#       | notes_records --after-last-handoff --heading '手順 2 観測記録' --last | tail -n +2
notes_records() {
  local after_handoff=0 has_heading=0 heading="" only_last=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --after-last-handoff) after_handoff=1 ;;
      --heading)
        if [ "$#" -lt 2 ]; then
          echo "notes_records: --heading には見出しを渡す" >&2
          return 2
        fi
        has_heading=1
        heading="$2"
        shift
        ;;
      --last) only_last=1 ;;
      *)
        printf 'notes_records: 不明な引数: %s\n' "$1" >&2
        return 2
        ;;
    esac
    shift
  done
  # 見出しは awk -v ではなく環境変数で渡す。-v はバックスラッシュをエスケープとして解釈するためである。
  notes_section | NOTES_RECORDS_HEADING="$heading" LC_ALL=C awk \
    -v after_handoff="$after_handoff" -v has_heading="$has_heading" -v only_last="$only_last" '
    function title_of(s) {
      s = substr(s, 5)
      sub(/[ \t]+$/, "", s)
      return s
    }
    /^### / {
      n++
      head[n] = $0
      title[n] = title_of($0)
      body_len[n] = 0
      next
    }
    n > 0 {
      body_len[n]++
      body[n, body_len[n]] = $0
    }
    END {
      heading = ENVIRON["NOTES_RECORDS_HEADING"]
      first = 1
      if (after_handoff) {
        for (k = 1; k <= n; k++) {
          if (title[k] == "引き渡し") { first = k + 1 }
        }
      }
      count = 0
      for (k = first; k <= n; k++) {
        if (has_heading && title[k] != heading) { continue }
        count++
        picked[count] = k
      }
      from = 1
      if (only_last) { from = count }
      for (j = from; j <= count; j++) {
        if (j < 1) { continue }
        k = picked[j]
        print head[k]
        m = body_len[k]
        while (m > 0 && body[k, m] == "") { m-- }
        for (x = 1; x <= m; x++) { print body[k, x] }
      }
    }
  '
}
