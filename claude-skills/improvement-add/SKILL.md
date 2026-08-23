---
name: improvement-add
description: 人間が伝えた改善要望を、探索や観点選定を挟まずそのまま Backlog.md に Proposed で起票する。「このタスクも積んでおいて」「〜を直したいので起票して」「これも改善候補にして」のように、人間が既に内容を把握している改善案をタスク化したいときに使用する。improvement ループの入口の一つであり、起票したタスクは人間が To Do に上げるまで着手されない。コードベースを探索して改善候補そのものを洗い出したいときは improvement-scout を使う。
---

# improvement-add

人間から伝えられた改善要望を、Backlog.md に `Proposed` で起票する。
成果物はタスクだけである。このスキルの中でコードは変更しない。
探索や観点選定は行わない。内容は人間から与えられたものをそのまま使う。

## ループ内の位置

| status | 意味 | 動かす主体 |
| --- | --- | --- |
| `Proposed` | 起票された改善候補。未承認 | **add が起票する（scout も起票する）** |
| `To Do` | 着手が承認された | 人間 |
| `In Progress` | 作業ブランチに引き渡し済み | improvement-dispatch |
| `In Review` | 実装がブランチに乗り、レビュー待ち | improvement-work |
| `Approved` | 人間のレビューが済み、マージを待っている | 人間 |
| `Done` | main にマージ済み | improvement-dispatch |

`Proposed` から先には進めない。人間が内容を確認して `To Do` に上げたものだけが improvement-dispatch に拾われる。
このスキルは起票までで終わる。承認を促したり、自分で `To Do` に上げたりしない。

使わない場面：

- コードベースを探索して改善候補そのものを見つけたい依頼（`improvement-scout` を使う）。
- 特定の不具合を直す依頼（起票せず直接修正する）。
- 起票を伴わないレビューや説明の依頼。
- Backlog.md が未導入のリポジトリ。`backlog task list --plain` が「No Backlog.md project found」を返すなら、`backlog init` してよいかユーザーに確認する。

## 引数

人間が伝えた改善要望のテキストをそのまま受け取る。要望が曖昧で「何をどう変えるか」が特定できない場合は、起票前にユーザーに確認する。推測で内容を埋めない。

## 1. 前提を確認する

- `backlog instructions overview` と `backlog instructions task-creation` を読む。プロジェクトの規約が優先される。
- `backlog config get statuses` を実行し、`Proposed` があるか確認する。設定にない status を渡すとタスク作成が失敗するため、この確認を先に行う。
- 無ければ `.backlog/config.yml`（または `backlog/config.yml`）の `statuses` に `Proposed` を先頭で追加する。`statuses` は `backlog config set` では変更できず、backlog 自身が config ファイルの直接編集を案内する。
- `backlog config get types` と `backlog config get priorities` で使える値を確認し、以降その値だけを渡す。
- backlog の読み取り系コマンドには必ず `--plain` を付ける。付けないと対話 UI が起動してセッションが止まる。`backlog task create` はタイトルを引数で渡す（省略すると対話プロンプトになる）。

## 2. 既存タスクと照合する

同じ内容が既に追跡されていないか、起票の前に必ず確認する。

```bash
backlog task list --plain
backlog search "<キーワード>" --plain
backlog search --modified-file <対象パス> --plain
```

- 同じ内容のタスクがあれば起票しない。`Proposed` のまま残っている候補も対象に含めて数える。既存タスクを見つけたらユーザーに伝え、重複起票せず終える。
- 既存タスクに足すべき情報があるときは `backlog task edit TASK-<n> --comment '<追記>' --comment-author @<name>` にとどめる。説明や受入基準の書き換えはユーザーに確認してから行う。
- `Proposed` が溜まりすぎている（目安 10 件超）なら、新規起票の前にその事実を報告する。積み増しより承認待ちの解消が先である。

## 3. 起票する

1 件 = 1 コマンド。伝えられた要望を 1 タスクに詰め込まない。複数の要望が混ざっているときは分けて起票する。

```bash
backlog task create '<何をどうするかが分かる動詞句>' \
  -s Proposed \
  --type <bug|chore|enhancement|feature|docs|spike> \
  --priority <High|Medium|Low> \
  --modified-file <分かっていれば対象のパス> \
  -d '## 現状
<分かっている範囲で、いま何がどうなっているか>

## 問題
<どの条件で誰が何に困るか>

## 期待する結果
<満たされるべき状態。実装方法は書かない>

## 確認したこと
<既存タスクとの重複確認で読んだもの、実行したコマンドとその結果>' \
  --ac '<検証可能な条件>' \
  --ac '<検証可能な条件>' \
  --plain
```

規約：

- 引数は単一引用符で囲む。バッククォートを含む文字列を二重引用符に入れるとシェルがコマンド置換として実行してしまい、原文が復元できない。
- 複数行の description は引用符の中に実際の改行を入れる。`\n` は展開されない。
- `-s Proposed` を明示する。`default_status` に依存しない。
- `audit` ラベルは付けない。`audit` は improvement-scout が調査から起票したタスクに使う印で、このスキルが起票するのは人間発案のタスクだから対象外である。
- `--modified-file` は分かっている場合だけ付ける。次回以降 `backlog search --modified-file <path> --plain` で重複を検出できる。
- 受入基準は振る舞いで書く。「関数を追加する」ではなく「〜のとき〜になる」。実装手順を受入基準にしない。
- `--plan` は書かない。着手時に improvement-work が調べ直して記録する。
- `## 確認したこと` には実際に見た根拠だけを書く。人間から伝えられた内容をそのまま書き写すだけでなく、重複確認で実行したコマンドとその結果を書く。
- 依存関係を付けるときは前提側を先に作り、出力の ID を控えてから後続に `--dep TASK-<n>` を渡す。存在しない ID を渡すと作成自体が失敗する。
- 要望の内容から type・priority・受入基準が特定できないときは、推測で埋めずユーザーに確認する。

## 4. 報告する

1. 起票したタスクの一覧。ID、タイトル、優先度、type。
2. 承認の手順を添える：着手させるなら `backlog task edit TASK-<n> -s "To Do"`、不要なら `backlog task archive TASK-<n>`。
3. 重複として起票しなかったものがあれば、対応する既存タスクの ID を示す。

タスク本文と報告の言語は会話の言語に合わせる。既存タスクがあるならその言語に合わせる。

## 禁止事項

- `.backlog/`（または `backlog/`）配下の md を直接編集しない。追加も更新もアーカイブも `backlog` CLI 経由で行う。config.yml は例外で、`statuses` の追加のみ直接編集してよい。
- 起票したタスクを自分で `To Do` に上げない。承認は人間の役割である。
- このスキルの中でコードを変更しない。修正は起票したタスクの実行として行われる。
- 曖昧な要望を推測で埋めて起票しない。特定できない項目はユーザーに確認する。
- `audit` ラベルを付けない。監査由来のタスクと人間発案のタスクを混同しない。
