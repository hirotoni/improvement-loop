# improvement ループの状態遷移表（正本）

improvement ループが使う6状態の名称・意味・「動かす主体」の正本。
`improvement-scout` / `improvement-scout-major` / `improvement-add` / `improvement-dispatch` / `improvement-work` の
各 `SKILL.md` は、ステータスの定義を手元に複製せず、この表を単一情報源として参照する。
5ファイルを直接編集する前に必ずこの表を更新すること。

## ステータス名の一致先

ここに列挙するステータス名の集合・順序は、`bin/setup-improvement-loop` の `REQUIRED_STATUSES` 配列と一致させる
（新規リポジトリに improvement ループをセットアップする際、`.backlog/config.yml` の `statuses` にこの順で補完される
名前の一覧）。

```
REQUIRED_STATUSES=(Proposed "To Do" "In Progress" "In Review" Approved Done)
```

この配列を変更しないままステータス名だけをこの表で変えることはできない。名称を変える場合は
`bin/setup-improvement-loop` の `REQUIRED_STATUSES` を先に（または同時に）更新し、`bash tests/run.sh` が
通ることを確認する。

## 状態遷移表

| status | 意味 | 動かす主体 |
| --- | --- | --- |
| `Proposed` | 起票された改善候補。未承認 | improvement-scout / improvement-scout-major / improvement-add のいずれかが起票する |
| `To Do` | 着手が承認された | 人間 |
| `In Progress` | 作業ブランチに引き渡し済み | improvement-dispatch |
| `In Review` | 実装がブランチに乗り、レビュー待ち | improvement-work |
| `Approved` | 人間のレビューが済み、マージを待っている | 人間 |
| `Done` | main にマージ済み | `auto_merge_reviewed`（`.backlog/config.my.yml` の `improvement_loop` 設定値）次第で improvement-dispatch または人間。既定値 `false` では人間が PR でマージした後 `Done` にする。`true` では improvement-dispatch がローカルで main にマージして `Done` にする |

補足（各行の「動かす主体」列について）：

- `Proposed`：起票元は3スキルある。`improvement-scout` は探索から選んだ最大3件、`improvement-scout-major` は
  milestone とその配下のタスク群、`improvement-add` は人間から伝えられた要望をそのまま起票する。いずれも
  `Proposed` から先には自分で進めない。
- `To Do`：`Proposed` を `To Do` に上げるのは人間である。これが承認の意味を持つ。improvement-work は
  「承認は既に済んでいる」前提でこの遷移を扱う。
- `In Progress`：作業ブランチ・ワークツリーを用意し、improvement-work サブエージェントに引き渡すのは
  improvement-dispatch である。
- `In Review`：実装・検証・コミットを終えてこの状態にするのは improvement-work である。`Done` にはしない。
- `Approved`：`In Review` を `Approved` に上げるのは人間である。improvement-dispatch はレビューを代行しない。
- `Done`：`Approved` になったタスクの扱いは調整値 `auto_merge_reviewed` で分岐する。`false`（既定）は
  GitHub 上の PR ベース運用を前提とし、人間が PR でマージした後 `Done` にする。`true` は PR を運用しない
  前提で、improvement-dispatch がローカルで main にマージしてから `Done` にする（`push` はしない）。
