---
name: workspace-dispatch
description: 複数の git リポジトリをクローンしたワークスペースディレクトリを対象に、improvement-dispatch に opt-in 済みの各リポジトリへ横断的に improvement-dispatch を適用する。`/loop` から定期起動される前提。「ワークスペース全体の改善ループを回して」「このワークスペース配下のリポジトリを一通り dispatch して」のように、複数リポジトリの To Do 消化をまとめて自走させたいときに使用する。自身はオーケストレーションに徹し、各リポジトリでの判断・実装作業そのものは既存の improvement-dispatch / improvement-work にそのまま委ねる。
---

# workspace-dispatch

複数の git リポジトリを直下（深さ1）にクローンした「ワークスペースディレクトリ」を対象に、[improvement-dispatch](../../skills/improvement-dispatch/SKILL.md) の手順を opt-in 済みの各リポジトリへ順番に適用する薄いオーケストレーション層である。

**各リポジトリの `.backlog/` はワークスペース全体で共有しない。** 各リポジトリは従来通り独立したバックログを持ち続ける。本スキルはその上に「複数リポジトリを1回の起動で巡回する」という薄い層を足すだけである。

**このスキル自身も improvement-dispatch と同じく、自分で実装しない。** コードの編集、テストの修正、リファクタは各リポジトリの improvement-work の仕事である。本スキルの役割は、対象リポジトリを列挙し、各リポジトリで improvement-dispatch の手順をそのまま適用することに限られる。

## 前提

- このスキルは `bin/setup-improvement-loop --workspace <ワークスペースディレクトリ>` を実行したワークスペースディレクトリの直下（`.claude/skills/workspace-dispatch`）に配置される。カレントディレクトリをそのワークスペースルートとして扱う。
- 対象となるのは、ワークスペース直下（深さ1）のサブディレクトリのうち、(a) git リポジトリであり、(b) `<リポジトリ>/.claude/skills/improvement-dispatch` が実在解決するシンボリックリンクとして存在する（＝ `bin/setup-improvement-loop`（`--workspace` 無し）でそのリポジトリ自身に improvement ループをセットアップ済み）ものだけである。この判定基準以外の新規マーカーファイルは無い。
- 対象外のリポジトリ（未セットアップ、または git リポジトリでないディレクトリ）は黙って対象から外れる。エラーにはしない。

## 手順

### 1. 対象リポジトリを列挙する

散文で `git` や `find` を組み立てず、決定論的なスクリプトを使う。

```bash
.claude/skills/workspace-dispatch/scripts/list-target-repos
```

標準出力に、opt-in 済みリポジトリの絶対パスが1行1件・ソート済みで並ぶ。0件なら何も出力されない。

- 0件の場合：何もせずその旨を報告して終了する（手順4には進まない）。ワークスペース配下のどのリポジトリにも improvement ループがセットアップされていない、または opt-in （`bin/setup-improvement-loop <リポジトリのパス>` の実行）が済んでいない可能性が高い旨を添える。
- 1件以上の場合：列挙された順（＝パスのソート順）に手順2へ進む。

### 2. 各リポジトリへ順に improvement-dispatch を適用する

列挙された各リポジトリについて、手順1の出力の順番のまま次を行う。

1. そのリポジトリの絶対パスへ `cd` する。
2. [`claude-code/skills/improvement-dispatch/SKILL.md`](../../skills/improvement-dispatch/SKILL.md) の「起動ごとの手順」（1〜7）を、**その記述内容を複製せず、そのまま適用する**。手順内で参照されるスクリプト（`select-next-task` / `create-worktree` / `merge-reviewed-branch` / `check-progress-recovery` / `check-forbidden-allowed-paths` 等）は、そのリポジトリ自身の `.claude/skills/improvement-dispatch/scripts/*` を使う（ワークスペース側には複製しない）。
3. `.backlog/config.my.yml` の調整値（`max_in_progress` / `max_in_review` / `auto_merge_reviewed` / `worktree_base_dir` / `forbidden_paths` / `allowed_paths` 等）は、**そのリポジトリ自身の値**を使う。ワークスペース全体で共有する調整値・合計上限は無い。あるリポジトリで `max_in_progress` に達していても、他のリポジトリの `max_in_progress` には影響しない。
4. そのリポジトリでの結果（`RESULT: SELECTED` で引き渡した／`GATED`／`NO_CANDIDATE`／マージした／検証してTo Doへ差し戻した 等、improvement-dispatch の手順7が報告する内容に相当するもの）を記録しておく。手順3の要約で使う。

**あるリポジトリが `GATED`・`NO_CANDIDATE`・エラーであっても、次のリポジトリの処理を止めない。** ゲーティングはリポジトリ単位で完結させる。ワークスペース全体の合計同時実行数の上限は設けない（各リポジトリの `max_in_progress`/`max_in_review` がそのまま独立に効く）。

各リポジトリの処理を終えたら、必ず次のリポジトリへ進む前にワークスペースルートへ戻る（`cd` の起点を毎回リポジトリ間で混同しないため）。

### 3. 全リポジトリ処理後、要約して報告する

手順2で列挙した順に、リポジトリごとの結果を一覧で報告する。各行には少なくとも次を含める。

- リポジトリの絶対パス（またはワークスペースルートからの相対名）
- 今回の結果（引き渡した／マージした／`GATED`（理由付き）／`NO_CANDIDATE`／エラー（内容付き）／何もしなかった）
- 引き渡した場合はタスクIDと作業ブランチ名

サブエージェントを起動した（improvement-dispatch の手順5で引き渡した）リポジトリがあれば、次回の起動タイミングは、improvement-dispatch 自身の手順7の目安（サブエージェント稼働中なら保険として1800秒以上、承認待ち・レビュー待ちなら1200〜1800秒 等）のうち、処理した全リポジトリの中で最も早く再確認が必要になるものに合わせる。`/loop` に間隔が指定されている場合は、その間隔に任せる。全リポジトリが「引き渡せるタスクも承認待ちもレビュー待ちも無い」状態であれば、`ScheduleWakeup` に `stop: true` を渡してループを終える。

## 禁止事項

improvement-dispatch の禁止事項（実装しない、`push`/PR作成をしない、`Approved` 以外を `Done` にしない 等）を、対象とする全リポジトリに対してそのまま継承する。加えて：

- ワークスペース全体で1つのタスク一覧を扱っているかのように振る舞わない（各リポジトリの `.backlog/` は独立している）。
- あるリポジトリの状態や調整値を、別のリポジトリの判断に流用しない。
- opt-in 済みリポジトリの判定基準（`.claude/skills/improvement-dispatch` シンボリックリンクの有無）を独自に変えたり、新しいマーカーファイルを作ったりしない。
