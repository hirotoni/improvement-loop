# improvement-loop

## 概要

Backlog.md と Claude Code のスキルを組み合わせ、コードベースの改善タスクの起票からレビュー待ちまでを自走させるためのファイル群。以下の記事を参考にした、Backlog.md と独自ループを掛け合わす開発フローを実装している。
https://creators.bengo4.com/entry/2026/07/22/095159

## 前提条件

このリポジトリのスキル群・スクリプト群は [Backlog.md](https://backlog.md/)（[GitHub: MrLesk/Backlog.md](https://github.com/MrLesk/Backlog.md)）の `backlog` CLI に依存しており、事前に以下のいずれかの方法で導入しておく。

```sh
brew install backlog-md
# または
npm install -g backlog.md
```

動作確認済みの最小バージョンは `1.48.0`。

このリポジトリは macOS での実行を前提としている。

## インストール手順

```sh
# bin/setup-improvement-loopをパスに追加する
./install.zsh

cd <対象リポジトリ>

# 内部で backlog init を呼び出し backlog-md を初期化しながら、
# さらに改善ループ用の独自追加セットアップを行う。
setup-improvement-loop
```

インストール後のフォルダ構成

```txt
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

関連ファイルは全て `.git/info/exclude` に登録されているため、リポジトリを汚染することなく改善ループを行うことができる。

## 使い方

improvement ループは Backlog.md のタスク状態（`Proposed` → `To Do` → `In Progress` → `In Review` → `Approved` → `Done`）を、以下の 5 スキルが分担して動かす。状態遷移の正本は `claude-code/skills/status-table.md` にある。
各スキルの詳細（引数、手順、入出力例）はこの README には書かず、対応する `claude-code/skills/<name>/SKILL.md` を参照すること。

- **improvement-add**: 人間が伝えた改善要望を、そのまま `Proposed` として起票する。
- **improvement-scout**: コードベースを探索し、改善候補を `Proposed` として起票する。
- **improvement-scout-major**: アーキテクチャ級の改善候補を、milestone と配下のタスクに分解して `Proposed` として起票する。
- **improvement-dispatch**: `To Do` のタスクにワークツリーを用意して `In Progress` にし、improvement-work サブエージェントに引き渡す。
- **improvement-work**: 引き渡されたタスクを実装・検証・コミットし、`In Review` にして人間のレビューを待つ。

`Proposed` を `To Do` に上げる（着手の承認）のと、`In Review` を `Approved` に上げる（レビュー完了）のは、いずれも人間が行う。

## ワークスペース対応

複数の git リポジトリを直下（深さ 1）にクローンした「ワークスペースディレクトリ」を対象に、improvement ループの dispatch / scout を横断的に走らせることができる。
**各リポジトリのバックログは独立したまま**であり、ワークスペース全体で 1 つのタスク一覧を共有する仕組みではない。`improvement-add` / `improvement-work` はワークスペース対応の対象外である。
各スキルの詳細はこの README には書かず、対応する `claude-code/workspace-skills/<name>/SKILL.md` を参照すること。

- **workspace-dispatch**: opt-in 済みの各リポジトリへ順に `improvement-dispatch` を適用する。
- **workspace-scout**: opt-in 済みの各リポジトリへ順に `improvement-scout` を適用する。
- **workspace-scout-major**: opt-in 済みの全リポジトリを横断して 1 回で調査し、リポジトリをまたぐ改善候補を関与する各リポジトリに起票する。

### セットアップ

```sh
# bin/setup-improvement-loopをパスに追加する
./install.zsh

# 対象にしたい各リポジトリで opt-in する
cd <対象リポジトリ>
setup-improvement-loop

# ワークスペースディレクトリに移動して、ワークスペース向けのスキルをインストールする
cd ..
setup-improvement-loop --workspace
```

インストール後のフォルダ構成

```
<ワークスペースディレクトリ>/
├── .claude/
│   └── skills/
│       ├── workspace-dispatch/**
│       ├── workspace-scout/**
│       └── workspace-scout-major/**
├── repo-a/               # setup-improvement-loop 実行済み（opt-in）
│   ├── .claude/skills/
│   │   ├── improvement-dispatch
│   │   ├── improvement-scout
│   │   ├── improvement-scout-major
│   │   └── ...
│   └── .backlog/**
└── repo-b/               # 未 opt-in（workspace-* スキルの対象外）
```

opt-in の判定に使うのは `.claude/skills/improvement-dispatch` 等のシンボリックリンクの有無だけ。

## 開発者向け情報

このリポジトリ（improvement-loop 自身）を開発する人向けの設定。`bin/setup-improvement-loop` や `install.zsh` が配布する対象には含まれない。

`tests/run.sh` を `git commit` 時に自動実行し、失敗時はコミットをブロックするフックを `githooks/pre-commit` として用意している。`.git/hooks/` は git 管理外のため、このリポジトリを clone した人が最初に一度だけ以下を実行して有効化する。

```sh
git config core.hooksPath githooks
```

インストール済みでないバージョンの backlog CLI（通常は動作確認済み最小バージョン `1.48.0`）で `tests/run.sh` を手動で実行するときは、次のコマンドを使う。

```sh
BACKLOG_VERSION=1.48.0
BACKLOG_TMP="$(mktemp -d)"
npm install --prefix "$BACKLOG_TMP" "backlog.md@$BACKLOG_VERSION"
PATH="$BACKLOG_TMP/node_modules/.bin:$PATH" backlog --version  # BACKLOG_VERSION と同じ値が出ることを確かめる
PATH="$BACKLOG_TMP/node_modules/.bin:$PATH" bash tests/run.sh
rm -rf "$BACKLOG_TMP"
```

グローバルにインストールした `backlog` も PATH に残っているので、PATH 上に backlog が 2 つある状態になる。

## ライセンス

このプロジェクトは [MIT License](./LICENSE) のもとで公開されている。
