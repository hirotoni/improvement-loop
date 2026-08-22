---
name: improvement-dispatcher
description: Backlog.md のタスク状態を見て improvement ループを制御する。To Do のタスクがあれば作業ブランチを作り、サブエージェントに improvement-work を引き渡す。`/loop` から定期起動される前提。「改善ループを回して」「backlog の To Do を順に進めて」のように、起票済みタスクの消化を自走させたいときに使用する。オーケストレーションに徹し、実装作業そのものは行わない。
---

# improvement-orchestrator

Backlog.md の状態を読み、次に何を動かすかを決める。
1 回の起動でやることは「状態を読む」「レビュー済みをマージする」「必要なら 1 件引き渡す」「次の起動を決める」の 4 つだけである。

**自分で実装しない。** コードの編集、テストの修正、リファクタは improvement-work の仕事である。
引き渡しのために調べる（対象ファイルの特定、依存の確認、リポジトリ規約の抽出）のは構わない。

## ループ内の位置

| status        | 意味                                     | 動かす主体                |
| ------------- | ---------------------------------------- | ------------------------- |
| `Proposed`    | 起票された改善候補。未承認               | improvement-scout が起票  |
| `To Do`       | 着手が承認された                         | 人間                      |
| `In Progress` | 作業ブランチに引き渡し済み               | **orchestrator が動かす** |
| `In Review`   | 実装がブランチに乗り、レビュー待ち       | improvement-work          |
| `Reviewed`    | 人間のレビューが済み、マージを待っている | 人間                      |
| `Done`        | main にマージ済み                        | **orchestrator が動かす** |

`Proposed` を `To Do` に上げるのは人間である。承認を代行しない。
`In Review` を `Reviewed` に上げるのも人間である。レビューを代行しない。
`Reviewed` になったものは orchestrator が main にマージし、`Done` にする（手順 3）。

このリポジトリは PR を運用していない。ローカルで main にマージし、人間がプッシュする流れである。orchestrator はマージまで進め、`push` はしない。

## 調整値

上限は `.backlog/config.my.yml` の `improvement_loop` で設定する。手順 1 で読み、以降の判断にはこのファイルの値を使う。散文に書かれた数字を根拠にしない。

| キー              | 意味                                                            | 既定値 |
| ----------------- | --------------------------------------------------------------- | ------ |
| `max_in_review`   | この件数以上 `In Review` が溜まっていたら新規の引き渡しを止める | 3      |
| `max_in_progress` | 同時に `In Progress` にできる件数                               | 1      |
| `max_redispatch`  | 同じタスクを再引き渡しできる回数                                | 2      |

ファイルが存在しない場合、`improvement_loop` が無い場合、個別のキーが欠けている場合は、それぞれ既定値を使う。読めなかった旨を報告に 1 行添えること。値の変更は直接編集で行う。`backlog config set` は `config.yml` 側の設定を触るもので、このファイルには効かない。

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

進行中のサブエージェントがあるかも確認する。`TaskList` と `TaskOutput` を使う（schema が未ロードなら `ToolSearch` で `select:TaskList,TaskOutput` を取得する）。

### 2. 進行中のものを突合する

`In Progress` のタスクがある場合：

- 対応するサブエージェントが動いている → 今回の起動でやることはない。手順 7 に進む。
- サブエージェントが完了している → 手順 6 の検証に進む。
- サブエージェントが存在しない（前回のセッションが落ちた、中断された） → 復旧する。
  1. `backlog task view TASK-<n> --plain` で notes と plan を読む。notes には引き渡し時のワークツリーのパスが残っているはずである。
  2. `git worktree list` でそのワークツリーが残っているか確認する。残っていれば `git -C <ワークツリーのパス> log --oneline` で到達点を確認する。ワークツリーが無くなっていても、そのブランチ自体（`improvement/task-<n>-<スラッグ>`）は `git branch` の一覧に残る。`git worktree remove` はワークツリーのディレクトリを片付けるだけでブランチは削除しない。ブランチが残っていれば、メインの作業木から `git log <作業ブランチ> --oneline` で到達点を確認できる（ワークツリーに入る必要はない）。
  3. 実装が途中まで進んでいるなら、その到達点を引き渡し情報に含めて再度引き渡す（手順 5）。ワークツリーが残っていればそのまま再利用する。無くなっていれば、まず `git worktree prune` で古い管理情報を掃除してから、既存の作業ブランチを起点にワークツリーを作り直す（手順 5 の「既存ブランチの再利用」分岐を使う）。
  4. 何も進んでいないなら、`backlog task edit TASK-<n> -s "To Do" --comment '引き渡し先が消失したため To Do に戻した' --comment-author @orchestrator` で戻す。ワークツリーが残っていれば `git worktree remove <ワークツリーのパス>` で片付ける。

`In Progress` は同時に `max_in_progress` 件までとする。以前はメインの作業木を複数のサブエージェントで共有していたため、この上限がブランチの混線を防ぐ唯一の歯止めだった。手順 5 でタスクごとに独立したワークツリーへ分離した現在、その理由自体は成立しなくなっている。ただし値を引き上げるかどうかはこのタスクのスコープ外として据え置く（レビュー体制や運用実績を見て別途判断する）。

### 3. レビュー済みのものを main にマージする

`Reviewed` は人間のレビューが済み、マージを待っている状態である。手順 4 の選定より先に処理する。ここで main が進めば、後続の引き渡しは新しい main を基点にできる。

```bash
backlog task list --status "Reviewed" --plain
```

対象が無ければ手順 4 に進む。

マージの前提条件。1 つでも欠けたらマージせず、状況を報告して今回の起動を終える。

- **メインの作業木**（人間や orchestrator がいるこのディレクトリ）の `git status --porcelain` が空である。汚れているときはそこでブランチを切り替えない。stash も reset もしない。作業ブランチはワークツリーで分離されているため、この条件はメインの作業木自身の汚れ（人間の手元の変更）にのみ関する。他のサブエージェントが別のワークツリーで稼働中かどうかはこの条件に影響しない。
- 対応する作業ブランチが存在し、`git log main..<作業ブランチ>` にコミットがある。ブランチさえ存在すればよく、対応するワークツリーがまだ残っているかは問わない。

対象は 1 件ずつ処理する。マージ操作自体はメインの作業木（main を checkout しているディレクトリ）で行い、ワークツリー側のディレクトリに入る必要はない。まず早送りを試す。

```bash
git switch main
git merge --ff-only <作業ブランチ>
```

早送りできない場合（main が先に進んでいる）は、衝突の有無を先に確かめる。

```bash
git merge --no-commit --no-ff <作業ブランチ>
```

- 衝突した → `git merge --abort` で元に戻す。タスクは `Reviewed` のまま残し、衝突したファイルを報告する。解消は人間に委ねる。次の対象には進まない。
- 衝突しない → そのままコミットしてマージを完了する。

`rebase` は使わない。人間がレビューしたコミットの同一性が変わるためである。`--force` を伴う操作もしない。

マージが完了したタスクだけ `Done` にする。

```bash
backlog task edit TASK-<n> -s "Done" --comment 'main にマージした（<マージ後の main の短縮ハッシュ>）' --comment-author @orchestrator
```

マージ後も `push` はしない。リモートへの反映は人間が行う。作業ブランチは削除せず残す（過去のコミットを辿れるようにするため）。一方、ワークツリーのディレクトリはマージが完了すれば役目を終えるので片付ける。

```bash
git worktree remove <ワークツリーのパス>   # 例: <リポジトリの親ディレクトリ>/.worktree/task-<n>-<スラッグ>
```

サブエージェントが後始末し忘れた未コミットの変更がワークツリー側に残っていて `remove` が失敗する場合は、`--force` で強制削除せず、その旨を報告してそのワークツリーは残す。中身の破棄が必要かどうかの判断は人間に委ねる。

処理後に `git log --oneline -1 main` で main の位置を確認し、報告に含める。

### 4. 次に引き渡すタスクを選ぶ

`In Progress` が無いときだけ選ぶ。`To Do` の中から次の規則で 1 件選ぶ。

除外するもの：

- `blocked:needs-decision` ラベルが付いているもの。人間の判断を待っている。
- 依存タスク（`Dependencies`）が `Done` になっていないもの。

`backlog task list` の出力にラベルは出ず、ラベルの除外指定も無い。差集合で求める。

```bash
backlog task list --status "To Do" --plain                                    # 候補全体
backlog task list --status "To Do" --labels 'blocked:needs-decision' --plain  # 除外する分
```

依存は候補ごとに `backlog task view TASK-<n> --plain` の `Dependencies` を見て確認する。

順序：

1. 優先度が高いもの（`High` → `Medium` → `Low`）。
2. 同じ優先度なら ID が小さいもの。

引き渡しを止める条件：

- `In Review` のタスクが `max_in_review` 件以上溜まっている。レビューが追いついていない。新規の引き渡しをせず、レビュー待ちの一覧を報告する。
- `To Do` に対象が無い。手順 7 に進む。

以前はメインの作業木が汚れている（`git status --porcelain` に出力がある）ことも引き渡しを止める条件だった。手順 5 は `git worktree add` でリポジトリの親ディレクトリの `.worktree/` 配下に新しいワークツリーを作るだけで、メインの作業木のブランチ切り替えや checkout の変更を伴わない。そのため人間がメインの作業木で未コミットの変更を持っていても新規タスクを引き渡せる。この条件は停止条件から外す。

### 5. ワークツリーを作って引き渡す

作業ブランチはメインの作業木の上には作らない。リポジトリの親ディレクトリの `.worktree/` 配下に、タスクごとに独立したワークツリーを作る。この操作はメインの作業木のブランチ切り替えや checkout の変更を伴わないため、人間がメインの作業木で作業中でも実行できる。

このハーネスは Bash 呼び出しごとにカレントディレクトリとシェル変数をリセットする（呼び出しをまたいで保持されない）。そのため、以下は **1 回の Bash 呼び出しにまとめて実行する**。複数回に分けると、後半のコマンドが `$WORKTREE_DIR` や `$BRANCH` を参照できず失敗する。

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
PARENT_DIR=$(dirname "$REPO_ROOT")
mkdir -p "$PARENT_DIR/.worktree"
WORKTREE_DIR="$PARENT_DIR/.worktree/task-<n>-<英小文字のスラッグ>"
BRANCH="improvement/task-<n>-<英小文字のスラッグ>"

git worktree prune   # ディレクトリだけ消えて登録情報が残っているケースを掃除してから作る

if git fetch origin 2>/dev/null; then
  DEFAULT_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  BASE_REF="origin/${DEFAULT_BRANCH:-main}"
else
  BASE_REF="main"   # デフォルトブランチが判定できない/リモートが無い場合は main を使う
fi

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  # 再引き渡し等で既にブランチが存在する場合は、新規作成せずそのブランチを割り当てる
  git worktree add "$WORKTREE_DIR" "$BRANCH"
else
  git worktree add "$WORKTREE_DIR" -b "$BRANCH" "$BASE_REF"
fi

# .backlog/ は git 管理外（.git/info/exclude で除外）なので、
# git worktree add では新しいワークツリーに作られない。
# メインの作業木の .backlog/ へのシンボリックリンクにして、タスクデータを共有する。
if [ -e "$REPO_ROOT/.backlog" ] && [ ! -e "$WORKTREE_DIR/.backlog" ]; then
  ln -s "$REPO_ROOT/.backlog" "$WORKTREE_DIR/.backlog"
fi

# 古いインストール（.git/info/exclude が末尾スラッシュ付きの ".backlog/" のまま）だと、
# 上のシンボリックリンクは除外パターンにマッチせず、ワークツリー内で git status が
# 常に汚れて見える。スラッシュ無しの ".backlog" は両方にマッチするので、無ければ足す。
EXCLUDE_FILE="$(git rev-parse --git-common-dir)/info/exclude"
mkdir -p "$(dirname "$EXCLUDE_FILE")"
grep -Fxq ".backlog" "$EXCLUDE_FILE" 2>/dev/null || echo ".backlog" >> "$EXCLUDE_FILE"

backlog task edit TASK-<n> -s "In Progress" -a @improvement-work --plain

echo "WORKTREE_DIR=$WORKTREE_DIR"
echo "BRANCH=$BRANCH"
```

デフォルトブランチ名の判定は `git symbolic-ref --short refs/remotes/origin/HEAD` に依存する。この参照が設定されていないリモート環境では `DEFAULT_BRANCH` が空になり、上のスクリプトは `main` にフォールバックする。実際のデフォルトブランチが `main` 以外の場合は、このフォールバック値を書き換える。

出力された `WORKTREE_DIR` と `BRANCH` の値は、以降の手順（サブエージェントへの引き渡しプロンプト、`--append-notes` への記録）でリテラルな文字列として使う。シェル変数として次の呼び出しに持ち越そうとしない。

新しいワークツリーはフェッチできれば `origin/<デフォルトブランチ>` を起点にするため、ローカルの `main` 自体が古くても最新の内容から分岐する。一方でローカルの `main` は、以前のように毎回 `pull` されるわけではなく、手順 3 の ff-only マージで進む分だけ更新される。ローカル `main` と `origin/main` がしばらく乖離しても、次の分岐や手順 3 のマージには支障が無い。

`$WORKTREE_DIR` にあたるパスが git worktree としてではなく通常のディレクトリやファイルとして既に存在している場合（手作業での汚染など）、`git worktree add` は失敗する。内容を確認し、不要と判断できる場合のみ削除するか、人間に判断を委ねて別のタスクを処理する。

引き渡しはサブエージェント（`Agent`、`subagent_type: general-purpose`）に対して行う。背景実行のままにする。完了時に通知が返るので、待ち合わせのための短い間隔での起動は入れない。

プロンプトには必ず次を含める。

- 冒頭に `improvement-work スキルを使って進めること`。
- タスク ID と、`backlog task view TASK-<n> --plain` で全文を読む指示。
- **作業ディレクトリ（ワークツリーの絶対パス、`$WORKTREE_DIR`）**と、そのディレクトリから移動しないこと。ブランチ名（`$BRANCH`）も参考情報として伝えるが、サブエージェントは自分でブランチを切り替えたり新しく作ったりしない。ワークツリーは引き渡し時点で既にそのブランチを checkout 済みである。
- リポジトリの規約（`CLAUDE.md` の場所、backlog CLI 経由の原則、実行すべき検証コマンド）。
- 非目標。タスクの受入基準の外に手を広げないこと。
- 完了時に返すべき内容：変更ファイル、実行した検証とその結果、残るリスク、受入基準を満たせたか、人間の判断が必要な未解決点。

引き渡した内容の要点（ワークツリーのパスとブランチ名）は `backlog task edit TASK-<n> --append-notes '<引き渡し内容>'` に残す。セッションが落ちても手順 2 で復旧できる。

### 6. 完了を検証する

サブエージェントの報告をそのまま信じない。次を自分で確認する。

```bash
backlog task view TASK-<n> --plain
git log <デフォルトブランチ>..<作業ブランチ> --oneline
git diff <デフォルトブランチ>..<作業ブランチ> --stat
```

- status が `In Review` になっているか。
- 受入基準がチェックされ、notes に検証の証跡（実行したコマンドと結果）があるか。
- ブランチにコミットがあるか。差分が受入基準の範囲に収まっているか。
- 報告に挙がった検証コマンドを 1 つ選び、自分で実行して結果が一致するか確かめる。

満たしていない場合の扱い：

- 実装が不完全、範囲外、または検証が無い → `backlog task edit TASK-<n> -s "To Do" --comment '<不足点>' --comment-author @orchestrator` で戻し、次回の起動で再度引き渡す。同じタスクの再引き渡しは `max_redispatch` 回まで。
- 再引き渡しを `max_redispatch` 回使い切った、または人間の判断が必要と報告された → `backlog task edit TASK-<n> --add-label 'blocked:needs-decision' -s "To Do" --comment '<未解決の判断事項>' --comment-author @orchestrator`。以降の選択から自動的に外れる。
- 満たしている → そのまま `In Review` で置く。`Done` にしない。ブランチ名と差分の要約を報告する。

### 7. 次の起動を決めて報告する

報告に含めるもの：

- 今回やったこと（マージした／引き渡した／検証した／何もしなかった）。
- 現在の状態の内訳（`Proposed` / `To Do` / `In Progress` / `In Review` / `Reviewed` の件数）。
- マージした場合は、マージ後の main の位置と、プッシュが未実施であること。
- 人間に必要な行動：
  - `Proposed` の承認：`backlog task edit TASK-<n> -s "To Do"`
  - `In Review` のレビュー、済んだら `backlog task edit TASK-<n> -s "Reviewed"`（次の起動で orchestrator が main にマージし `Done` にする）
  - main のプッシュ（orchestrator は行わない）
  - `blocked:needs-decision` の判断：コメントに書かれた選択肢に答え、`backlog task edit TASK-<n> --remove-label 'blocked:needs-decision'` でループに戻す
- 作業ブランチ名とワークツリーのパスの一覧（レビュー対象）。

`/loop` に間隔が指定されている場合は、その間隔に任せる。間隔が指定されていない（動的ペース）場合は `ScheduleWakeup` で次回を決める。

- サブエージェントが走っている → 完了通知で起こされるので、保険として 1800 秒以上。
- `Proposed` の承認待ち、または `In Review` のレビュー待ちで動けない → 1200〜1800 秒。
- 引き渡せるタスクも承認待ちもレビュー待ちも無い（backlog が空） → `ScheduleWakeup` に `stop: true` を渡してループを終える。improvement-scout を実行して候補を積むようユーザーに伝える。自分で scout を起動しない（ユーザーがそう指示した場合を除く）。

## 禁止事項

- 実装しない。コード、設定、テストを編集しない。
- `push` と PR 作成をしない。リモートへの反映は人間が行う。
- `merge` は手順 3 の `Reviewed` のものに限る。それ以外のブランチを main に入れない。
- `rebase` と `--force` を伴う git 操作をしない。レビュー済みのコミットの同一性を変えない。
- メインの作業木が汚れているときは、そこでブランチを切り替えない（該当するのは手順 3 のマージ時のみ。手順 5 のワークツリー作成はメインの作業木の状態を問わない）。stash も reset もしない。
- サブエージェントが作業しているワークツリーの中身を直接編集・削除しない。片付けはマージ完了後（手順 3）に、そのワークツリーに限って `git worktree remove` で行う。
- `Proposed` を `To Do` に上げない。`In Review` を `Reviewed` に上げない。`Reviewed` 以外を `Done` にしない。
- `.backlog/` 配下の md を直接編集しない。すべて `backlog` CLI 経由で行う。
- `max_in_progress` 件を超えて `In Progress` にしない。
- サブエージェントの完了を待つために短い間隔で起動を繰り返さない。通知で起こされる。
