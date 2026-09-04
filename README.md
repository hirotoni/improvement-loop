# improvement-loop

## 概要

Backlog.md と Claude Code のスキルを組み合わせ、コードベースの改善タスクの起票からレビュー待ちまでを自走させるためのファイル群。以下の記事を参考にした、Backlog.md と独自ループを掛け合わす開発フローを実装している。
https://creators.bengo4.com/entry/2026/07/22/095159

## 前提条件

このリポジトリのスキル群・スクリプト群は [Backlog.md](https://backlog.md/)（[GitHub: MrLesk/Backlog.md](https://github.com/MrLesk/Backlog.md)）の `backlog` CLI に依存しており、`--add-label` / `--check-ac` / `--final-summary` / `--plan` など多数の非自明なフラグを前提にしている。事前に以下のいずれかの方法で導入しておく。

```sh
brew install backlog-md
# または
npm install -g backlog.md
```

動作確認済みの最小バージョンは `1.48.0`（`backlog --version` で確認）。これより古いバージョンでは、上記フラグの一部が使えず、improvement-dispatch/improvement-work 実行中にエラーになる場合がある。`setup-improvement-loop` は `backlog` コマンドの存在確認のみ行い、バージョンまでは確認しない。

シェルは zsh と bash の両方を使う。用途が分かれており、一方がもう一方の代わりにはならない。

- zsh: 下記インストール手順1の `install.zsh` の実行に必要。`install.zsh` はシバンが `#!/usr/bin/env zsh` の zsh 専用スクリプトで、`${0:A:h}` など zsh 固有の構文を使う。bash では実行できない。
- bash: `bin/setup-improvement-loop` と各スキルの `scripts/` 配下のスクリプト、および下記「開発者向け情報」の `tests/run.sh` の実行に必要。これらはシバンが `#!/usr/bin/env bash` で、`BASH_SOURCE` など bash 固有の機能を使う。zsh では実行できない。

## インストール手順

1. `install.zsh` を実行する。`bin/setup-improvement-loop` を `$HOME/.local/bin` にシンボリックリンクし、パスから使えるようにする。
2. 対象リポジトリで `setup-improvement-loop [対象リポジトリのパス]` を実行する。以下を冪等に行う。
   - `backlog init`（`.backlog/config.yml` が未導入の場合のみ）
   - `.backlog/config.yml` の `statuses` に improvement ループが前提とする6状態（`Proposed` / `To Do` / `In Progress` / `In Review` / `Approved` / `Done`）のうち欠けているものを補う
   - `claude-code/skills/` 配下の5スキル（improvement-add / improvement-scout / improvement-scout-major / improvement-dispatch / improvement-work）を `.claude/skills/` にシンボリックリンクとして配置する
   - `backlog-md/config.my.yml`（improvement ループ独自の調整値）を `.backlog/config.my.yml` として配置する
   - `.backlog/` と配置したスキル群を `.git/info/exclude` に追記し、対象リポジトリを汚染しないようにする

```
.
├── .backlog/
│   └── config.my.yml
└── .claude/
    └── skills/
        ├── improvement-add/**
        ├── improvement-dispatch/**
        ├── improvement-scout/**
        ├── improvement-scout-major/**
        └── improvement-work/**
```

個人でローカルで運用する場合、関連ファイルは全て `.git/info/exclude` に登録されているため、リポジトリを汚染することなく改善ループを行うことができる。

## 使い方

improvement ループは Backlog.md のタスク状態（`Proposed` → `To Do` → `In Progress` → `In Review` → `Approved` → `Done`）を、以下の5スキルが分担して動かす。状態遷移の正本は `claude-code/skills/status-table.md` にある。
各スキルの詳細（引数、手順、入出力例）はこの README には書かず、対応する `claude-code/skills/<name>/SKILL.md` を参照すること。

- **improvement-add**: 人間が伝えた改善要望を、そのまま `Proposed` として起票する。
- **improvement-scout**: コードベースを探索し、改善候補を `Proposed` として起票する。
- **improvement-scout-major**: アーキテクチャ級の改善候補を、milestone と配下のタスクに分解して `Proposed` として起票する。
- **improvement-dispatch**: `To Do` のタスクにワークツリーを用意して `In Progress` にし、improvement-work サブエージェントに引き渡す。
- **improvement-work**: 引き渡されたタスクを実装・検証・コミットし、`In Review` にして人間のレビューを待つ。

`Proposed` を `To Do` に上げる（着手の承認）のと、`In Review` を `Approved` に上げる（レビュー完了）のは、いずれも人間が行う。

## ワークスペース対応

複数の git リポジトリを直下（深さ1）にクローンした「ワークスペースディレクトリ」を対象に、improvement ループの dispatch / scout を横断的に走らせることができる。
**各リポジトリのバックログは独立したまま**であり、ワークスペース全体で1つのタスク一覧を共有する仕組みではない。`improvement-add` / `improvement-work` はワークスペース対応の対象外である。
各スキルの詳細はこの README には書かず、対応する `claude-code/workspace-skills/<name>/SKILL.md` を参照すること。

- **workspace-dispatch**: opt-in 済みの各リポジトリへ順に `improvement-dispatch` を適用する。
- **workspace-scout**: opt-in 済みの各リポジトリへ順に `improvement-scout` を適用する。
- **workspace-scout-major**: opt-in 済みの全リポジトリを横断して1回で調査し、リポジトリをまたぐ改善候補を関与する各リポジトリに起票する。

### セットアップ

1. 対象にしたい各リポジトリで、これまで通り `setup-improvement-loop <リポジトリのパス>`（`--workspace` フラグ無し）を実行する。これが「そのリポジトリを opt-in させる」操作である。
2. ワークスペースディレクトリ自体に対して `setup-improvement-loop --workspace [ワークスペースディレクトリのパス]` を実行する（引数を省略した場合は現在のディレクトリを対象とする）。ワークスペースディレクトリが git リポジトリである必要はない。以下を冪等に行う。
   - `workspace-dispatch` / `workspace-scout` / `workspace-scout-major` の3スキルを `.claude/skills/` にシンボリックリンクとして配置する（`backlog init` や `.backlog/` 配下の配置は一切行わない）
   - ワークスペースディレクトリ自体が git リポジトリでもある場合に限り、配置したスキルパスを `.git/info/exclude` に追記する（git リポジトリでなければスキップされ、エラーにはならない）

```
<ワークスペースディレクトリ>/
├── repo-a/            # setup-improvement-loop <repo-a> 済み（opt-in）
│   └── .claude/skills/improvement-dispatch, improvement-scout, improvement-scout-major, ...
├── repo-b/            # 未 opt-in（workspace-* スキルの対象外）
└── .claude/
    └── skills/
        ├── workspace-dispatch/**
        ├── workspace-scout/**
        └── workspace-scout-major/**
```

opt-in の判定に使うのは `.claude/skills/improvement-dispatch` 等のシンボリックリンクの有無だけであり、専用のマーカーファイルは無い。opt-in していないリポジトリや git リポジトリでないディレクトリは黙って対象から外れる。
対象リポジトリの列挙ロジックは `bin/lib/list_opted_in_repos.sh` に一本化されており、各スキルの `scripts/list-target-repos` が薄いラッパーとして呼び出す。

## 開発者向け情報

このリポジトリ（improvement-loop 自身）を開発する人向けの設定。`bin/setup-improvement-loop` や `install.zsh` が配布する対象には含まれない。

`tests/run.sh` を `git commit` 時に自動実行し、失敗時はコミットをブロックするフックを `githooks/pre-commit` として用意している。`.git/hooks/` は git 管理外のため、このリポジトリを clone した人が最初に一度だけ以下を実行して有効化する。

```sh
git config core.hooksPath githooks
```

有効化すると、以降このリポジトリで行う `git commit` のたびに `tests/run.sh` が実行され、FAIL があればコミットが中断される。
`tests/run.sh` は依存ゼロの最小テストランナーで、`tests/` 配下の `test_*.sh` を順に実行し、各ファイルのサマリー行を合算して全体の PASS/FAIL/SKIP を報告する。依存（bash・git・backlog）が欠けている場合は、対象テストが SKIP として報告される。
zsh はテストの共通の依存ではない。zsh を使うのは `install.zsh` を実際に実行する `tests/test_setup_improvement_loop.sh` の1箇所だけで、zsh が無い環境ではその検証だけが SKIP になり、他のテストはそのまま実行される。
GitHub Actions 等の CI はこのリポジトリでは対象外とする。

## ライセンス

このプロジェクトは [MIT License](./LICENSE) のもとで公開されている。
