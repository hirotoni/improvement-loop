# improvement-loop

以下の記事を参考にした、Backlog.md と独自ループを掛け合わす開発フローのためのファイル群。
https://creators.bengo4.com/entry/2026/07/22/095159

## claude skills

- improvement-dispatch
- improvement-scout
- improvement-scout-major
- improvement-work
- improvement-add

これらのスキル群は `backlogmd-custom-config/config.my.yml`の独自設定を参照する。

## インストール手順

### 前提: backlog CLI

このリポジトリのスキル群・スクリプト群は [Backlog.md](https://backlog.md/)（[GitHub: MrLesk/Backlog.md](https://github.com/MrLesk/Backlog.md)）の `backlog` CLI に依存しており、`--add-label` / `--check-ac` / `--final-summary` / `--plan` など多数の非自明なフラグを前提にしている。`setup-improvement-loop`は `backlog` コマンドの存在確認のみ行い、バージョンまでは確認しないため、事前に以下のいずれかの方法で導入しておく。

```sh
brew install backlog-md
# または
npm install -g backlog.md
```

動作確認済みの最小バージョンは `1.48.0`（`backlog --version`で確認）。これより古いバージョンでは、上記フラグの一部が使えず、improvement-dispatch/improvement-work 実行中にエラーになる場合がある。

`install.zsh`は以下を行う。

1. `setup-improvement-loop`コマンドをパスに追加

`setup-improvement-loop`は以下を行う。

1. Backlog.md CLI を使ったセットアップ
2. claude-skills をリポジトリに配置（シンボリックリンク使用）
3. `backlogmd-custom-config/config.my.yml`の配置
4. .backlog/\*\*と claude スキル群の`.git/info/exclude`への追加

```sh
.
├── .backlog/
│   └── config.my.yml
└── .claude/
    └── skills/
        ├── improvement-dispatch/**
        ├── improvement-scout/**
        ├── improvement-work/**
        └── improvement-add/**
```

## 運用

個人でローカルで運用する場合、関連ファイルは全て`.git/info/exclude`に登録されているため、リポジトリを汚染することなく改善ループを行うことができる。

## このリポジトリ自身の開発（pre-commit フック）

このリポジトリ（improvement-loop 自身）を開発する人向けの設定。`bin/setup-improvement-loop`や`install.zsh`が配布する対象には含まれない。

`tests/run.sh`を`git commit`時に自動実行し、失敗時はコミットをブロックするフックを`githooks/pre-commit`として用意している。`.git/hooks/`は git 管理外のため、このリポジトリを clone した人が最初に一度だけ以下を実行して有効化する。

```sh
git config core.hooksPath githooks
```

有効化すると、以降このリポジトリで行う`git commit`のたびに`tests/run.sh`が実行され、FAILがあればコミットが中断される。GitHub Actions等のCIはこのリポジトリでは対象外とする。
