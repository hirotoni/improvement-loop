# improvement-loop

以下の記事を参考にした、Backlog.md と独自ループを掛け合わす開発フローのためのファイル群。
https://creators.bengo4.com/entry/2026/07/22/095159

## claude skills

- improvement-dispatcher
- improvement-scout
- improvement-scout-major
- improvement-work
- improvement-add

これらのスキル群は `backlogmd-custom-config/config.my.yml`の独自設定を参照する。

## インストール手順

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
        ├── improvement-dispatcher/**
        ├── improvement-scout/**
        ├── improvement-work/**
        └── improvement-add/**
```

## 運用

個人でローカルで運用する場合、関連ファイルは全て`.git/info/exclude`に登録されているため、リポジトリを汚染することなく改善ループを行うことができる。
