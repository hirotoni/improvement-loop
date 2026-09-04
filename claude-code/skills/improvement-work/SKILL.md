---
name: improvement-work
description: improvement-dispatch から引き渡された Backlog.md タスクを、interview-dev-loop の型で遂行する。サブエージェントとして起動される前提のため人間に質問できず、曖昧さは repo の根拠から自分で解決し、判断が必要な点だけ中断して差し戻す。作業ブランチ上で実装・検証・コミットし、タスクを In Review にして報告する。単独のタスク実装依頼で、人間と対話できる場合は interview-dev-loop を直接使う。
---

# improvement-work

引き渡された 1 件の Backlog.md タスクを、作業ブランチ上で完了させる。
`interview-dev-loop` の型を踏襲するが、**人間と対話できない**前提で読み替える。

## ループ内の位置

状態遷移表の正本は `claude-code/skills/status-table.md` にある。まず読む。**このスキルが動かすのは `In Review`（work が動かす）である。**

**承認は既に済んでいる。** 人間が `Proposed` を `To Do` に上げた時点が承認である。
だから改めて承認を求めない。ただし承認されたのはタスクの受入基準の範囲だけである。そこから外に出るときは中断する（後述）。

`Done` にしない。終端は `In Review` である。

## 1. 引き渡し内容を確認する

```bash
cd "<引き渡された作業ディレクトリ>"
backlog instructions task-execution
backlog task view TASK-<n> --plain
# check-handoff の実体を探す（探索順とその理由は下の箇条書きを参照）。
HANDOFF_SCRIPT=""
MAIN_WORKTREE_ROOT="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
for candidate in \
  "claude-code/skills/improvement-work/scripts/check-handoff" \
  "$MAIN_WORKTREE_ROOT/.claude/skills/improvement-work/scripts/check-handoff"; do
  if [ -x "$candidate" ]; then
    HANDOFF_SCRIPT="$candidate"
    break
  fi
done
if [ -n "$HANDOFF_SCRIPT" ]; then
  "$HANDOFF_SCRIPT" "<引き渡された作業ディレクトリ>" "<引き渡されたブランチ名>"
  HANDOFF_EXIT=$?
else
  echo "エラー: check-handoff の実体が見つからない" >&2
  HANDOFF_EXIT=2
fi
echo "HANDOFF_EXIT=$HANDOFF_EXIT"
```

- `check-handoff` は、作業ディレクトリ一致・ブランチ一致・`.backlog` シンボリックリンクの健全性という、引き渡しが完全かどうかを機械的に判定できる3条件をまとめて確認する（スクリプトの中身は配布元の `claude-code/skills/improvement-work/scripts/check-handoff` を読むこと。実行時にどのパスで呼ぶかは下の探索順で決める）。3条件すべてを満たせば終了コード0、いずれかを満たさなければ標準エラーにどの条件が満たされていないかを明示して非0の終了コードで終わる。
- 引数には、引き渡された作業ディレクトリの絶対パスと、引き渡されたブランチ名をそのまま渡す。呼び出し側は `cd` 済みのワークツリーをカレントディレクトリとして持っていればよく、スクリプトをどのパスから呼んでも判定結果は変わらない（このスクリプト自身は `cd` せず、カレントディレクトリと引数だけで3条件を判定する）。
- 参照パスは固定しない。次の順に探し、最初に見つかった実行可能な実体を使う。これは手順8が `check-forbidden-allowed-paths` に対して行う探索とまったく同じで、理由（導入先リポジトリには `claude-code/skills/` が無く、`bin/setup-improvement-loop` が配る `.claude/skills/<スキル名>` シンボリックリンクは git 管理外でワークツリーに複製されないこと、メインの作業木のパスを `git worktree list --porcelain` の1行目から取ること）は手順8の該当箇所に書いてある（TASK-68・TASK-71）。同じ説明をここに繰り返さない。この探索を共通化せず2箇所に重複させたままにする判断とその理由、および食い違いを検知するテストについても手順8に書いてある（TASK-76）。
  1. `claude-code/skills/improvement-work/scripts/check-handoff`（このワークツリー内。improvement-loop 自身のリポジトリで解決する）。
  2. `<メインの作業木>/.claude/skills/improvement-work/scripts/check-handoff`（improvement-loop 以外の導入先リポジトリで解決する）。
- どちらのパスにも実体が無い場合（`setup-improvement-loop` による導入が済んでいない等）は、スクリプトを実行せずに `HANDOFF_EXIT=2`（環境不備）として扱い、下の「非0で終了した場合」と同じように報告して止まる。以前はワークツリー内の tracked パスだけを直接参照していたため、improvement-loop 以外の導入先では引き渡しが正常でも必ず `127` になり、毎回「引き渡し不備」と誤診断されていた（TASK-71）。
- 指定された作業ディレクトリ（ワークツリー、例: `<リポジトリルート>/.worktree/task-<n>-<スラッグ>`）へは自分で `cd` する。自分でブランチを作成・切り替え（`git switch`、`git checkout` 等）しない。ワークツリーは引き渡し時点で既に指定のブランチを checkout 済みである。
- `check-handoff` が非0で終了した場合（`$HANDOFF_EXIT` が0以外。作業ディレクトリが存在しない、`.backlog/` が見当たらない・シンボリックリンクになっていない等）は、dispatch の引き渡しが不完全なので、標準エラーの内容をそのまま報告して止まる。停止の判断・backlog タスクの編集はこのスクリプトの責務外であり、呼び出し側（自分自身）が行う。
- `check-handoff` はこの3条件のみを機械的に確認する。ワークツリー自体が `git worktree list` に登録されているか（worktree の管理情報が壊れているケース等）は範囲外なので、疑わしい場合は別途 `git worktree list` で確認すること。
- `.backlog/` は git 管理外である（`.git/info/exclude` で除外され、コミットされない）。そのため通常の `git worktree add` では作業ディレクトリに `.backlog/` は作られない。dispatch が引き渡し時に `$WORKTREE_DIR/.backlog` をメインの作業木の `.backlog/` へのシンボリックリンクとして用意している。これにより `backlog task edit` 等はこのワークツリーから実行しても、メインの作業木・他のワークツリーと同じタスクデータを共有して読み書きする。このシンボリックリンクを削除したり、実体のディレクトリに置き換えたりしない。
- このディレクトリはメインの作業木（人間が普段作業する場所）とは別の独立したワークツリーである。メインの作業木のファイルには一切触れない。
- **重要:** このハーネスは Bash 呼び出しごとにカレントディレクトリをリセットする。一度 `cd` しても次の Bash 呼び出しには引き継がれない。したがって、これ以降タスクが終わるまでの**すべての** Bash 呼び出しで、各コマンドの前に必ずこの作業ディレクトリへ `cd` してから続きを実行する（例: `cd "<作業ディレクトリ>" && git status --porcelain`、あるいは 1 回の呼び出し内に複数行の一連の作業をまとめて書く）。以降の手順の bash 例ではこの `cd` を省略して書くが、実行時には必ず補うこと。
- 自分を担当者にする：`backlog task edit TASK-<n> -a @improvement-work --plain`。status は既に `In Progress` になっている。
- リポジトリの規約（`CLAUDE.md`、`AGENTS.md`、lint 設定）を読む。backlog の操作は必ず CLI 経由で行う。

## 2. 調査する（interview-dev-loop の Pre-approval 相当）

該当する角度をすべて見て、見たものを名指しで書けるようにする。

- code：タスクが指している実物を読み切る
- docs：README、CLAUDE.md、コメントの宣言
- tests：既存の検証手段。無いなら無いと書く
- 既存の記録：`git log -- <path>`、過去タスクの notes、関連タスク
- ローカル規約：lint、フォーマッタ、pre-commit、CI

調査結果を `Collected Findings` / `Working Plan Context` / `Still Ambiguous` の形でまとめ、タスクに残す。

```bash
backlog task edit TASK-<n> --append-notes '### Collected Findings
- code: ...
- docs: ...
- tests: ...
- 既存の記録: ...
- ローカル規約: ...

### Working Plan Context
- 目的: ...
- 現状: ...
- 確定している前提: ...
- 壊してはいけない制約: ...
- 未決: ...' --plain
```

## 3. 曖昧さを自分で解決する（Clarification の読み替え）

人間に選択肢を提示できない。`Still Ambiguous` の各項目は、次の順で自分で決める。

1. タスクの受入基準。基準が答えているなら、それが答えである。
2. リポジトリの既存実装と規約。同種の処理がどう書かれているかに合わせる。
3. 既存のテスト・検証が守っている振る舞い。壊さない方を選ぶ。
4. `git log` に残る過去の意図。同じ判断を繰り返す。
5. それでも決まらないなら、可逆で影響の小さい方を選ぶ。

決めたことは根拠つきで残す。採用しなかった選択肢も 1 行書く。後から人間が覆せるようにするためである。

```bash
backlog task edit TASK-<n> --append-notes '### 自己解決した判断
- 判断: ...
  根拠: <file:line / 規約 / 既存テスト>
  採用しなかった選択肢: ...' --plain
```

### 中断する条件

次に当たったら、実装せずに差し戻す。推測で進めない。

- 受入基準の外にある製品判断（挙動の方針、UI の意味、命名規則の変更など）が必要になった。
- 破壊的、または外向きの操作（データ削除、force push、外部サービスへの送信、公開設定の変更）が必要になった。
- タスクの前提が既に成立していない（対象コードが消えている、既に直っている）。
- 受入基準どうしが矛盾している。

差し戻しの手順：

```bash
backlog task edit TASK-<n> \
  --add-label 'blocked:needs-decision' \
  -s "To Do" \
  --comment '<判断が必要な点。選択肢と、それぞれの結果を A) B) 形式で書く>' \
  --comment-author @improvement-work --plain
```

そのうえで、報告に `blocked` であることと必要な判断を書いて終わる。`blocked:needs-decision` が付いたタスクは dispatch の選択対象から外れ、人間が判断してラベルを外すまで動かない。

## 4. 計画を記録する（Plan gate の読み替え）

曖昧さの処理が終わってから計画を書く。計画は **backlog タスクの plan フィールドに記録する**。

```bash
backlog task edit TASK-<n> --plan '1. ...
2. ...
3. 検証: ...' --plain
```

- `docs/plans/*.md` などの計画ファイルを repo に作らない。このリポジトリでは backlog タスクが計画の記録場所である。
- 下書きが必要ならスクラッチパッド（repo 外）に書く。repo に残さない。
- 計画には手順、検証方法、触らない範囲（非目標）を含める。
- 途中で方針が変わったら、実装を進める前に `--plan` を更新する。タスクが常に現在の計画を指している状態を保つ。

## 5. 実装する

- 1 スライスずつ実装し、その都度検証する。
- 受入基準の範囲に留まる。範囲外の問題を見つけても直さない。`backlog task edit TASK-<n> --comment '<発見した別の問題>' --comment-author @improvement-work` に記録し、報告に「改善候補」として挙げる。次の scout の材料になる。
- 同じ根本原因が受入基準の範囲内に複数箇所あるなら、まとめて直す。
- 関係のない既存の変更を戻さない。
- 進捗は `backlog task edit TASK-<n> --append-notes '<実装したこと>'` に残す。

## 6. レビューパスを回す

実装が一巡したら、実装とは別の目で差分を見る。

```bash
git diff <デフォルトブランチ>...HEAD
```

- 範囲指定は3ドット（`A...B` = `git diff $(git merge-base A B) B`、マージベース起点）で揃えている。2ドット（両端の比較）にすると、分岐後にデフォルトブランチが進んでいる場合に他タスクの変更まで差分に混ざる。dispatch 手順6の完了検証と check-forbidden-allowed-paths の使用例も同じ3ドットである。
- サブエージェントを立てられる場合は、レビュー専用に 1 つ立て、差分だけを渡して `P0`/`P1`/`P2`/`P3` の一覧か `No findings` を返させる。
- 立てられない場合は自分でレビューパスを回す。差分を頭から読み直し、実装時の意図を持ち込まずに指摘を出す。
- 深刻度：`P0` は正しさ・セキュリティ・データ損失、`P1` は重要な不具合や検証の欠落、`P2` は保守性と設計の問題、`P3` は nit。
- `P0`/`P1`/`P2` が残っている限り、根本原因を直してレビューをやり直す。実装が終わったことは停止条件ではない。
- `P3` は安く直せるときだけ直す。

## 7. 検証する

リポジトリが宣言している検査を探して実行する。思い込みで済ませない。

- `.pre-commit-config.yaml`、CI 設定、`Makefile`、`package.json` の scripts を見て、該当するものを走らせる。
- 対象が設定ファイル（シェル、エディタ、ツール設定）なら、実際に読み込ませて確認する。例：シェルスクリプトは `bash -n` / `shellcheck`、Neovim 設定は `nvim --headless '+qa'` の終了コードとエラー出力。
- 受入基準ごとに、それを満たしたと言える証跡（コマンドと出力）を用意する。証跡が作れない基準はチェックしない。

## 8. コミットする

```bash
git add <変更したファイル>
# check-forbidden-allowed-paths の実体を探す（探索順とその理由は下の箇条書きを参照）。
CHECK_SCRIPT=""
MAIN_WORKTREE_ROOT="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
for candidate in \
  "claude-code/skills/improvement-dispatch/scripts/check-forbidden-allowed-paths" \
  "$MAIN_WORKTREE_ROOT/.claude/skills/improvement-dispatch/scripts/check-forbidden-allowed-paths"; do
  if [ -x "$candidate" ]; then
    CHECK_SCRIPT="$candidate"
    break
  fi
done
CHANGED_FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && CHANGED_FILES+=("$f")
done < <(git diff --name-only --cached)
if [ -n "$CHECK_SCRIPT" ]; then
  CHECK_OUTPUT="$("$CHECK_SCRIPT" "${CHANGED_FILES[@]}" 2>&1)"
  CHECK_EXIT=$?
else
  CHECK_OUTPUT="RESULT: ERROR (check-forbidden-allowed-paths の実体が見つからない)"
  CHECK_EXIT=2
fi
printf '%s\n' "$CHECK_OUTPUT"
echo "CHECK_EXIT=$CHECK_EXIT"
```

- `git add` の直後、`git commit` の前に、`check-forbidden-allowed-paths` に、ステージした変更ファイル一覧（`git diff --name-only --cached`）を渡し、`.backlog/config.my.yml` の `forbidden_paths`/`allowed_paths` と機械的に突き合わせる。ファイル名に半角スペースが含まれていても1ファイル=1引数のまま壊れないよう、`git diff` の出力を改行区切りで1行ずつ配列 `CHANGED_FILES` に読み込み、`"${CHANGED_FILES[@]}"` として展開する（`$CHANGED_FILES` のようにクォート無しで直接展開すると、ファイル名中の空白でも単語分割されて1つのパスが複数の偽の引数に壊れる）。
- 参照パスは固定しない。次の順に探し、最初に見つかった実行可能な実体を使う（TASK-68）。
  1. `claude-code/skills/improvement-dispatch/scripts/check-forbidden-allowed-paths`（このワークツリー内）。improvement-loop 自身のリポジトリでは `claude-code/skills/` が tracked なのでワークツリーにも実体としてチェックアウトされている。この場合は作業ブランチ側の内容が使われる。
  2. `<メインの作業木>/.claude/skills/improvement-dispatch/scripts/check-forbidden-allowed-paths`。improvement-loop 以外の導入先リポジトリには `claude-code/skills/` が無く、`bin/setup-improvement-loop` が配るのは `.claude/skills/<スキル名>` というシンボリックリンクだけである。しかもそれは `.git/info/exclude` に登録されて git 管理外なので、`git worktree add` で作られたワークツリーには複製されない。つまり導入先ではこの実体はメインの作業木にしか存在しない。メインの作業木のパスは `git worktree list --porcelain` の1行目（`worktree <パス>`）から取る。
- メインの作業木側の実体を呼んでも判定対象は変わらない。このスクリプトはカレントディレクトリから `git rev-parse --show-toplevel` で対象リポジトリを決め、その直下の `.backlog/config.my.yml`（ワークツリーでは `.backlog` シンボリックリンク経由でメインの作業木の実体を指す）を読むためである。スクリプト自身も自分の実パスから配布元リポジトリのルートを解決するので、シンボリックリンク経由でも `bin/lib/` の読み込みは壊れない。
- どちらのパスにも実体が無い場合（`setup-improvement-loop` による導入が済んでいない等）は、スクリプトを実行せずに `CHECK_EXIT=2`（環境不備）として扱う。見つからないまま `git commit` に進まない。以前はワークツリー内の tracked パスだけを直接参照していたため、improvement-loop 以外の導入先では必ず終了コード `127` になり、下の `0`/`1`/`2` のどの分岐にも当たらなかった（TASK-68）。
- この2候補探索は手順1（`check-handoff` の解決）にも同じ形で書かれている。共通化せず重複させたままにするのは意図的な判断である（TASK-76）。理由は3つある。
  1. 探索処理を外部のスクリプトや `bin/lib/*.sh` に切り出しても、SKILL.md からそれを呼ぶには切り出し先自身の実パスを同じ2候補探索で解決しなければならず、問題がそのまま再帰する。improvement-loop 以外の導入先リポジトリには `claude-code/` も `bin/` も無く、配布元の実体へ届く経路は `<メインの作業木>/.claude/skills/<スキル名>/` のシンボリックリンクだけだからである。
  2. `bin/lib/*.sh` を `DIST_REPO_ROOT` 経由で読む既存のスクリプト（`create-worktree` 等）は、自分自身の実パスを `BASH_SOURCE` から取れるので成立する。SKILL.md は読み手（AI）が実行する散文であり、それに相当する自己パスを持たない。同じ手は使えない。
  3. 手順1と手順8は別々の Bash 呼び出しで実行され、シェル変数を引き継げない（手順1の「重要」の項を参照）。片方で解決した結果をもう片方で使い回すこともできない。
- 重複を残す代わりに、手順1と手順8の探索ブロックが対象スクリプト名を除いて同一であることを `tests/test_skill_script_lookup.sh` が機械的に検査する。片方だけを変更すると `bash tests/run.sh` が FAIL する。探索順を変えるときは、両方の bash ブロックを同時に直すこと。
- `forbidden_paths`/`allowed_paths` が両方空、またはキー自体が無い場合、このスクリプトは常に `RESULT: OK`・終了コード `0` で終わる。したがってこの手順を追加しても、両方未設定の既存タスクの実行フローは変化しない（そのまま `git commit` に進むだけである）。
- `$CHECK_EXIT` の値で分岐する。
  - `0`（`RESULT: OK`）：違反なし。そのまま `git commit` する。
  - `1`（`RESULT: VIOLATION`）：コミットしない。次の二段で対応する。
    1. **自己修正を試みる**：`CHECK_OUTPUT` の `VIOLATING_FILES:` に列挙されたファイルのうち、受入基準の達成に必要ない変更は `git restore --staged --worktree -- <file>` で取り消す。取り消し後、`git add` からやり直して同じチェックを再実行する。再チェックが `RESULT: OK` になれば、そのまま `git commit` する。
    2. **自己修正できない場合**：違反ファイルへの変更が受入基準の達成に不可欠で取り消せない場合（＝受入基準の範囲そのものが `forbidden_paths`/`allowed_paths` と矛盾している）は、手順3「中断する条件」の「受入基準どうしが矛盾している」に準じて扱う。コミットせず、手順3と同じ差し戻し手順を実行する。
       ```bash
       backlog task edit TASK-<n> \
         --add-label 'blocked:needs-decision' \
         -s "To Do" \
         --comment '<VIOLATING_FILES の一覧と、どの受入基準の達成にその変更が必要か。A) forbidden_paths/allowed_paths を緩める B) 該当の受入基準を見直す、の形で選択肢を書く>' \
         --comment-author @improvement-work --plain
       ```
       報告に `blocked` である旨と違反内容を書いて終える。
  - `2`（`RESULT: ERROR`、または上記の探索でスクリプトの実体が見つからず `CHECK_EXIT=2` とした場合）：スクリプトが対象リポジトリを認識できない、実体が見つからない等の環境不備。コミットしない。これは製品判断ではなく環境不備なので `blocked:needs-decision` は付けず、手順1の `check-handoff` が非0終了したときと同じ扱い（`CHECK_OUTPUT` の内容をそのまま報告して止まる。停止の判断・backlog タスクの編集はこのスクリプトの責務外であり、呼び出し側である自分が行う）にする。
- 作業ディレクトリ（ワークツリー）内でコミットする。このディレクトリのブランチはこのタスクのために作られている。メインの作業木には一切コミットしない。
- コミットメッセージはリポジトリの既存の書式に合わせる。ハーネスがトレーラを要求している場合はそれに従う。
- `push` しない。`merge` しない。PR を作らない。リモートに触らない。`git worktree remove` もしない。ワークツリーの片付けは dispatch がマージ後に行う。
- 作業ディレクトリ（ワークツリー）を汚したまま終わらない。一時ファイルは消す。`git status --porcelain` が空になる状態にする。

## 9. 完了させて報告する

```bash
backlog instructions task-finalization
backlog task edit TASK-<n> --check-ac <満たした基準の番号> --plain
backlog task edit TASK-<n> --append-notes '検証: <コマンドと結果>' --plain
backlog task edit TASK-<n> --final-summary '<何を変え、なぜ、どう検証したか>' --plain
backlog task edit TASK-<n> -s "In Review" --plain
```

- 受入基準は証跡がある分だけチェックする。コードが存在することを根拠にチェックしない。
- 満たせなかった基準があるなら、チェックせずに理由を notes に書く。
- 最後に `In Review` にする。`Done` にはしない。

報告（dispatch が読む）に含めるもの：

1. タスク ID と最終 status。
2. 作業ブランチ名・作業ディレクトリ（ワークツリーのパス）とコミットの一覧。
3. 変更したファイル。
4. 実行した検証とその結果。
5. 満たせた受入基準と、満たせなかった基準（理由つき）。
6. 残るリスク。
7. 範囲外で見つけた改善候補。
8. 人間の判断が必要な未解決点（あれば `blocked` と明示）。

言語は引き渡し時の会話言語に合わせる。既存タスクの記述言語がそれと異なる場合はタスクの言語に合わせる。

## 禁止事項

- `push`、`merge`、PR 作成、リモート操作をしない。
- 自分の作業ディレクトリ（ワークツリー）の外、特にメインの作業木には触れない。`git worktree remove` もしない（片付けは dispatch がマージ後に行う）。
- タスクを `Done` にしない。終端は `In Review` である。
- 受入基準の外に手を広げない。見つけた問題は記録して報告する。
- 人間に質問して待たない。答えを得られないので、解決するか差し戻すかの二択にする。
- `docs/plans/*.md` のような計画ファイルを repo に残さない。計画は backlog タスクに記録する。
- `.backlog/` 配下の md を直接編集しない。すべて `backlog` CLI 経由で行う。
- 検証していない結果を報告に書かない。実行していないなら実行していないと書く。
