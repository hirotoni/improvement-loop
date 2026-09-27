---
name: improvement-work
description: improvement-dispatch から引き渡された Backlog.md タスクを、interview-dev-loop の型で遂行する。サブエージェントとして起動される前提のため人間に質問できず、曖昧さは repo の根拠から自分で解決し、判断が必要な点だけ中断して差し戻す。作業ブランチ上で実装・検証・コミットし、タスクを In Review にして報告する。単独のタスク実装依頼で、人間と対話できる場合は interview-dev-loop を直接使う。
model: Sonnet 5
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

- `check-handoff` は、作業ディレクトリ一致・ブランチ一致・`.backlog` シンボリックリンクの健全性という、引き渡しが完全かどうかを機械的に判定できる 3 条件をまとめて確認する（スクリプトの中身は配布元の `claude-code/skills/improvement-work/scripts/check-handoff` を読むこと。実行時にどのパスで呼ぶかは下の探索順で決める）。3 条件すべてを満たせば終了コード 0、いずれかを満たさなければ標準エラーにどの条件が満たされていないかを明示して非 0 の終了コードで終わる。
- 引数には、引き渡された作業ディレクトリの絶対パスと、引き渡されたブランチ名をそのまま渡す。呼び出し側は `cd` 済みのワークツリーをカレントディレクトリとして持っていればよく、スクリプトをどのパスから呼んでも判定結果は変わらない（このスクリプト自身は `cd` せず、カレントディレクトリと引数だけで 3 条件を判定する）。
- 参照パスは固定しない。次の順に探し、最初に見つかった実行可能な実体を使う。これは手順 8 が `check-forbidden-allowed-paths` に対して行う探索とまったく同じで、理由（導入先リポジトリには `claude-code/skills/` が無く、`bin/setup-improvement-loop` が配る `.claude/skills/<スキル名>` シンボリックリンクは git 管理外でワークツリーに複製されないこと、メインの作業木のパスを `git worktree list --porcelain` の 1 行目から取ること）は手順 8 の該当箇所に書いてある（TASK-68・TASK-71）。同じ説明をここに繰り返さない。この探索を共通化せず複数箇所（手順 1・5・7・8）に重複させたままにする判断とその理由、および食い違いを検知するテストについても手順 8 に書いてある（TASK-76）。
  1. `claude-code/skills/improvement-work/scripts/check-handoff`（このワークツリー内。improvement-loop 自身のリポジトリで解決する）。
  2. `<メインの作業木>/.claude/skills/improvement-work/scripts/check-handoff`（improvement-loop 以外の導入先リポジトリで解決する）。
- どちらのパスにも実体が無い場合（`setup-improvement-loop` による導入が済んでいない等）は、スクリプトを実行せずに `HANDOFF_EXIT=2`（環境不備）として扱い、下の「非 0 で終了した場合」と同じように報告して止まる。以前はワークツリー内の tracked パスだけを直接参照していたため、improvement-loop 以外の導入先では引き渡しが正常でも必ず `127` になり、毎回「引き渡し不備」と誤診断されていた（TASK-71）。
- 指定された作業ディレクトリ（ワークツリー、例: `<リポジトリルート>/.worktree/task-<n>-<スラッグ>`）へは自分で `cd` する。自分でブランチを作成・切り替え（`git switch`、`git checkout` 等）しない。ワークツリーは引き渡し時点で既に指定のブランチを checkout 済みである。
- `check-handoff` が非 0 で終了した場合（`$HANDOFF_EXIT` が 0 以外。作業ディレクトリが存在しない、`.backlog/` が見当たらない・シンボリックリンクになっていない等）は、dispatch の引き渡しが不完全なので、標準エラーの内容をそのまま報告して止まる。停止の判断・backlog タスクの編集はこのスクリプトの責務外であり、呼び出し側（自分自身）が行う。
- `check-handoff` はこの 3 条件のみを機械的に確認する。ワークツリー自体が `git worktree list` に登録されているか（worktree の管理情報が壊れているケース等）は範囲外なので、疑わしい場合は別途 `git worktree list` で確認すること。
- `.backlog/` は git 管理外である（`.git/info/exclude` で除外され、コミットされない）。そのため通常の `git worktree add` では作業ディレクトリに `.backlog/` は作られない。dispatch が引き渡し時に `$WORKTREE_DIR/.backlog` をメインの作業木の `.backlog/` へのシンボリックリンクとして用意している。これにより `backlog task edit` 等はこのワークツリーから実行しても、メインの作業木・他のワークツリーと同じタスクデータを共有して読み書きする。このシンボリックリンクを削除したり、実体のディレクトリに置き換えたりしない。
- **共有の `.backlog/config.yml` を書き換えない。** 上のシンボリックリンクがあるので、ワークツリー直下で `.backlog/config.yml` へ書き込む（`>`・`>>`・`cp`・`mv`・`sed -i` 等）と、メインの作業木と全ワークツリーが共有する config.yml がそのまま書き換わる。`backlog config set` も同じである。ワークツリー直下ではどちらも実行しない（TASK-117）。2026-09-27 に、実 CLI の挙動を確かめる即席のコマンドが `cd` の失敗で止まらずワークツリー直下で走り、共有 config.yml をフィクスチャの値で上書きした。その結果、全タスクのステータス変更が失敗してループが止まった。
  - backlog CLI の挙動や config.yml の読み方を確かめたいときは、`mktemp -d` で作った一時ディレクトリを git リポジトリにし、その中に実ディレクトリの `.backlog` を置いて行う（シンボリックリンクにしない）。
  - その一時ディレクトリへの `cd` は、失敗したら止まる形で書く（例: `cd "$TMP_REPO" || exit 1`）。`cd <dir>; <コマンド>` や、`cd` の成否を見ないループにしない。`cd` が失敗すると、後続のコマンドがカレントディレクトリ（ワークツリー直下）で走るためである。
  - 仕組みでも見張っている。dispatch は引き渡し時点の config.yml を複製しておき、手順 8 のコミット前の確認と dispatch の完了検証で改変を検知する。ただし検知できるのは壊れた後である。規定を守ることが先である。
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
- 各実装スライスが完了するたび（進捗を notes に残す前後など）、占有記録のハートビート更新（TASK-93 の軽量経路 `touch-occupancy`）を呼ぶ。1スライスの実装・その場での検証がコミットを伴わずに続くと、`claude-code/skills/improvement-dispatch/SKILL.md` に明記された残存リスク（30分を超えるコミット無し処理中に誤って `REVERT_TO_TODO` される）が現実になりうるためである。

  ```bash
  MAIN_WORKTREE_ROOT="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
  TOUCH_SCRIPT=""
  for candidate in \
    "claude-code/skills/improvement-dispatch/scripts/touch-occupancy" \
    "$MAIN_WORKTREE_ROOT/.claude/skills/improvement-dispatch/scripts/touch-occupancy"; do
    if [ -x "$candidate" ]; then
      TOUCH_SCRIPT="$candidate"
      break
    fi
  done
  if [ -n "$TOUCH_SCRIPT" ]; then
    TASK_SLUG="$(git rev-parse --abbrev-ref HEAD | sed 's#^improvement/##')"
    "$TOUCH_SCRIPT" "$(pwd)" "$TASK_SLUG" >/dev/null 2>&1 || true
  fi
  ```

  - 参照パスの2候補探索は手順1・手順8と同じ理由（導入先リポジトリには `claude-code/skills/` が無く、`.claude/skills/<スキル名>` シンボリックリンク経由でしか実体に届かない）による。
  - この呼び出しは**ベストエフォート**である。`touch-occupancy` の実体が見つからない場合（`TOUCH_SCRIPT` が空のまま）、または見つかっても失敗した場合（`|| true` で握り潰す）でも、実装・検証・コミット・`In Review` への遷移を一切止めない。占有記録の更新に失敗しても、既存のコミット履歴ベースのフォールバック判定（`claude-code/skills/improvement-dispatch/scripts/check-progress-recovery`）に委ねられる。
  - `TOUCH_SCRIPT` を手順8の `CHECK_SCRIPT` と混同しない。別の Bash 呼び出しで変数は引き継がれないため、呼ぶたびにこのブロックをそのまま実行する。

## 6. レビューパスを回す

実装が一巡したら、実装とは別の目で差分を見る。

```bash
git diff <デフォルトブランチ>...HEAD
```

- 範囲指定は 3 ドット（`A...B` = `git diff $(git merge-base A B) B`、マージベース起点）で揃えている。2 ドット（両端の比較）にすると、分岐後にデフォルトブランチが進んでいる場合に他タスクの変更まで差分に混ざる。dispatch 手順 6 の完了検証と check-forbidden-allowed-paths の使用例も同じ 3 ドットである。
- **レビューは独立サブエージェントで行うのが原則である。** Agent ツール（環境によっては `Task` ツールという名前で提供される。以下まとめて Agent ツールと書く）が使える限り、毎巡（再レビューを含む）レビュー専用のサブエージェントを 1 つ新しく立てる。渡すのは差分、タスクの受入基準、作業ディレクトリ（ワークツリー）の絶対パス、それに「ファイルを編集しない（読み取りのみ）」という指示だけである。ワークツリーのパスを渡すのは、レビュー役が文脈確認のためにファイルを開いたとき、メインの作業木にある変更前の版を読まないようにするためである。`P0`/`P1`/`P2`/`P3` の一覧か `No findings` を返させる。実装時の意図や自分の判断の説明は渡さない（例外は下の「妥当でないと判断した指摘」の扱いだけである）。実装役とレビュー役を分けることがこの手順の目的だからである。
  - 入れ子の深さは制約にならない。Claude Code v2.1.219 以降のサブエージェントは既定でメインの会話から 3 階層下まで入れ子にでき、dispatch（メイン）→ improvement-work（1 階層目）→ レビュー役（2 階層目）はその範囲に収まる（https://code.claude.com/docs/en/sub-agents）。
  - 「差分が小さい」「自明な変更である」「時間がかかる」「自分で読んだ方が早い」は、自己レビューに切り替える理由にならない。
- 自己レビューで代替してよいのは、サブエージェントを起動できなかった場合に限る。具体的には次のどちらかだけである。
  - Agent ツールが自分のツール一覧に無い。deferred tool として名前だけが示されている場合は「無い」に当たらない。ToolSearch 等でスキーマを読み込んでから呼び出す。
  - Agent ツールの呼び出しが 2 回続けて失敗した。失敗とは、呼び出しがエラーを返したこと、または完了したサブエージェントの最終報告にレビュー結果（指摘一覧か `No findings`）が含まれていなかったことを指す。サブエージェントがバックグラウンドで動き、呼び出しがすぐ戻る場合は、完了の通知を待ってから最終報告で判断する。呼び出しが結果を伴わずにすぐ戻ったことは失敗ではない。1 回目の失敗では自己レビューに切り替えず、同じ依頼でもう 1 回呼び出す。
- 自己レビューにしたときは差分を頭から読み直し、実装時の意図を持ち込まずに指摘を出す。自己レビューにした理由（無かったのか、失敗したのか。失敗なら 2 回分のエラー内容）を下の記録に必ず書く。自己レビューに切り替えた後も、次の巡では改めて Agent ツールでの独立レビューから試みる。
- 深刻度：`P0` は正しさ・セキュリティ・データ損失、`P1` は重要な不具合や検証の欠落、`P2` は保守性と設計の問題、`P3` は nit。
- `P0`/`P1`/`P2` が残っている限り、根本原因を直してレビューをやり直す。実装が終わったことは停止条件ではない。
- `P3` は安く直せるときだけ直す。
- 妥当でないと判断した `P0`/`P1`/`P2` の指摘は、直さずに済ませてよいことにはならない。次巡のレビュー役にその指摘と却下の根拠を渡して再評価させる。レビュー役が根拠を認めて取り下げた指摘は、停止条件の判定で数えない。取り下げを認められるのは独立サブエージェントのレビュー役だけである。自己レビューの巡で出た `P0`/`P1`/`P2` は、自分で却下せず、直すか差し戻すかのどちらかにする。次巡でも同じ指摘が維持されたら、自分で打ち切らず、手順 3「中断する条件」の差し戻し手順（`blocked:needs-decision`）に従う。
- レビュー役の起動から結果を受け取るまでは、コミットを伴わずに時間がかかる。レビューを依頼する直前と結果を受け取った直後に、手順 5 と同じ占有記録のハートビート更新（`touch-occupancy`）を呼ぶ。手順 7 の検証コマンドの前後と同じ扱いである。
- **レビューを 1 巡行うたびに**タスクの notes へ記録する。記録するのは、その巡の指摘への対応を終えた時点（次巡のレビューを依頼する前。指摘が無ければ結果を受け取った直後）である。ただし、その巡の指摘を理由に手順 3 の差し戻しをする場合は、対応が終わらないので、差し戻しの前にその巡を記録する。記録が無いレビューは行わなかったものとみなされる。巡数は 1 から数え、再レビューのたびに 1 増やす。

  ```bash
  backlog task edit TASK-<n> --append-notes '### レビュー <巡数> 巡目
  - 方法: 独立サブエージェント | 自己レビュー
  - 自己レビューにした理由: <Agent ツールが無い / Agent ツールの呼び出しが 2 回続けて失敗した（各回のエラー内容）。独立サブエージェントなら「該当なし」>
  - 結果: P0 <件数> / P1 <件数> / P2 <件数> / P3 <件数>（指摘が無ければ No findings）
  - 対応: <直した指摘と直し方。見送った P3、妥当でないと判断した指摘とその根拠>' --plain
  ```

  - 記録の書式の正本は [`claude-code/skills/improvement-work/review-record-format.md`](review-record-format.md) にある。上の例はその書式と同じ 5 行である。各行の書き方（`対応:` 以外は 1 行に収めること、`方法:`・`結果:` の値に付けてよい注記、取り下げの書き方、`対応:` の続け方）はそちらに従う。dispatch 手順 6 は `check-review-records` でこの書式どおりに記録を読み、書式から外れた巡は書式不備として差し戻す。
  - 本文は単一引用符で囲んでいる。エラーメッセージや指摘を写すときに本文へ `'` が入る場合は、`'\''` に置き換えるか、全角の引用符に書き換える。
  - 結果の件数は、レビュー役が返した指摘をそのまま数える。自分で妥当でないと判断した指摘も件数から除かない。
  - 最終巡（`P0`/`P1`/`P2` が、レビュー役が取り下げたものを除いて 0 件になった巡）の記録が、手順 9 の報告に書くレビュー結果の根拠になる。差し戻しで最終巡に至らなかった場合は、最後に行った巡の記録が根拠になる。

## 7. 検証する

リポジトリが宣言している検査を探して実行する。思い込みで済ませない。

- `.pre-commit-config.yaml`、CI 設定、`Makefile`、`package.json` の scripts を見て、該当するものを走らせる。
- 対象が設定ファイル（シェル、エディタ、ツール設定）なら、実際に読み込ませて確認する。例：シェルスクリプトは `bash -n` / `shellcheck`、Neovim 設定は `nvim --headless '+qa'` の終了コードとエラー出力。
- 受入基準ごとに、それを満たしたと言える証跡（コマンドと出力）を用意する。証跡が作れない基準はチェックしない。
- テストスイートの実行など、コミットを伴わずに時間のかかる検証コマンドを走らせるときは、その直前・直後に占有記録のハートビート更新を呼ぶ。手順5と同じ呼び出しをそのまま使う。

  ```bash
  MAIN_WORKTREE_ROOT="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
  TOUCH_SCRIPT=""
  for candidate in \
    "claude-code/skills/improvement-dispatch/scripts/touch-occupancy" \
    "$MAIN_WORKTREE_ROOT/.claude/skills/improvement-dispatch/scripts/touch-occupancy"; do
    if [ -x "$candidate" ]; then
      TOUCH_SCRIPT="$candidate"
      break
    fi
  done
  if [ -n "$TOUCH_SCRIPT" ]; then
    TASK_SLUG="$(git rev-parse --abbrev-ref HEAD | sed 's#^improvement/##')"
    "$TOUCH_SCRIPT" "$(pwd)" "$TASK_SLUG" >/dev/null 2>&1 || true
  fi
  # ここで本来の検証コマンド（例: bash tests/run.sh）を実行する。
  # 完了後、同じブロックをもう一度呼んで直後のタイムスタンプも更新する。
  ```

  - この呼び出しも**ベストエフォート**である。手順5と同じく、`touch-occupancy` が見つからない・失敗しても検証そのもの・その後の報告・コミットへの移行は止めない。

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

- `git add` の直後、`git commit` の前に、`check-forbidden-allowed-paths` に、ステージした変更ファイル一覧（`git diff --name-only --cached`）を渡し、`.backlog/config.my.yml` の `forbidden_paths`/`allowed_paths` と機械的に突き合わせる。ファイル名に半角スペースが含まれていても 1 ファイル=1 引数のまま壊れないよう、`git diff` の出力を改行区切りで 1 行ずつ配列 `CHANGED_FILES` に読み込み、`"${CHANGED_FILES[@]}"` として展開する（`$CHANGED_FILES` のようにクォート無しで直接展開すると、ファイル名中の空白でも単語分割されて 1 つのパスが複数の偽の引数に壊れる）。
- 参照パスは固定しない。次の順に探し、最初に見つかった実行可能な実体を使う（TASK-68）。
  1. `claude-code/skills/improvement-dispatch/scripts/check-forbidden-allowed-paths`（このワークツリー内）。improvement-loop 自身のリポジトリでは `claude-code/skills/` が tracked なのでワークツリーにも実体としてチェックアウトされている。この場合は作業ブランチ側の内容が使われる。
  2. `<メインの作業木>/.claude/skills/improvement-dispatch/scripts/check-forbidden-allowed-paths`。improvement-loop 以外の導入先リポジトリには `claude-code/skills/` が無く、`bin/setup-improvement-loop` が配るのは `.claude/skills/<スキル名>` というシンボリックリンクだけである。しかもそれは `.git/info/exclude` に登録されて git 管理外なので、`git worktree add` で作られたワークツリーには複製されない。つまり導入先ではこの実体はメインの作業木にしか存在しない。メインの作業木のパスは `git worktree list --porcelain` の 1 行目（`worktree <パス>`）から取る。
- メインの作業木側の実体を呼んでも判定対象は変わらない。このスクリプトはカレントディレクトリから `git rev-parse --show-toplevel` で対象リポジトリを決め、その直下の `.backlog/config.my.yml`（ワークツリーでは `.backlog` シンボリックリンク経由でメインの作業木の実体を指す）を読むためである。スクリプト自身も自分の実パスから配布元リポジトリのルートを解決するので、シンボリックリンク経由でも `bin/lib/` の読み込みは壊れない。
- どちらのパスにも実体が無い場合（`setup-improvement-loop` による導入が済んでいない等）は、スクリプトを実行せずに `CHECK_EXIT=2`（環境不備）として扱う。見つからないまま `git commit` に進まない。以前はワークツリー内の tracked パスだけを直接参照していたため、improvement-loop 以外の導入先では必ず終了コード `127` になり、下の `0`/`1`/`2` のどの分岐にも当たらなかった（TASK-68）。
- この 2 候補探索は手順 1（`check-handoff` の解決）、手順 5・7（`touch-occupancy`）、この手順 8 の後半（`backlog-config-snapshot`）にも同じ形で書かれている。共通化せず重複させたままにするのは意図的な判断である（TASK-76）。理由は 3 つある。
  1. 探索処理を外部のスクリプトや `bin/lib/*.sh` に切り出しても、SKILL.md からそれを呼ぶには切り出し先自身の実パスを同じ 2 候補探索で解決しなければならず、問題がそのまま再帰する。improvement-loop 以外の導入先リポジトリには `claude-code/` も `bin/` も無く、配布元の実体へ届く経路は `<メインの作業木>/.claude/skills/<スキル名>/` のシンボリックリンクだけだからである。
  2. `bin/lib/*.sh` を `DIST_REPO_ROOT` 経由で読む既存のスクリプト（`create-worktree` 等）は、自分自身の実パスを `BASH_SOURCE` から取れるので成立する。SKILL.md は読み手（AI）が実行する散文であり、それに相当する自己パスを持たない。同じ手は使えない。
  3. 手順 1 と手順 8 は別々の Bash 呼び出しで実行され、シェル変数を引き継げない（手順 1 の「重要」の項を参照）。片方で解決した結果をもう片方で使い回すこともできない。
- 重複を残す代わりに、この SKILL.md にある 5 つの探索ブロック（手順 1 の `check-handoff`、手順 5・7 の `touch-occupancy`、手順 8 の `check-forbidden-allowed-paths` と `backlog-config-snapshot`）が対象スクリプト名を除いて同一であることを `tests/test_skill_script_lookup.sh` が機械的に検査する。どれか 1 つだけを変更すると `bash tests/run.sh` が FAIL する。探索順を変えるときは、5 つの bash ブロックを同時に直すこと。
- `forbidden_paths`/`allowed_paths` が両方空、またはキー自体が無い場合、このスクリプトは常に `RESULT: OK`・終了コード `0` で終わる。したがってこの手順を追加しても、両方未設定の既存タスクの実行フローは変化しない（そのまま `git commit` に進むだけである）。
- `$CHECK_EXIT` の値で分岐する。
  - `0`（`RESULT: OK`）：違反なし。下の「共有の `.backlog/config.yml` が書き換わっていないか確かめる」を経て `git commit` する。
  - `1`（`RESULT: VIOLATION`）：コミットしない。次の二段で対応する。
    1. **自己修正を試みる**：`CHECK_OUTPUT` の `VIOLATING_FILES:` に列挙されたファイルのうち、受入基準の達成に必要ない変更は `git restore --staged --worktree -- <file>` で取り消す。取り消し後、`git add` からやり直して同じチェックを再実行する。再チェックが `RESULT: OK` になれば、`0` の場合と同じく下の確認を経て `git commit` する。
    2. **自己修正できない場合**：違反ファイルへの変更が受入基準の達成に不可欠で取り消せない場合（＝受入基準の範囲そのものが `forbidden_paths`/`allowed_paths` と矛盾している）は、手順 3「中断する条件」の「受入基準どうしが矛盾している」に準じて扱う。コミットせず、手順 3 と同じ差し戻し手順を実行する。
       ```bash
       backlog task edit TASK-<n> \
         --add-label 'blocked:needs-decision' \
         -s "To Do" \
         --comment '<VIOLATING_FILES の一覧と、どの受入基準の達成にその変更が必要か。A) forbidden_paths/allowed_paths を緩める B) 該当の受入基準を見直す、の形で選択肢を書く>' \
         --comment-author @improvement-work --plain
       ```
       報告に `blocked` である旨と違反内容を書いて終える。
  - `2`（`RESULT: ERROR`、または上記の探索でスクリプトの実体が見つからず `CHECK_EXIT=2` とした場合）：スクリプトが対象リポジトリを認識できない、実体が見つからない等の環境不備。コミットしない。これは製品判断ではなく環境不備なので `blocked:needs-decision` は付けず、手順 1 の `check-handoff` が非 0 終了したときと同じ扱い（`CHECK_OUTPUT` の内容をそのまま報告して止まる。停止の判断・backlog タスクの編集はこのスクリプトの責務外であり、呼び出し側である自分が行う）にする。

### 共有の `.backlog/config.yml` が書き換わっていないか確かめる

`git commit` の前に（上の `check-forbidden-allowed-paths` の後に続けて）、共有の `.backlog/config.yml` が引き渡し時点から変わっていないかを確かめる（TASK-117）。`.backlog/` は git 管理外なので、ここでの改変は `git diff` にも `check-forbidden-allowed-paths` にも現れない。

```bash
MAIN_WORKTREE_ROOT="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
SNAPSHOT_SCRIPT=""
for candidate in \
  "claude-code/skills/improvement-dispatch/scripts/backlog-config-snapshot" \
  "$MAIN_WORKTREE_ROOT/.claude/skills/improvement-dispatch/scripts/backlog-config-snapshot"; do
  if [ -x "$candidate" ]; then
    SNAPSHOT_SCRIPT="$candidate"
    break
  fi
done
TASK_SLUG="$(git rev-parse --abbrev-ref HEAD | sed 's#^improvement/##')"
if [ -n "$SNAPSHOT_SCRIPT" ]; then
  "$SNAPSHOT_SCRIPT" check "$TASK_SLUG"
  SNAPSHOT_EXIT=$?
else
  echo "RESULT: ERROR (backlog-config-snapshot の実体が見つからない)"
  SNAPSHOT_EXIT=2
fi
echo "SNAPSHOT_EXIT=$SNAPSHOT_EXIT"
```

- 参照パスの 2 候補探索は手順 5 の `touch-occupancy` と同じ形（`MAIN_WORKTREE_ROOT` を先に求める）にしている。このブロックも `tests/test_skill_script_lookup.sh` の一致検査の対象である。
- このスクリプトは読むだけで、何も書き込まない。比較対象はワークツリーの `.backlog` ではなく、メインの作業木の `.backlog/config.yml` である。複製は dispatch の `create-worktree` が引き渡し時に `<git-common-dir>/improvement-loop/backlog-config-snapshots/<task-id>.yml` へ保存している。
- `$SNAPSHOT_EXIT` の値で分岐する。
  - `0`（`RESULT: OK`）：変わっていない。そのまま進む。
  - `1`（`RESULT: CHANGED`）：共有 config.yml が引き渡し時点から変わっている。標準エラーに差分が、標準出力に `RESTORE_COMMAND=` が出る。**自分で戻さない**（`restore` を実行しない、手で書き戻さない）。変更が人間の意図的な設定変更かどうかを区別できないためである。次の 2 つを行い、コミットと手順 9 はそのまま進める（コミット内容は config.yml と無関係なので止める理由にならない。ただし config.yml の `statuses` が壊れていると手順 9 のステータス変更が失敗しうる。失敗したらその旨も報告に書く）。
    1. `backlog task edit TASK-<n> --comment '共有 .backlog/config.yml が引き渡し時点から変わっている。差分: <差分の要約>。戻すなら人間が次を実行する: <RESTORE_COMMAND の値>' --comment-author @improvement-work --plain` でタスクに残す。
    2. 手順 9 の報告の「人間の判断が必要な未解決点」に、差分の要約と `RESTORE_COMMAND` の値を書く。自分の作業中のコマンドが原因だと分かっている場合は、それも書く。
  - `3`（`RESULT: NO_SNAPSHOT`）：複製が無く比較できない（この仕組みの導入前に作られたワークツリー、引き渡し時点で config.yml が無かった場合等。後者では、後から作られた config.yml も検知されない）。止めずに進み、手順 9 の報告に「共有 config.yml の改変検知は複製が無く実施できなかった」と書く。
  - `2`（`RESULT: ERROR`）：環境不備。止めずに進み、出力をそのまま手順 9 の報告に書く。この確認は検知のための補助であり、`check-forbidden-allowed-paths` のようなコミットの門番ではないためである。

### コミットの作法

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
5. 手順 6 のレビュー結果。巡ごとの方法（独立サブエージェント／自己レビュー。自己レビューの巡があればその理由）、巡数、最終巡の指摘状況（`P0`〜`P3` の件数か `No findings`、見送った `P3` があればその旨）。手順 6 で notes に残した記録と食い違わないように書く。
6. 満たせた受入基準と、満たせなかった基準（理由つき）。
7. 残るリスク。
8. 範囲外で見つけた改善候補。
9. 人間の判断が必要な未解決点（あれば `blocked` と明示）。
10. 手順 8 の共有 `.backlog/config.yml` の確認結果（`OK` / `CHANGED` / `NO_SNAPSHOT` / `ERROR`）。`CHANGED` なら差分の要約と `RESTORE_COMMAND` の値。

言語は引き渡し時の会話言語に合わせる。既存タスクの記述言語がそれと異なる場合はタスクの言語に合わせる。

## 禁止事項

- `push`、`merge`、PR 作成、リモート操作をしない。
- 自分の作業ディレクトリ（ワークツリー）の外、特にメインの作業木には触れない。`git worktree remove` もしない（片付けは dispatch がマージ後に行う）。
- タスクを `Done` にしない。終端は `In Review` である。
- 受入基準の外に手を広げない。見つけた問題は記録して報告する。
- 人間に質問して待たない。答えを得られないので、解決するか差し戻すかの二択にする。
- `docs/plans/*.md` のような計画ファイルを repo に残さない。計画は backlog タスクに記録する。
- `.backlog/` 配下の md を直接編集しない。すべて `backlog` CLI 経由で行う。
- ワークツリー直下で `.backlog/config.yml` を書き換えない。`backlog config set` を実行しない。CLI の挙動の確認は一時リポジトリの中で行い、その `cd` は失敗したら止まる形（`cd <dir> || exit 1`）にする（手順 1）。
- 検証していない結果を報告に書かない。実行していないなら実行していないと書く。
