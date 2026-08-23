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

## インストール手順

1. `install.zsh` を実行する。`bin/setup-improvement-loop` を `$HOME/.local/bin` にシンボリックリンクし、パスから使えるようにする。
2. 対象リポジトリで `setup-improvement-loop [対象リポジトリのパス]` を実行する。以下を冪等に行う。
   - `backlog init`（`.backlog/config.yml` が未導入の場合のみ）
   - `.backlog/config.yml` の `statuses` に improvement ループが前提とする6状態（`Proposed` / `To Do` / `In Progress` / `In Review` / `Approved` / `Done`）のうち欠けているものを補う
   - `claude-skills/` 配下の5スキル（improvement-add / improvement-scout / improvement-scout-major / improvement-dispatch / improvement-work）を `.claude/skills/` にシンボリックリンクとして配置する
   - `backlogmd-custom-config/config.my.yml`（improvement ループ独自の調整値）を `.backlog/config.my.yml` として配置する
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

improvement ループは Backlog.md のタスク状態（`Proposed` → `To Do` → `In Progress` → `In Review` → `Approved` → `Done`）を、以下の5スキルが分担して動かす。状態遷移の正本は `claude-skills/status-table.md` にある。各スキルの詳細（引数、手順、入出力例）はこの README には書かず、対応する `claude-skills/<name>/SKILL.md` を参照すること。

- **improvement-add**: 人間が伝えた改善要望を、そのまま `Proposed` として起票する。
- **improvement-scout**: コードベースを探索し、改善候補を選別して `Proposed` として起票する（1回の実行で最大3件）。
- **improvement-scout-major**: アーキテクチャ級の大きい改善候補を、milestone とその配下の複数タスクに分解して `Proposed` として起票する。
- **improvement-dispatch**: `To Do` のタスクを検知し、作業ブランチ・ワークツリーを用意して `In Progress` にし、improvement-work サブエージェントに引き渡す。
- **improvement-work**: 引き渡されたタスクを実装・検証・コミットし、`In Review` にして人間のレビューを待つ。

`Proposed` を `To Do` に上げる（着手の承認）のと、`In Review` を `Approved` に上げる（レビュー完了）のは、いずれも人間が行う。

## 開発者向け情報

このリポジトリ（improvement-loop 自身）を開発する人向けの設定。`bin/setup-improvement-loop` や `install.zsh` が配布する対象には含まれない。

`tests/run.sh` を `git commit` 時に自動実行し、失敗時はコミットをブロックするフックを `githooks/pre-commit` として用意している。`.git/hooks/` は git 管理外のため、このリポジトリを clone した人が最初に一度だけ以下を実行して有効化する。

```sh
git config core.hooksPath githooks
```

有効化すると、以降このリポジトリで行う `git commit` のたびに `tests/run.sh` が実行され、FAIL があればコミットが中断される。`tests/run.sh` は依存ゼロの最小テストランナーで、`tests/` 配下の `test_*.sh` を順に実行し、各ファイルのサマリー行を合算して全体の PASS/FAIL/SKIP を報告する。依存（bash/zsh・git・backlog）が欠けている場合は、対象テストが SKIP として報告される。GitHub Actions 等の CI はこのリポジトリでは対象外とする。

## ライセンス

このプロジェクトは [MIT License](./LICENSE) のもとで公開されている。
