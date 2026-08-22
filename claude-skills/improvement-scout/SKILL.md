---
name: improvement-scout
description: コードベースを探索して改善タスクを Backlog.md に Proposed で起票する。観点リストから 3 観点を選び、1 回の実行で 3 件まで起票する。「改善点を洗い出して起票して」「技術的負債を棚卸しして」「改善ネタを積んで」のように、調査結果をタスク化したいときに使用する。improvement ループの入口であり、起票したタスクは人間が To Do に上げるまで着手されない。特定の不具合の修正依頼や、起票を伴わないレビューには使わない。
---

# improvement-scout

コードベースを探索し、改善候補を選別して Backlog.md に `Proposed` で起票する。
成果物はタスクだけである。このスキルの中でコードは変更しない。

## ループ内の位置

| status | 意味 | 動かす主体 |
| --- | --- | --- |
| `Proposed` | 起票された改善候補。未承認 | **scout が起票する** |
| `To Do` | 着手が承認された | 人間 |
| `In Progress` | 作業ブランチに引き渡し済み | improvement-orchestrator |
| `In Review` | 実装がブランチに乗り、レビュー待ち | improvement-work |
| `Reviewed` | 人間のレビューが済み、マージを待っている | 人間 |
| `Done` | main にマージ済み | `auto_merge_reviewed` 次第（orchestrator または人間） |

`Proposed` から先には進めない。人間が内容を確認して `To Do` に上げたものだけが improvement-orchestrator に拾われる。
このスキルは起票までで終わる。承認を促したり、自分で `To Do` に上げたりしない。

使わない場面：

- 特定の不具合を直す依頼（起票せず直接修正する）
- 起票を伴わないレビューや説明の依頼
- Backlog.md が未導入のリポジトリ。`backlog task list --plain` が「No Backlog.md project found」を返すなら、`backlog init` してよいかユーザーに確認する

## 引数

`[観点スラッグ...] [パスや範囲] [--count N]` を任意で受ける。

- 観点が指定されればそれを使う。指定がなければ後述の規則で 3 観点選ぶ。
- 範囲が指定されなければリポジトリ全体を対象とし、エントリポイントとセットアップ経路、直近で変更が多い領域を優先する。
- `--count` が指定されなければ起票は 3 件。超えた候補は起票せず報告に列挙する。

## 1. 前提を確認する

- `backlog instructions overview` と `backlog instructions task-creation` を読む。プロジェクトの規約が優先される。
- `backlog config get statuses` を実行し、`Proposed` があるか確認する。ない場合は `.backlog/config.yml`（または `backlog/config.yml`）の `statuses` に `Proposed` を先頭で追加する。`statuses` は `backlog config set` では変更できず、backlog 自身が config ファイルの直接編集を案内する。設定にない status を渡すと作成が失敗する。
- `backlog config get types` と `backlog config get priorities` で使える値を確認し、以降その値だけを渡す。
- backlog の読み取り系コマンドには必ず `--plain` を付ける。付けないと対話 UI が起動してセッションが止まる。`backlog task create` はタイトルを引数で渡す（省略すると対話プロンプトになる）。

## 2. 観点を 3 つ選ぶ

観点リストは `.claude/skills/improvement-scout/viewpoints.md` にある。まず読む。

選定は、これまでの起票が少ない観点を優先する。使用履歴は `viewpoint:<slug>` ラベルで backlog 側に残っているので、別の状態ファイルは持たない。

```bash
for v in $(grep -oE '^## [a-z-]+' .claude/skills/improvement-scout/viewpoints.md | cut -d' ' -f2); do
  printf '%s\t%s\n' "$v" "$(backlog task list --labels "viewpoint:$v" --plain 2>/dev/null | grep -c 'TASK-')"
done
```

- 件数が少ない観点から 3 つ取る。同数のときは今回の対象範囲に効きそうなものを選ぶ。
- 全観点が同程度に消化されているときは、直近のコミットが触っている領域に関係する観点を選ぶ。
- 選んだ理由を 1 行で言えるようにする。報告に書く。

## 3. 既存タスクと照合する

同じ内容が既に追跡されていないか、起票の前に必ず確認する。

```bash
backlog task list --plain
backlog search "<キーワード>" --plain
backlog search --modified-file <対象パス> --plain
```

- 同じ内容のタスクがあれば起票しない。`Proposed` のまま残っている候補も対象に含めて数える。
- 既存タスクに足すべき情報があるときは `backlog task edit TASK-<n> --comment '<追記>' --comment-author @<name>` にとどめる。説明や受入基準の書き換えはユーザーに確認してから行う。
- `Proposed` が溜まりすぎている（目安 10 件超）なら、新規起票の前にその事実を報告する。積み増しより承認待ちの解消が先である。

## 4. 調査する

先に全体像を掴む。宣言（ドキュメント、設定、lock、スクリプト）と実態のずれに実際の不具合が出る。

```bash
git log --oneline -20
git ls-files
```

README、CLAUDE.md、セットアップスクリプト、CI 設定、lint / フォーマッタ設定を読み、宣言されている前提を把握してから、その前提が守られているかを見る。

そのうえで、選んだ 3 観点の「問い」に順に答える。観点ごとに最も強い候補を 1 件立てるのが基本形である。

起票しないもの：

- 好みのリファクタ、命名やスタイルの揺れ、抽象化の追加。
- 「〜かもしれない」で終わる推測。確認できないなら確認する。確認できないなら候補から落とす。
- 動いている実装の全面書き換え提案。
- 失敗経路を示せない「読みにくさ」。
- 観点リストの「除外」に該当するもの。

候補ごとに、確認できることは確認する。該当ファイルを読み切る、コマンドを実行して挙動を見る、`git log -- <path>` で経緯を見る。意図的にそうなっている可能性を排除してから起票する。

## 5. 選別する

起票の閾値は「HOW を考える必要があるか」。

- 考える必要がある（調査、判断、影響範囲の確認が伴う）＝起票する。
- その場の 1 行修正で終わる＝起票せず報告に列挙し、直すかをユーザーに聞く。

優先度の目安：

- `High`：壊れている、環境やデータを壊す、秘密情報が露出している。
- `Medium`：特定条件で失敗する、宣言と実態が乖離していて他の人が踏む。
- `Low`：今は動くが将来の事故の芽。

影響を言葉にできない候補は `Low` にせず落とす。3 件に届かないなら届かないまま報告する。数を埋めるための起票をしない。

## 6. 起票する

1 件 = 1 コマンド。指摘を 1 タスクに詰め込まない。

```bash
backlog task create '<何をどうするかが分かる動詞句>' \
  -s Proposed \
  --type <bug|chore|enhancement|feature|docs|spike> \
  --priority <High|Medium|Low> \
  --labels 'audit,viewpoint:<slug>' \
  --modified-file <根拠のパス> \
  -d '## 現状
<file:line を挙げて、いま何がどうなっているか>

## 問題
<どの条件で誰が何に困るか>

## 期待する結果
<満たされるべき状態。実装方法は書かない>

## 確認したこと
<読んだファイル、実行したコマンドとその結果>' \
  --ac '<検証可能な条件>' \
  --ac '<検証可能な条件>' \
  --plain
```

規約：

- 引数は単一引用符で囲む。バッククォートを含む文字列を二重引用符に入れるとシェルがコマンド置換として実行してしまい、原文が復元できない。
- 複数行の description は引用符の中に実際の改行を入れる。`\n` は展開されない。
- `-s Proposed` を明示する。`default_status` に依存しない。
- `--labels 'audit,viewpoint:<slug>'` を必ず付ける。`audit` で監査由来のタスクを、`viewpoint:` で観点の消化状況を追える。
- `--modified-file` に根拠のファイルを入れる。次回以降 `backlog search --modified-file <path> --plain` で重複を検出できる。
- 受入基準は振る舞いで書く。「関数を追加する」ではなく「〜のとき〜になる」。実装手順を受入基準にしない。
- `--plan` は書かない。着手時に improvement-work が調べ直して記録する。
- `## 確認したこと` には実際に見た根拠だけを書く。ここが書けない候補は起票の条件を満たしていない。
- 依存関係を付けるときは前提側を先に作り、出力の ID を控えてから後続に `--dep TASK-<n>` を渡す。存在しない ID を渡すと作成自体が失敗する。

## 7. 報告する

1. 選んだ 3 観点と、選んだ理由。
2. 起票したタスクの一覧。ID、タイトル、優先度、観点、根拠の `file:line`。
3. 承認の手順を添える：着手させるなら `backlog task edit TASK-<n> -s "To Do"`、不要なら `backlog task archive TASK-<n>`。
4. 起票しなかった軽微な指摘を箇条書きで示し、直すかをユーザーに聞く。
5. 件数上限で落とした候補があれば、件数と概要を書く。

タスク本文と報告の言語は会話の言語に合わせる。既存タスクがあるならその言語に合わせる。

## 禁止事項

- `.backlog/`（または `backlog/`）配下の md を直接編集しない。追加も更新もアーカイブも `backlog` CLI 経由で行う。config.yml は例外で、`statuses` の追加のみ直接編集してよい。
- 起票したタスクを自分で `To Do` に上げない。承認は人間の役割である。
- 監査の中でコードを変更しない。修正は起票したタスクの実行として行われる。
- 未確認の推測を起票しない。根拠のない指摘は、起票しないより悪い。
