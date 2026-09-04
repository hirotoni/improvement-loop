---
name: improvement-dispatch
description: Backlog.md のタスク状態を見て improvement ループを制御する。To Do のタスクがあれば作業ブランチを作り、サブエージェントに improvement-work を引き渡す。`/loop` から定期起動される前提。「改善ループを回して」「backlog の To Do を順に進めて」のように、起票済みタスクの消化を自走させたいときに使用する。オーケストレーションに徹し、実装作業そのものは行わない。
---

# improvement-dispatch

Backlog.md の状態を読み、次に何を動かすかを決める。
1 回の起動でやることは「状態を読む」「レビュー済みを扱う（設定により main にマージする）」「必要なら 1 件引き渡す」「次の起動を決める」の 4 つだけである。

**自分で実装しない。** コードの編集、テストの修正、リファクタは improvement-work の仕事である。
引き渡しのために調べる（対象ファイルの特定、依存の確認、リポジトリ規約の抽出）のは構わない。

## ループ内の位置

状態遷移表の正本は `claude-code/skills/status-table.md` にある。まず読む。**このスキルが動かすのは `In Progress`（dispatch が動かす）と、`auto_merge_reviewed` 次第の `Done`（dispatch または人間）である。**

`Proposed` を `To Do` に上げるのは人間である。承認を代行しない。
`In Review` を `Approved` に上げるのも人間である。レビューを代行しない。
`Approved` になったものの扱いは `auto_merge_reviewed`（調整値、既定 `false`）で分岐する（手順 3）。

- `auto_merge_reviewed: true` のとき。このリポジトリは PR を運用していない前提であり、dispatch が `Approved` を検知するとローカルで main にマージし、`Done` にする。マージまで進め、`push` はしない。
- `auto_merge_reviewed: false`（既定）のとき。このリポジトリは GitHub 上で PR ベースの開発フローを運用している前提であり、dispatch は `Approved` を検知しても main にマージしない。人間が PR で正規にレビュー・マージし、その後 `Done` にする。

## 調整値

上限は `.backlog/config.my.yml` の `improvement_loop` で設定する。手順 1 で読み、以降の判断にはこのファイルの値を使う。散文に書かれた数字を根拠にしない。

| キー                   | 意味                                                              | 既定値  |
| ---------------------- | ----------------------------------------------------------------- | ------- |
| `max_in_review`        | この件数以上 `In Review` が溜まっていたら新規の引き渡しを止める   | 3       |
| `max_in_progress`      | 同時に `In Progress` にできる件数                                 | 1       |
| `max_redispatch`       | 同じタスクを再引き渡しできる回数                                  | 2       |
| `auto_merge_reviewed`  | `Approved` を検知したとき main に自動マージするかどうか（手順 3）。あわせて手順 5 のワークツリーの起点の決め方も変える（`true` は push しない前提なのでローカルのデフォルトブランチを見る） | `false` |
| `worktree_base_dir`    | ワークツリーの作成先ベースディレクトリ（手順 5）。配下にさらにリポジトリ名で名前空間分けされる | `""`（= リポジトリルート/`.worktree`） |
| `forbidden_paths`      | AIエージェントが変更してはいけないパスのリスト（前方一致）。手順 5 の引き渡しプロンプトに反映され、improvement-work の手順 8 と dispatch の手順 6 で機械的に照合される | `[]`（制限なし） |
| `allowed_paths`        | AIエージェントが変更してよいパスのリスト（前方一致）。手順 5 の引き渡しプロンプトに反映され、improvement-work の手順 8 と dispatch の手順 6 で機械的に照合される | `[]`（制限なし） |

ファイルが存在しない場合、`improvement_loop` が無い場合、個別のキーが欠けている場合は、それぞれ既定値を使う。読めなかった旨を報告に 1 行添えること。値の変更は直接編集で行う。`backlog config set` は `config.yml` 側の設定を触るもので、このファイルには効かない。

`forbidden_paths` / `allowed_paths` は二層で効く。1つ目は AIエージェント（improvement-work やその配下で動く実装パス）への指示で、手順 5 の引き渡しプロンプトに明記される。2つ目は機械的な照合で、improvement-work の手順 8（コミット直前）と dispatch の手順 6（完了検証）が `check-forbidden-allowed-paths` に変更ファイル一覧を渡し、一致すれば `RESULT: VIOLATION` としてコミット・完了が止まる。ただし照合に渡す変更ファイル一覧は呼び出し側 2 箇所とも `git diff` から作るため、機械的に止まるのは git の追跡対象パスへの変更だけである。git 管理外のパス（`.backlog/` 配下、`.claude/skills/<スキル名>` 配下、`.git/` 配下）は差分に一度も現れないので、ここに書いても機械的には止まらず、1つ目の指示としてのみ効く。この限界の詳細は `.backlog/config.my.yml` の当該キーのコメント（配布元テンプレートは `backlog-md/config.my.yml`）にある。両方とも空、またはキー自体が無い場合は制限なく動作する（従来どおり）。両方が設定されている場合は「`allowed_paths` の範囲内、かつ `forbidden_paths` に無いパス」に変更を留めるよう指示する（手順 5 参照）。

`.backlog/` は `.git/info/exclude` に登録され除外されるため、このファイルはバージョン管理されない。新しい機体では存在しないのが正常であり、その場合は既定値で動く。

## 起動ごとの手順

### 1. 状態を読む

```bash
backlog task list --plain
git status --porcelain
git branch --show-current
git worktree list
cat .backlog/config.my.yml 2>/dev/null   # 無ければ調整値は既定値を使う
```

進行中のサブエージェントがあるかも確認する。稼働中のサブエージェントの列挙には `ListAgents` を使う（ツール一覧に最初からあり、schema のロードは要らない）。個々のサブエージェントの出力を見るときは `TaskOutput` を使う（schema が未ロードなら `ToolSearch` で `select:TaskOutput` を取得する）。`ToolSearch` の `select:` は、存在しないツール名を渡されても何の診断も出さず無音で欠落させるだけである。だからここには実在するツール名しか書かない（以前は実在しないツール名が書かれており、取得できていないことに気付けないまま手順 2 の判定材料が1つ欠けていた。TASK-88）。`ListAgents` が示す running/completed（busy/idle）の表示は、同一サブエージェントに対してすら呼び出しごとに running→completed→running のように矛盾して変化することが実際に観測されている。次の手順 2 で判定するときも、この表示は補助情報にとどめ、単独の根拠にしない。

### 2. 進行中のものを突合する

`In Progress` のタスクがある場合、次の優先順位で状態を判定する。**`ListAgents` の running/completed（busy/idle）表示だけを根拠に完了・停止を断定しない。**

#### 2-1. 完了の確定

次のいずれかが得られたときに限り「完了している」と確定し、手順 6 の検証に進む。

- 対応するサブエージェントからの `task-notification` が実際に届いている。
- ブロッキングな `TaskOutput` 呼び出しが完了応答を返した。
- 上記が無くても、`backlog task view TASK-<n> --plain` の notes/ステータスに検証記録（テスト実行結果、レビュー結果、`In Review` への遷移など）がすでに残っている。

#### 2-2. 稼働中の確認

2-1 が成立せず、`ListAgents` でそのサブエージェントがまだ動いている（running/busy）と分かる場合 → 今回の起動でやることはない。手順 7 に進む。

ただし、この「動いている」表示だけを鵜呑みにして無期限に信用しない。同じタスクについて起動のたびに「動いている」と表示され続けている一方で、2-3 の観測（コミットハッシュ・`git status --porcelain`）が全く変化していない場合は、その表示自体を疑い、2-2 で止まらず 2-3 の判定に進む。

#### 2-3. 判断の持ち越しと不在の確定

2-1 も 2-2 も成立しない場合（または 2-2 の「動いている」表示を疑うべき場合）、直ちに「存在しない」とみなして `To Do` へ差し戻さない。ワークツリーの実際の状態を確認してから判断する。

```bash
git worktree list
git -C <ワークツリーのパス> log -1 --format='%H %cI'   # 直近コミットのハッシュと時刻
git -C <ワークツリーのパス> status --porcelain          # 未コミットの変更の有無
date -u +%FT%TZ                                          # 今回の起動時刻（観測に記録する）
backlog task view TASK-<n> --plain                       # 前回この手順で記録した観測（あれば）を確認する
```

ワークツリーが `git worktree list` に存在しない場合は上記の `-C` が使えない。その場合は `git branch --list improvement/task-<n>-<スラッグ>` でブランチの有無を確認する。ブランチも残っていなければ、観測を待たずその時点で「存在しない」と確定してよい（ワークツリーとブランチの両方が消えているのは、作業途中で環境ごと失われたことの強い証拠である）。ブランチだけが残っている場合は、メインの作業木から `git log <作業ブランチ> --oneline -1` で得たコミットハッシュを観測値として使い、以降は同じ比較ロジックに従う。

- notes に前回の起動でこの手順が記録した観測（コミットハッシュ・`git status --porcelain` の内容・観測時刻）が無い、またはあっても今回のコミットハッシュか `git status --porcelain` の内容と異なる → 直近で変化があったということであり、まだ作業中の可能性が高いとみなす。そのタスクには触れず（`To Do` へ戻さない）、今回の観測を新しい記録として残し、手順 7 に進む。notes にはこの見出しの記録が複数回追記されて残ることがあるが、比較には常に notes 中でこの見出しが最後に現れる記録（＝直近に記録したもの）だけを使う。過去の記録が残っていても無視してよい。

  ```bash
  backlog task edit TASK-<n> --append-notes '### 手順 2 観測記録
  - commit: <ハッシュ> (<コミット時刻>)
  - status: <git status --porcelain の内容。無ければ (clean)>
  - 観測時刻: <今回の起動時刻>' --plain
  ```

- 直近の記録があり、かつコミットハッシュと `git status --porcelain` の内容が完全に一致する（＝直近の観測から変化が無い）→ その記録の観測時刻からの経過時間を見る。
  - 経過が 30 分未満 → まだ「存在しない」と断定しない。記録は上書きせずそのまま残し、判断を持ち越して手順 7 に進む。
  - 経過が 30 分以上 → ここで初めて「サブエージェントが存在しない（前回のセッションが落ちた、中断された）」と確定し、復旧する。

    1. `backlog task view TASK-<n> --plain` で notes と plan を読む。notes には引き渡し時のワークツリーのパス（`WORKTREE_DIR`）と作業ブランチ名（`BRANCH`）が残っているはずである。

    2. 復旧診断（ワークツリー・ブランチの有無、デフォルトブランチから見て新しいコミットがあるかの判定）は `.claude/skills/improvement-dispatch/scripts/check-progress-recovery` に切り出されている。散文を読んで毎回 `git worktree list` や `git log` を手で組み立てない。メインの作業木（このディレクトリ）から実行する。

       ```bash
       .claude/skills/improvement-dispatch/scripts/check-progress-recovery <ワークツリーのパス> <作業ブランチ> <デフォルトブランチ>
       ```

       標準出力には `RESULT` の前に次の判定材料の行が並ぶ。

       ```
       WORKTREE_EXISTS: true|false
       BRANCH_EXISTS: true|false
       NEW_COMMITS: <件数>|N/A
       OCCUPANCY_RECORD_EXISTS: true|false
       OCCUPANCY_AGE_SECONDS: <秒数>|N/A
       OCCUPANCY_FRESH: true|false|N/A
       RESULT: <値>
       ```

       `OCCUPANCY_*` は、ワークツリー直下の占有記録（`.worktree-occupancy`。`.claude/skills/improvement-dispatch/scripts/create-worktree` が引き渡し・再引き渡しのたびに上書きする。`TASK_ID`・`ASSIGNED_AT`・`ASSIGNED_AT_EPOCH` の3行）を読み、その `ASSIGNED_AT_EPOCH`（最後に `create-worktree` が実行された＝最後にこのワークツリーが引き渡された時刻）からの経過秒数が 1800 秒（30分）未満かどうかを示す。占有記録が無い、または読めない場合は `OCCUPANCY_RECORD_EXISTS: false` / `OCCUPANCY_AGE_SECONDS: N/A` / `OCCUPANCY_FRESH: N/A` となり、占有記録導入前と同じくコミット履歴のみの判定にフォールバックする。dispatch はこれらの行を個別に解釈する必要は無く、最後の行 `RESULT: <値>` だけで結果を判別すればよい（終了ステータスでも判別できる: 0=REUSE_WORKTREE_REDISPATCH, 1=RECREATE_WORKTREE_REDISPATCH, 2=REVERT_TO_TODO, 3=ERROR）。診断結果を出すのみで、backlog タスクのステータス変更や `git worktree add`/`remove` のような実際の変更操作はスクリプトの範囲外であり、次の対応表の通り dispatch が行う。

       | `RESULT` | 意味 | dispatch が行うこと |
       | --- | --- | --- |
       | `REUSE_WORKTREE_REDISPATCH` | 次のいずれか。(a) ワークツリー・ブランチともに存在し、デフォルトブランチから見て新しいコミットがある（＝実装が途中まで進んでいる）。(b) 新しいコミットは無いが、`OCCUPANCY_FRESH: true`（＝最後の引き渡しから30分未満）。この場合はコミットを伴わない長時間処理（大きなテスト実行など）が続いているだけで、実際には稼働中の可能性が高いとみなす。 | 既存のワークツリーをそのまま再利用し、その到達点を引き渡し情報に含めて手順 5 で再度引き渡す（手順 5 は `create-worktree` を経由するため、占有記録の `ASSIGNED_AT_EPOCH` もこの再引き渡しの時刻に更新される）。 |
       | `RECREATE_WORKTREE_REDISPATCH` | ワークツリーは無いがブランチが存在し、新しいコミットがある（ワークツリーが無い時点で占有記録は判定に使わない） | `git worktree prune` で古い管理情報を掃除した後、手順 5（`.claude/skills/improvement-dispatch/scripts/create-worktree`。ワークツリーは無くブランチだけ存在する場合、新規作成せず既存の作業ブランチを割り当てる）で作り直し、到達点を引き渡し情報に含めて再度引き渡す。 |
       | `REVERT_TO_TODO` | ブランチが存在しない。またはブランチはあるが新しいコミットが無く、かつ占有記録も新しくない（`OCCUPANCY_FRESH` が `false` または `N/A`）（＝コミット履歴からも占有記録からも活動が確認できない） | `backlog task edit TASK-<n> -s "To Do" --comment '引き渡し先が消失したため To Do に戻した' --comment-author @dispatch` で戻す。出力の `WORKTREE_EXISTS: true` でワークツリーが残っていると分かれば `git worktree remove <ワークツリーのパス>` で片付ける。 |
       | `ERROR` | 引数不正、対象リポジトリでない、デフォルトブランチが解決できない等 | 標準エラー出力の内容を確認する。 |

30 分という閾値は、この手順の中に独立して2箇所出てくる。ひとつは直前の「経過が 30 分以上」（dispatch 自身が notes のコミットハッシュ・`git status --porcelain` の記録から判定する、この復旧診断を呼び出すかどうかのゲート）、もうひとつは `check-progress-recovery` 内部の `OCCUPANCY_FRESH`（占有記録の `ASSIGNED_AT_EPOCH` からの経過。復旧診断を呼び出した後、新しいコミットが無い場合の判定に使う）である。両者は測る起点が異なる（前者はコミット・作業ツリー差分が最後に変化した時刻、後者は最後に `create-worktree` が実行された＝引き渡された時刻）。値をどちらも 1800 秒に揃えているのは、根拠となる手順 7 の起動間隔（後述）が共通だからであり、同じ1つの計測を指しているわけではない。

この 30 分という目安の根拠は手順 7 の起動間隔である。手順 7 では、サブエージェント稼働中の次回起動を保険として 1800 秒以上後に、承認待ち・レビュー待ちで動けないときは 1200〜1800 秒後にそれぞれ設定する目安を定めている。1 回の起動間隔が概ね 20〜30 分であることを踏まえ、記録した観測から 30 分以上が経過していれば、その間に少なくとも 1 回以上は別の起動を挟んでいる（＝複数回の起動にわたって同じ状態を確認した）とみなせる。

この基準はワークツリーの静けさをサブエージェントの生死の代理指標として使っているため、コミットを伴わない長時間の処理（大きなテスト実行など）が続いている場合には、「まだ生きているのに存在しないと誤判定し、再引き渡しした先で同一ワークツリーへの二重書き込みが起きる」リスクがある。占有記録（`.worktree-occupancy` と `OCCUPANCY_FRESH`、上の対応表参照）は、このリスクのうち「直近に引き渡し・再引き渡しされたばかりのワークツリーが、コミットを伴わない処理の間に誤って `REVERT_TO_TODO` されてしまう」場合を軽減する。ただし占有記録は `create-worktree` 実行のたびに丸ごと上書きされるだけで、作業の進行に合わせて継続的に更新されるハートビートではない。そのため、直近の引き渡しから 30 分を超えてなおコミットを伴わない処理（大きなテスト実行など）が続く場合は `OCCUPANCY_FRESH` も `false` になり、占有記録導入前と同じ誤判定のリスクがそのまま残る。この残余リスクを完全に無くす設計（例えば作業の進行に合わせて占有記録を継続的に更新するハートビート方式の導入）は現時点では未着手であり、必要になった際に別途タスク化する。

`In Progress` は同時に `max_in_progress` 件までとする。以前はメインの作業木を複数のサブエージェントで共有していたため、この上限がブランチの混線を防ぐ唯一の歯止めだった。手順 5 でタスクごとに独立したワークツリーへ分離した現在、その理由自体は成立しなくなっている。ただし値を引き上げるかどうかはこのタスクのスコープ外として据え置く（レビュー体制や運用実績を見て別途判断する）。

### 3. レビュー済みのものを扱う

`Approved` は人間のレビューが済んだ状態である。手順 4 の選定より先に処理する。

```bash
backlog task list --status "Approved" --plain
```

対象が無ければ手順 4 に進む。

対象があれば、`auto_merge_reviewed`（調整値、既定 `false`）の値で扱いが分かれる。

#### `auto_merge_reviewed: false`（既定）

main へのマージは行わない。このリポジトリは GitHub 上の PR ベースの開発フローを正規のルートとする前提であり、dispatch がそれを迂回してローカルで main を進めることはしない。

対象タスクは `Approved` のまま変更せず、一覧を報告するだけに留めて手順 4 に進む。マージも `Done` への変更も行わない。

`Approved` から `Done` への経路は人間が担う。

1. 人間が作業ブランチ（`improvement/task-<n>-<スラッグ>`）から PR を作成し、レビューと CI を経て GitHub 上で main にマージする。
2. マージ後、人間が次のコマンドで `Done` にする。

   ```bash
   backlog task edit TASK-<n> -s "Done" --comment 'PR で main にマージ済み' --comment-author @human --plain
   ```

3. 対応するワークツリー（既定では `<リポジトリルート>/.worktree/<リポジトリ名>/task-<n>-<スラッグ>`。配置場所は `worktree_base_dir` で変更できる）の後片付け（`git worktree remove`）も、この設定のときは dispatch ではなく人間が行う。dispatch は `auto_merge_reviewed: false` の間、`Approved`/`Done` のワークツリーを片付けない。

この設定のとき、手順 7 の「人間に必要な行動」に `Approved` の一覧を毎回含めて報告し、ループが `Approved` のまま滞留していても人間が次に何をすべきか（PR 作成・マージ・`Done` への変更）分かるようにする。

#### `auto_merge_reviewed: true`

現在の挙動を維持する。このリポジトリで PR を運用していない前提でのみ使う設定である。ここで main が進めば、後続の引き渡しは新しい main を基点にできる。

マージ判定（前提条件確認・ff-only 試行・3-way ドライラン・衝突判定・commit/abort・ワークツリーの片付け）は `.claude/skills/improvement-dispatch/scripts/merge-reviewed-branch` に切り出されている。散文を読んで毎回 git コマンドを組み立てない。対象は 1 件ずつ処理する。メインの作業木（人間や dispatch がいるこのディレクトリ）から実行する。

```bash
.claude/skills/improvement-dispatch/scripts/merge-reviewed-branch <作業ブランチ>
```

終了ステータスと、標準出力に現れる `RESULT: <値>` の行で結果を判別する。backlog タスクのステータス変更はスクリプトの責務外であり、次の対応表の通り dispatch が行う。

| 終了ステータス | `RESULT` | 意味 | dispatch が行うこと |
| --- | --- | --- | --- |
| `0` | `MERGED` | ff-only、または衝突のない 3-way でマージが完了した | `backlog task edit TASK-<n> -s "Done" --comment 'main にマージした（<出力中の main の短縮ハッシュ>）' --comment-author @dispatch` で `Done` にする。次の対象へ進む。 |
| `1` | `PRECONDITION_NOT_MET` | メインの作業木が汚れている／対象ブランチが存在しない／main との差分が無い、のいずれか | タスクは `Approved` のまま変更しない。標準エラー出力の内容を報告に含める。メインの作業木の汚れが原因の場合は他の対象を試しても同じ結果になるため、次の対象には進まず今回の起動を終える。 |
| `2` | `CONFLICT` | 3-way マージが衝突した（スクリプトが `git merge --abort` 済みで、git 状態はマージ前と同じ） | タスクは `Approved` のまま残し、標準エラー出力に列挙された衝突ファイルを報告する。解消は人間に委ねる。次の対象には進まない。 |
| `3` | `ERROR` | 想定外のエラー（引数不足、main への切り替え失敗、マージコミット自体の失敗等） | タスクは `Approved` のまま残し、標準エラー出力を報告する。次の対象には進まない。 |

`rebase` は使わない。人間がレビューしたコミットの同一性が変わるためである。`--force` を伴う操作もこのスクリプトでは行わない。

マージ後も `push` はしない。リモートへの反映は人間が行う。マージが完了した場合（`RESULT: MERGED`）のみ、スクリプトが対応するワークツリーのディレクトリを自動で片付け、続けて対応する作業ブランチ自体（`git branch -d`、安全削除のみ）も削除する。過去のコミットはマージ後の main から辿れるため、ブランチを残す必要はない。未コミットの変更が残っている等でワークツリーの片付けに失敗した場合、またはブランチが未マージ扱いになる等でブランチの削除自体に失敗した場合も、スクリプトは `--force`/`-D` せずその旨を出力するので、そのまま報告に含める（中身の破棄が必要かどうかの判断は人間に委ねる）。

処理後に `git log --oneline -1 main` で main の位置を確認し、報告に含める（スクリプトの出力にも短縮ハッシュが含まれる）。

### 4. 次に引き渡すタスクを選ぶ

選定ロジック（除外集合の計算、依存確認、優先度ソート、`max_in_progress`/`max_in_review` の閾値判定）は `.claude/skills/improvement-dispatch/scripts/select-next-task` に切り出されている。テキスト出力を手で読んで集合演算・ソートを組み立てない。手順 1 で読んだ `max_in_progress`（既定 1）・`max_in_review`（既定 3）の値をそのまま渡して呼ぶ。

```bash
.claude/skills/improvement-dispatch/scripts/select-next-task <max_in_progress> <max_in_review>
```

標準出力の1行目 `RESULT: <値>` で結果が分かる。終了ステータスでも判別できる（0=SELECTED, 1=GATED, 2=NO_CANDIDATE, 3=ERROR）。

- `RESULT: SELECTED` / `TASK_ID: TASK-<n>` → そのタスクを手順 5 で引き渡す。
- `RESULT: GATED` / `REASON: max_in_progress` → `In Progress` が上限に達している。今回は引き渡さず手順 7 に進む。
- `RESULT: GATED` / `REASON: max_in_review` → `In Review` が上限に達している。レビューが追いついていない。新規の引き渡しをせず、レビュー待ちの一覧を報告して手順 7 に進む。
- `RESULT: NO_CANDIDATE` → `To Do` に選べる候補が無い（`blocked:needs-decision` ラベル付き・依存タスク未完了のものを除いて残らない場合を含む）。手順 7 に進む。
- `RESULT: ERROR` → 引数不正など。標準エラーに詳細が出る。原因を確認する。

以前はメインの作業木が汚れている（`git status --porcelain` に出力がある）ことも引き渡しを止める条件だった。手順 5 は `git worktree add` でワークツリーの作成先ベースディレクトリ（既定ではリポジトリルートの `.worktree/`。`worktree_base_dir` で変更可能）配下の `<リポジトリ名>/` に新しいワークツリーを作るだけで、メインの作業木のブランチ切り替えや checkout の変更を伴わない。そのため人間がメインの作業木で未コミットの変更を持っていても新規タスクを引き渡せる。この条件は停止条件から外す（`.claude/skills/improvement-dispatch/scripts/select-next-task` もこの条件を見ない）。

### 5. ワークツリーを作って引き渡す

作業ブランチはメインの作業木の上には作らない。ワークツリーの作成先ベースディレクトリ（`improvement_loop.worktree_base_dir`。既定ではリポジトリルートの `.worktree/`）配下の `<リポジトリ名>/` に、タスクごとに独立したワークツリーを作る。リポジトリ名で名前空間分けすることで、同じ親ディレクトリを共有する兄弟リポジトリ同士でワークツリーのパスが衝突しない。この名前空間分けは `worktree_base_dir` の値を変えても常に適用される。この操作はメインの作業木のブランチ切り替えや checkout の変更を伴わないため、人間がメインの作業木で作業中でも実行できる。

ワークツリー作成の一連の処理（`worktree_base_dir` の解決・正規化、リポジトリ内外判定つき `.git/info/exclude` への追記、デフォルトブランチの判定、`git worktree add`、`.backlog` シンボリックリンクの作成）は `.claude/skills/improvement-dispatch/scripts/create-worktree` に決定論的なスクリプトとして切り出されている（`.claude/skills/improvement-dispatch` は `claude-code/skills/improvement-dispatch` ディレクトリ丸ごとへのシンボリックリンクであり、`scripts/` サブディレクトリごと配布される）。dispatch はこれを都度読み取って組み立てる必要は無く、次のように1回実行するだけでよい。

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)" && \
"$REPO_ROOT/.claude/skills/improvement-dispatch/scripts/create-worktree" task-<n>-<英小文字のスラッグ> && \
backlog task edit TASK-<n> -s "In Progress" -a @improvement-work --plain
```

`.claude/skills/improvement-dispatch/scripts/create-worktree` は `.backlog/config.my.yml` の `improvement_loop.worktree_base_dir` と `improvement_loop.auto_merge_reviewed` を自分で読み、標準出力に次を出力する。

```
RESULT: <OK | STALE_BASE>
BASE_REF=<採用した起点の参照名>
BASE_COMMIT=<その短縮ハッシュ。解決できない場合は N/A>
WORKTREE_DIR=<作成/再利用したワークツリーの絶対パス>
BRANCH=<割り当てた作業ブランチ名>
```

`RESULT: STALE_BASE` のときは、`BASE_COMMIT` と `WORKTREE_DIR` の間に理由と欠けているコミット数が1件1行で入る（複数該当する場合は複数行になる）。

```
STALE_REASON=<reused_branch_behind_base | diverged_default_branch | branch_behind_default_branch | base_ref_unresolved>
MISSING_COMMITS=<参照名>:<含まれていないコミット数>
```

以前の `worktree_base_dir` に対応する除外行が `.git/info/exclude` に残っている場合は、`RESULT` の値にかかわらず（`OK` でも `STALE_BASE` でも）次の行が同じ区間に入る。

```
STALE_EXCLUDE=<残っている除外行>:<added_by_improvement_loop | preexisting>
```

`WORKTREE_DIR` と `BRANCH` が標準出力の最後の2行であることは変わらない。

`&&` でつないでいるため、`create-worktree` が失敗（非ゼロ終了）した場合は後続の `backlog task edit` は実行されない。同じタスク番号・スラッグで再実行しても、既存のワークツリー・ブランチ・exclude の記述を再利用し、エラーにならない（冪等性は `.claude/skills/improvement-dispatch/scripts/create-worktree` 内で保証されている）。

デフォルトブランチ名の判定は `git symbolic-ref --short refs/remotes/origin/HEAD` に依存する。この参照が設定されていないリモート環境では `.claude/skills/improvement-dispatch/scripts/create-worktree` 内部で `main` にフォールバックする。実際のデフォルトブランチが `main` 以外の場合は、`.claude/skills/improvement-dispatch/scripts/create-worktree` 側のこのフォールバック値を書き換える。

出力された `WORKTREE_DIR` と `BRANCH` の値は、以降の手順（サブエージェントへの引き渡しプロンプト、`--append-notes` への記録）でリテラルな文字列として使う。シェル変数として次の呼び出しに持ち越そうとしない。

新しいワークツリーの起点は `auto_merge_reviewed` の値で決まる（TASK-75）。

- `auto_merge_reviewed: false`（既定・PR 運用）。フェッチできれば `origin/<デフォルトブランチ>` を起点にするため、ローカルの `main` 自体が古くても最新の内容から分岐する。未 push のローカルコミットはレビューを通っていない変更なので、作業ブランチの起点に混ぜない。
- `auto_merge_reviewed: true`（push しない完全ローカル運用）。この設定では手順 3 のマージ結果が push されないので `origin/<デフォルトブランチ>` は進まない。先行タスクの成果はローカルのデフォルトブランチにしか無いため、ローカルとリモートの包含関係を見て起点を選ぶ。ローカルが `origin` を含む（先行・同一）ならローカル、ローカルが遅れているなら `origin` を起点にする。これにより、`--dep` で順序付けたタスクの先行分がワークツリーに入る。

ローカルの `main` は、以前のように毎回 `pull` されるわけではなく、手順 3 の ff-only マージで進む分だけ更新される。

`create-worktree` は起点を決めた後、割り当てたブランチが実際にその起点の先端を含んでいるかを検査し、結果を `RESULT:` 行として出す。**この行を読まずに引き渡さない。** 既存のワークツリー・ブランチを再利用する経路（再引き渡し）では起点が使われないため、この検査を見ないと古い起点のまま気づかずに引き渡すことになる。

| `RESULT` | 意味 | dispatch が行うこと |
| --- | --- | --- |
| `OK` | 割り当てブランチが起点（および `auto_merge_reviewed: true` のときは採用しなかった側の候補）を含んでいる | そのまま引き渡す。 |
| `STALE_BASE` / `STALE_REASON=reused_branch_behind_base` | 既存ブランチを再利用したが、そのブランチが起点の先端を含まない（再引き渡しの間にデフォルトブランチが進んだ場合など） | 欠けているコミット（`MISSING_COMMITS`）が引き渡すタスクの前提になっていないか確認する。前提になっている（`--dep` の先行タスクの成果を含む等）場合は引き渡さず、そのブランチをどう扱うか（作業ブランチを畳んで作り直すか、人間がマージするか）を報告に挙げて人間の判断に回す。前提でないなら、その事実を引き渡しプロンプトに明記したうえで引き渡してよい。 |
| `STALE_BASE` / `STALE_REASON=diverged_default_branch` | ローカルとリモートのデフォルトブランチが分岐しており、どちらを起点にしても片方のコミットが欠ける | 引き渡さない。dispatch は `merge`・`rebase`・`push` でこれを解消しない（禁止事項）。分岐している事実と `MISSING_COMMITS` を報告し、人間の判断に回す。 |
| `STALE_BASE` / `STALE_REASON=branch_behind_default_branch` | 起点以外の候補（`auto_merge_reviewed: true` のときのもう一方のデフォルトブランチ）を含まない | `reused_branch_behind_base` と同じ扱いにする。欠けているコミットがタスクの前提かどうかで判断する。 |
| `STALE_BASE` / `STALE_REASON=base_ref_unresolved` | 起点そのものを解決できない（リモートが消えた等） | 引き渡さない。環境の不備として報告する。 |

`STALE_EXCLUDE` は上の表とは独立している（TASK-79）。`worktree_base_dir` を変更したときに、以前の値で書かれた `.git/info/exclude` の除外行がそのまま残っていることを示す。残った行は既に失効した理由で git の追跡を黙って止め続けるが、これはローカルの設定ファイルの問題であり、引き渡しを止める理由にはならない。**引き渡しはそのまま進め、`STALE_EXCLUDE` の内容（残っている行と、それを improvement-loop が追記したのか元からあったのか）を手順7の報告に含める。** 削除するかどうかは人間が決める。`create-worktree` は共有物である `.git/info/exclude` の既存行を削除・書き換えしない（自分が書いた管理記録のコメント行だけを更新する）。

`RESULT: STALE_BASE` でも `create-worktree` 自体は 0 で終了する（`&&` は切れず、後続の `backlog task edit` は実行される）。引き渡すかどうかの判断は上の表のとおり dispatch の責務であり、引き渡さないと判断した場合は `backlog task edit TASK-<n> -s "To Do" --comment '<STALE_BASE の内容>' --comment-author @dispatch --plain` で `To Do` に戻す。

`$WORKTREE_DIR` にあたるパスが git worktree としてではなく通常のディレクトリやファイルとして既に存在している場合（手作業での汚染など）、`create-worktree` はエラーを報告して非ゼロで終了する。内容を確認し、不要と判断できる場合のみ削除するか、人間に判断を委ねて別のタスクを処理する。

引き渡しはサブエージェント（`Agent`、`subagent_type: general-purpose`）に対して行う。背景実行のままにする。完了時に通知が返るので、待ち合わせのための短い間隔での起動は入れない。

プロンプトには必ず次を含める。

- 冒頭に `improvement-work スキルを使って進めること`。
- タスク ID と、`backlog task view TASK-<n> --plain` で全文を読む指示。
- **作業ディレクトリ（ワークツリーの絶対パス、`$WORKTREE_DIR`）**と、そのディレクトリから移動しないこと。
- ブランチ名（`$BRANCH`）。参考情報として伝えるが、サブエージェントは自分でブランチを切り替えたり新しく作ったりしない。ワークツリーは引き渡し時点で既にそのブランチを checkout 済みである。
- リポジトリの規約（`CLAUDE.md` の場所、backlog CLI 経由の原則、実行すべき検証コマンド）。
- 手順 1 で読んだ `improvement_loop.forbidden_paths` / `allowed_paths` のいずれかに 1 件以上の値がある場合、それぞれ「変更してはいけないパス」「変更してよいパス」として明記する。あわせて、この制限が improvement-work の手順 8（コミット直前）と dispatch の手順 6（完了検証）で `check-forbidden-allowed-paths` により機械的に照合され、違反すればコミットも完了検証も通らない旨を伝える。git 管理外のパスは `git diff` に現れないため機械的には止まらないが、指示としては同じく守ること（検知されないことを守らなくてよい理由にしないこと）も添える。両方とも空、またはキー自体が無い場合はこの指示を省略する（従来どおり制限なし）。
- 非目標。タスクの受入基準の外に手を広げないこと。
- 完了時に返すべき内容：変更ファイル、実行した検証とその結果、残るリスク、受入基準を満たせたか、人間の判断が必要な未解決点。

引き渡した内容の要点（ワークツリーのパスとブランチ名）は `backlog task edit TASK-<n> --append-notes '<引き渡し内容>'` に残す。セッションが落ちても手順 2 で復旧できる。

### 6. 完了を検証する

サブエージェントの報告をそのまま信じない。次を自分で確認する。

```bash
backlog task view TASK-<n> --plain
git log <デフォルトブランチ>..<作業ブランチ> --oneline
git diff <デフォルトブランチ>...<作業ブランチ> --stat
```

`git diff` は3ドット（`A...B` = `git diff $(git merge-base A B) B`、マージベース起点）で取る。2ドット（`A..B` = 両端の比較）にすると、分岐後にデフォルトブランチが進んでいる場合に、デフォルトブランチ側だけで変わったファイルまで差分に載る。手順6が動く時点では、In Review が複数件並ぶ間に別のタスクがマージされてデフォルトブランチが進んでいるのが通常であり、下の範囲レビューとバックストップ検証の根拠が汚れる。3ドットならマージベース起点になり、この作業ブランチが加えた変更だけを見る。`git log` の方は2ドットのままでよい。`git log A..B` は「B にあって A に無いコミット」であり、これは既に作業ブランチ側だけを見る指定である（`git log` の3ドットは対称差で、デフォルトブランチ側のコミットまで含んでしまい逆に壊れる）。同じ3ドットの指定を improvement-work/SKILL.md 手順6のレビューパスと check-forbidden-allowed-paths の使用例でも使っている。

- status が `In Review` になっているか。
- 受入基準がチェックされ、notes に検証の証跡（実行したコマンドと結果）があるか。
- ブランチにコミットがあるか。差分が受入基準の範囲に収まっているか。
- `forbidden_paths`/`allowed_paths` のバックストップ検証。上記の `--stat` と同じ範囲（マージベース起点の3ドット）で取った変更ファイル一覧を、機械的な照合スクリプトに突き合わせる。

  ```bash
  CHANGED_FILES=()
  while IFS= read -r f; do
    [ -n "$f" ] && CHANGED_FILES+=("$f")
  done < <(git diff <デフォルトブランチ>...<作業ブランチ> --name-only)
  .claude/skills/improvement-dispatch/scripts/check-forbidden-allowed-paths \
    "${CHANGED_FILES[@]}"
  ```

  変更ファイル一覧は改行区切りで配列 `CHANGED_FILES` に読み込んでから `"${CHANGED_FILES[@]}"` として展開する。`$(git diff ...)` をクォート無しで直接展開すると、ファイル名中の半角スペースでも単語分割され、1つのパスが複数の偽の引数に壊れる。

  終了ステータスと標準出力の `RESULT: <値>` の行で判別する（0=OK, 1=VIOLATION, 2=ERROR）。`forbidden_paths`/`allowed_paths` が両方空、キー自体が無い、または `.backlog/config.my.yml` 自体が無い場合、このスクリプトは常に `RESULT: OK` で終わる（スクリプト自身の仕様）。そのため未設定のときはこの検証を実行しても判定は常に無違反となり、既存の手順6の実行フローに変化は生じない。`RESULT: VIOLATION` のときは標準出力の `VIOLATING_FILES` に違反ファイルが列挙される。`RESULT: ERROR` のときは標準エラー出力を確認し、環境不備（対象リポジトリでない等）を解消したうえで手順6をやり直す。backlog タスクの状態はこのスクリプト自体では変更しない。
- 報告に挙がった検証コマンドを 1 つ選び、自分で実行して結果が一致するか確かめる。

満たしていない場合の扱い：

- 実装が不完全、範囲外、検証が無い、または `forbidden_paths`/`allowed_paths` のバックストップ検証が `RESULT: VIOLATION` を返した → `backlog task edit TASK-<n> -s "To Do" --comment '<不足点、または VIOLATING_FILES の一覧>' --comment-author @dispatch` で戻し、次回の起動で再度引き渡す。同じタスクの再引き渡しは `max_redispatch` 回まで。
- 再引き渡しを `max_redispatch` 回使い切った、または人間の判断が必要と報告された（`forbidden_paths`/`allowed_paths` の違反が再引き渡し後も解消しない場合を含む） → `backlog task edit TASK-<n> --add-label 'blocked:needs-decision' -s "To Do" --comment '<未解決の判断事項>' --comment-author @dispatch`。以降の選択から自動的に外れる。
- 満たしている（`forbidden_paths`/`allowed_paths` のバックストップ検証が `RESULT: OK` の場合を含む） → そのまま `In Review` で置く。`Done` にしない。ブランチ名と差分の要約を報告する。

### 7. 次の起動を決めて報告する

報告に含めるもの：

- 今回やったこと（マージした／引き渡した／検証した／何もしなかった）。
- 現在の状態の内訳（`Proposed` / `To Do` / `In Progress` / `In Review` / `Approved` の件数）。
- マージした場合は、マージ後の main の位置と、プッシュが未実施であること。
- 人間に必要な行動：
  - `Proposed` の承認：`backlog task edit TASK-<n> -s "To Do"`
  - `In Review` のレビュー、済んだら `backlog task edit TASK-<n> -s "Approved"`
    - `auto_merge_reviewed: true` の場合：次の起動で dispatch が main にマージし `Done` にする。
    - `auto_merge_reviewed: false`（既定）の場合：dispatch はマージしない。人間が作業ブランチから PR を作成し、レビュー・CI を経て main にマージした後、`backlog task edit TASK-<n> -s "Done"` で `Done` にする。対応するワークツリーの片付けも人間が行う。
  - main のプッシュ（`auto_merge_reviewed: true` でマージした場合のみ該当。dispatch は行わない）
  - `blocked:needs-decision` の判断：コメントに書かれた選択肢に答え、`backlog task edit TASK-<n> --remove-label 'blocked:needs-decision'` でループに戻す
- 作業ブランチ名とワークツリーのパスの一覧（レビュー対象）。

`/loop` に間隔が指定されている場合は、その間隔に任せる。間隔が指定されていない（動的ペース）場合は `ScheduleWakeup` で次回を決める。

- サブエージェントが走っている → 完了通知で起こされるので、保険として 1800 秒以上。
- `Proposed` の承認待ち、または `In Review` のレビュー待ちで動けない → 1200〜1800 秒。
- 引き渡せるタスクも承認待ちもレビュー待ちも無い（backlog が空） → `ScheduleWakeup` に `stop: true` を渡してループを終える。improvement-scout を実行して候補を積むようユーザーに伝える。自分で scout を起動しない（ユーザーがそう指示した場合を除く）。

## 禁止事項

- 実装しない。コード、設定、テストを編集しない。
- `push` と PR 作成をしない。リモートへの反映は人間が行う。
- `merge` は手順 3 の `Approved` のものに限る。それ以外のブランチを main に入れない。
- `rebase` と `--force` を伴う git 操作をしない。レビュー済みのコミットの同一性を変えない。
- メインの作業木が汚れているときは、そこでブランチを切り替えない（該当するのは手順 3 のマージ時のみ。手順 5 のワークツリー作成はメインの作業木の状態を問わない）。stash も reset もしない。
- サブエージェントが作業しているワークツリーの中身を直接編集・削除しない。片付けはマージ完了後（手順 3）に、そのワークツリーに限って `git worktree remove` で行う。
- `Proposed` を `To Do` に上げない。`In Review` を `Approved` に上げない。`Approved` 以外を `Done` にしない。
- `.backlog/` 配下の md を直接編集しない。すべて `backlog` CLI 経由で行う。
- `max_in_progress` 件を超えて `In Progress` にしない。
- サブエージェントの完了を待つために短い間隔で起動を繰り返さない。通知で起こされる。
