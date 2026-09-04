# 完了・アーカイブ済みタスクの照合手順（正本）

backlog CLI から見えなくなったタスク（完了済み・アーカイブ済み）を、起票前の重複照合と
観点ラベルの件数集計に乗せるための手順の正本。
`improvement-scout` / `improvement-scout-major` / `improvement-add` の各 `SKILL.md` は、
この手順を手元に複製せず、このファイルを単一情報源として参照する。
3ファイルを直接編集する前に必ずこのファイルを更新すること。

## なぜ必要か

`backlog task list` / `backlog search` / `backlog task view` は `.backlog/tasks/` しか見ない。
`backlog task complete` で `.backlog/completed/` へ移ったタスクと、`backlog task archive` で
`.backlog/archive/tasks/` へ移ったタスクは、これらのコマンドの結果に一切現れない
（`backlog task view TASK-<n> --plain` すら `Task TASK-<n> not found.` を返す）。
CLI 1.48.0 の `--help` を確認したが、完了・アーカイブ済みを対象に含めるオプションは無い。

ループを回すほど完了済みが増えるので、CLI だけに頼った照合は時間とともに劣化する。
一度直した内容の再起票と、既に消化した観点の再選択を止められない。
したがって CLI の結果を、下記のファイル走査で補う。

`backlog milestone list --plain` は Active と Completed の両方を出すので、milestone は完了では
消えない。消えるのは `.backlog/archive/milestones/` へ移したときだけである。

**読み取りに限った手当てである。** タスクの追加・更新・アーカイブは従来どおりすべて
`backlog` CLI 経由で行う。`.backlog/` 配下の md を直接編集しない。

## 共通の前置き

下の各コマンドは、この前置きと同じシェル呼び出しの中で実行する
（1 回の Bash 呼び出しに前置きと本体をまとめて書く）。

```bash
BACKLOG_DIR=".backlog"
[ -d "$BACKLOG_DIR" ] || BACKLOG_DIR="backlog"

HIDDEN_DIRS=()
for d in "$BACKLOG_DIR/completed" "$BACKLOG_DIR/archive/tasks" "$BACKLOG_DIR/archive/milestones"; do
  [ -d "$d" ] && HIDDEN_DIRS+=("$d")
done
echo "走査対象: ${HIDDEN_DIRS[*]:-（無し）}"
```

`HIDDEN_DIRS` が空なら、CLI から見えないタスクはまだ 1 件も無い。以降の走査は不要である。

以下の手順 1・2 は、該当が無ければ何も出力せず終了コード 1 で終わる。grep の仕様であり異常ではない。

## 1. キーワードで照合する

`backlog search "<キーワード>" --plain` と対にして実行する。

```bash
[ "${#HIDDEN_DIRS[@]}" -gt 0 ] && grep -ril -- "<キーワード>" "${HIDDEN_DIRS[@]}"
```

ファイル名にタイトルがそのまま入っているので、ヒットしたパスの一覧だけで概ね判断できる。
中身を読むときは `cat` でそのファイルを開く（`backlog task view` では引けない）。

## 2. パスで照合する（`--modified-file` 相当）

`backlog search --modified-file <対象パス> --plain` と対にして実行する。

```bash
[ "${#HIDDEN_DIRS[@]}" -gt 0 ] && grep -rlE "^[[:space:]]*-[[:space:]]*'?<対象パス>'?[[:space:]]*$" "${HIDDEN_DIRS[@]}"
```

正規表現は frontmatter の `modified_files:` 配下の行に一致するよう、行全体を固定している。
パスをそのまま `grep -F` で探すと、Implementation Notes の検証コマンド（`bash tests/run.sh` 等）に
片端から当たり、ほぼ全タスクがヒットして使い物にならない。
本文まで含めて広く見たいときは、パスを手順 1 のキーワードとして渡す。

## 3. 観点ラベルの件数を集計する（`improvement-scout` 手順 2）

`viewpoint:<slug>` ラベルの起票実績を数える。`backlog task list --labels` は使わない。
CLI 側とファイル側で数え方が分かれると、二重計上と数え漏れの検証が要るためである。
`.backlog/tasks/` も含めて、すべて同じ走査で数える。

```bash
for v in $(grep -oE '^## [a-z-]+' .claude/skills/improvement-scout/viewpoints.md | cut -d' ' -f2); do
  printf '%s\t%s\n' "$v" \
    "$(grep -rlE "^[[:space:]]*-[[:space:]]*'?viewpoint:$v'?[[:space:]]*$" \
        "$BACKLOG_DIR/tasks" "${HIDDEN_DIRS[@]}" 2>/dev/null | wc -l | tr -d ' ')"
done
```

- 数えるのはファイル数（`grep -l`）であり、出現回数ではない。1 タスク＝1 件にする。
- 数えるのはラベル行であり、タスク ID ではない。`.backlog/config.yml` の `task_prefix` を
  変えた導入先（ID が `ISSUE-1` になる等）でも同じ数え方が効く。
- 正規表現は frontmatter の `labels:` 配下の行（`  - 'viewpoint:<slug>'`。値にコロンを含むため
  クォートされる）に一致するよう、行全体を固定している。本文中に `viewpoint:<slug>` と書いた
  タスクがあり、緩い grep だと過大に数えてしまう。
- `.backlog/archive/tasks/` も数に入れる。人間が不要と判断して落とした候補も「その観点で起票を
  試みた実績」であり、同じ観点を選び直す根拠にはならないためである。
