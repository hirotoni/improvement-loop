---
name: improvement-scout-major
description: コードベースを探索し、アーキテクチャ級の大きい改善候補を見つけたら、milestone を起票してから、その配下に実装可能粒度まで分解した複数のタスクを依存関係（--dep）付きで Backlog.md に Proposed で起票する。既存 improvement-scout との違いは対象規模と起票の形である。improvement-scout は milestone を使わず 1 回の実行で独立した最大 3 件を起票するのに対し、こちらはモジュール間の責務境界の再編、状態遷移モデルの整合性、複数コンポーネント間の契約変更、データ/設定スキーマの移行、決定論的処理とAI裁量処理の分離、内部処理パイプラインの再設計、CI/CD・検証パイプラインの設計など、1 タスクでは完結せず複数タスクへの分割と依存順の実行計画が要る規模の候補だけを扱う。「大きな改善を段取りして起票して」「アーキテクチャの見直しをmilestoneに分けて積んで」のように、規模の大きい改善候補を計画的に分解して起票したいときに使用する。1 タスクで完結する規模の指摘には使わない（improvement-scout を使う）。
---

# improvement-scout-major

コードベースを探索し、アーキテクチャ級の大きい改善候補を見つけたら、milestone を 1 つ起票し、
その配下に実装可能粒度まで分解した複数のタスクを、依存関係があれば `--dep` を付けて `Proposed` で起票する。
成果物は milestone とタスクだけである。このスキルの中でコードは変更しない。

## improvement-scout との違い

| | improvement-scout | improvement-scout-major |
| --- | --- | --- |
| 対象規模 | 1 タスクで実装まで完結する | 複数タスクへの分割と依存順の実行計画が要る |
| 観点 | `viewpoints.md` の 13 観点から 3 つ選ぶ | `viewpoints.md`（本スキル）の 7 観点すべてを対象にする |
| 起票の形 | 独立したタスクを 1 回の実行で最大 3 件 | milestone 1 件 ＋ その配下のタスク複数件（依存関係付き） |
| 起票の閾値 | HOW を考える必要があるか | 複数タスクに分けないと安全に進められない規模か |

同じジャンルの問題（例：責務の重複）でも、1 タスクで閉じる規模なら `improvement-scout` の対象であり、
複数タスクへの分割と依存関係の設計が要る規模だけがこのスキルの対象になる。境界はジャンル単独ではなく、ジャンル＋規模の複合で引く。
各観点の「除外」欄にもこの基準を明記している。

## ループ内の位置

状態遷移表の正本は `claude-skills/status-table.md` にある。まず読む。**このスキルが動かすのは `Proposed`（scout-major が起票する）である。**

`Proposed` から先には進めない。人間が milestone とタスクの内容を確認して個々のタスクを `To Do` に上げたものだけが improvement-dispatch に拾われる。
このスキルは起票までで終わる。承認を促したり、自分で `To Do` に上げたりしない。
`improvement-dispatch` は `Dependencies` が `Done` になっていない `To Do` タスクを既に自動的に除外する仕組みを持つため、依存関係を付けて起票するだけで実行順は dispatch 側が守る。dispatch・work・既存 scout に変更は要らない。

使わない場面：

- 1 タスクで完結する規模の改善候補（`improvement-scout` を使う）。
- 特定の不具合を直す依頼（起票せず直接修正する）。
- 起票を伴わないレビューや設計相談。
- Backlog.md が未導入のリポジトリ。`backlog task list --plain` が「No Backlog.md project found」を返すなら、`backlog init` してよいかユーザーに確認する。

## 引数

`[観点スラッグ...] [パスや範囲] [--count N]` を任意で受ける。

- 観点が指定されればそれに絞る。指定がなければ 7 観点すべてを調査対象にする（`improvement-scout` と異なり、観点数が少ないため事前の絞り込みは行わない）。
- 範囲が指定されなければリポジトリ全体を対象とし、複数モジュールにまたがる構造・状態管理・パイプラインの定義箇所を優先する。
- `--count` が指定されなければ起票は milestone 1 件。超えた候補は起票せず報告に列挙する。1 milestone あたりのタスク数に上限は設けない（分解の結果として決まる）。

## 1. 前提を確認する

- `backlog instructions overview` と `backlog instructions task-creation` を読む。プロジェクトの規約が優先される。
- `backlog config get statuses` を実行し、`Proposed` があるか確認する。ない場合は `.backlog/config.yml`（または `backlog/config.yml`）の `statuses` に `Proposed` を先頭で追加する。`statuses` は `backlog config set` では変更できず、backlog 自身が config ファイルの直接編集を案内する。設定にない status を渡すと作成が失敗する。
- `backlog config get types` と `backlog config get priorities` で使える値を確認し、以降その値だけを渡す。
- `backlog milestone add --help` と `backlog task create --help` で `-m/--milestone`・`--dep/--depends-on` が使えることを確認する。
- backlog の読み取り系コマンドには必ず `--plain` を付ける。付けないと対話 UI が起動してセッションが止まる。`backlog task create`・`backlog milestone add` はタイトル・名前を引数で渡す（省略すると対話プロンプトになる）。

## 2. 観点に目を通す

観点リストは `.claude/skills/improvement-scout-major/viewpoints.md` にある。まず読む。

`improvement-scout` と異なり選定の絞り込みは行わない。7 観点すべての「問い」を対象コードベースに当ててみて、
複数タスクへの分割が要る強い候補があるかを見る。無理に各観点から候補を出す必要はない。該当なしのまま終わる観点があってよい。

## 3. 既存タスク・milestone と照合する

同じ内容が既に追跡されていないか、起票の前に必ず確認する。

```bash
backlog milestone list --plain
backlog task list --plain
backlog search "<キーワード>" --plain
backlog search --modified-file <対象パス> --plain
```

- 同じ趣旨の milestone・タスクが既にあれば起票しない。`Proposed` のまま残っている候補も対象に含めて数える。
- 既存の milestone・タスクに足すべき情報があるときは `backlog task edit TASK-<n> --comment '<追記>' --comment-author @<name>` にとどめる。説明や受入基準の書き換えはユーザーに確認してから行う。
- `Proposed` が溜まりすぎている（目安 10 件超）なら、新規起票の前にその事実を報告する。積み増しより承認待ちの解消が先である。

## 4. 調査する

先に全体像を掴む。宣言（ドキュメント、設定、エントリポイント）と実態のずれ、および複数モジュールにまたがる構造に実際の事故が出る。

```bash
git log --oneline -30
git ls-files
```

README、CLAUDE.md、セットアップスクリプト、CI 設定、主要なモジュールのエントリポイントを読み、
モジュール構成・状態管理・処理フロー・パイプライン構成の全体像を把握してから、観点ごとの「問い」に答える。

起票しないもの：

- 好みのリファクタ、命名やスタイルの揺れ、抽象化の追加。
- 「〜かもしれない」で終わる推測。確認できないなら確認する。確認できないなら候補から落とす。
- 動いている実装の全面書き換え提案で、分割の必要性を具体的に説明できないもの。
- 1 タスクで実装まで完結する規模のもの（`improvement-scout` に譲る）。
- 観点リストの「除外」に該当するもの。

候補ごとに、確認できることは確認する。該当ファイルを読み切る、コマンドを実行して挙動を見る、`git log -- <path>` で経緯を見る。意図的にそうなっている可能性を排除してから起票する。

## 5. 選別する

起票の閾値は「複数タスクへの分割と依存順の実行計画が要る規模か」。

- 実装可能粒度への分解、依存関係の整理、段階的な移行計画が要る＝milestone として起票する。
- 分解しなくても 1 タスクで実装まで完結する＝起票せず、報告で `improvement-scout` 向けの候補として挙げる。

優先度の目安（milestone・配下タスク共通）：

- `High`：現状のまま放置すると壊れやすい構造上の欠陥、または既に事故が起きている構造。
- `Medium`：特定の変更を行おうとするたびに複数箇所を手で合わせる必要があり、今後も繰り返し踏まれる。
- `Low`：今は動くが、将来この構造のまま拡張すると破綻する芽。

影響を言葉にできない候補は `Low` にせず落とす。`--count` に届かないなら届かないまま報告する。数を埋めるための起票をしない。

## 6. milestone とタスクを起票する

1 candidate = 1 milestone。milestone に値しない指摘を無理に milestone 化しない。

### 6.1 milestone を起票する

```bash
backlog milestone add '<何を再編・移行するかが分かる名詞句>' \
  -d '## 現状
<file:line を挙げて、いま何がどうなっているか>

## 問題
<この規模で直す必要がある理由。1タスクで閉じない根拠>

## 期待する結果
<milestone全体が完了したときに満たされるべき状態。実装方法は書かない>

## 確認したこと
<読んだファイル、実行したコマンドとその結果>'
```

出力される milestone の ID・タイトルを控える。以降のタスク起票で `-m` に渡す。

### 6.2 実装可能粒度に分解する

各タスクは 1 回の `improvement-work` 実行（1 スライスずつ実装し検証する単位）で完結する粒度にする。
`improvement-scout` の起票の閾値（HOW を考える必要があるか）を、milestone 配下の個々のタスクにも適用する。
1 タスクが大きすぎるなら、さらに分ける。

### 6.3 依存関係を洗い出し、循環を作らずに起票する

- 依存グラフを先に紙上で（実際にはこのやり取りの中で）組み立て、有向非巡回（DAG）になっているか確認してから起票を始める。あるタスクが直接・間接に自分自身へ依存する形を作らない。
- 前提となるタスクを先に起票し、`backlog task create` の出力から実際に割り振られたタスク ID を控える。存在しない ID を `--dep` に渡すと作成自体が失敗するため、必ず先行タスクの起票完了後に後続タスクを起票する。
- 依存が無いタスク同士（同じ milestone 内で並行して着手できるもの）には `--dep` を付けない。

```bash
backlog task create '<何をどうするかが分かる動詞句>' \
  -s Proposed \
  --type <bug|chore|enhancement|feature|docs|spike> \
  --priority <High|Medium|Low> \
  --labels 'audit,viewpoint:<slug>' \
  --modified-file <根拠のパス> \
  -m '<6.1で控えたmilestoneのIDまたはtitle>' \
  --dep TASK-<先行タスクのID> \
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
- `-m` は milestone 配下の全タスクに必ず付ける。同じ milestone 名・ID を使い、途中で表記を揺らさない。
- 依存があるタスクだけ `--dep TASK-<n>` を付ける。複数の前提があるときは `--dep TASK-<a> --dep TASK-<b>`（または `--depends-on TASK-<a>,TASK-<b>`）のように複数渡せる。
- `--modified-file` に根拠のファイルを入れる。次回以降 `backlog search --modified-file <path> --plain` で重複を検出できる。
- 受入基準は振る舞いで書く。「関数を追加する」ではなく「〜のとき〜になる」。実装手順を受入基準にしない。
- `--plan` は書かない。着手時に improvement-work が調べ直して記録する。
- `## 確認したこと` には実際に見た根拠だけを書く。ここが書けない候補は起票の条件を満たしていない。

## 7. 報告する

1. 起票した milestone。ID、タイトル、対象観点、根拠の `file:line`。
2. 起票したタスクの一覧。ID、タイトル、優先度、観点、依存関係（どの TASK-ID に依存するか）。依存グラフが追えるように、依存の無いタスク（先頭で着手可能なもの）を明示する。
3. 承認の手順を添える：milestone 配下のタスクを着手させるなら `backlog task edit TASK-<n> -s "To Do"`（依存元から順に）、milestone ごと不要なら `backlog milestone remove <milestone名>` の要否を人間に確認する。
4. milestone に値しなかった小粒度の指摘を箇条書きで示し、`improvement-scout` での起票候補としてユーザーに伝える。
5. 件数上限（`--count`）で落とした milestone 候補があれば、件数と概要を書く。

milestone・タスク本文と報告の言語は会話の言語に合わせる。既存タスクがあるならその言語に合わせる。

## 禁止事項

- `.backlog/`（または `backlog/`）配下の md を直接編集しない。追加も更新もアーカイブも `backlog` CLI 経由で行う。config.yml は例外で、`statuses` の追加のみ直接編集してよい。
- 起票した milestone・タスクを自分で `To Do` に上げない。承認は人間の役割である。
- 依存グラフに循環を作らない。起票前に依存の向きを確認する。
- 監査の中でコードを変更しない。修正は起票したタスクの実行として行われる。
- 未確認の推測を起票しない。根拠のない指摘は、起票しないより悪い。
- `improvement-scout`・`improvement-dispatch`・`improvement-work` を変更しない。既存の依存解決ロジックのみでこのスキルの出力を消化できる。
