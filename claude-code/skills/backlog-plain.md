# backlog CLI の `--plain` の適用範囲（正本）

backlog CLI のどのサブコマンドに `--plain` を付けるかの正本。
`improvement-scout` / `improvement-scout-major` / `improvement-add` の各 `SKILL.md` と
`claude-code/workspace-skills/workspace-scout-major/SKILL.md` は、この判断基準を手元に複製せず、
このファイルを単一情報源として参照する。
4ファイルを直接編集する前に必ずこのファイルを更新すること。

`--plain` を付けるコマンドと、付けると失敗するコマンドを取り違えない。
取り違えはどちらの向きでもセッションを止めるか、コマンドを失敗させる。

## 適用範囲の表

| コマンド | `--plain` | 誤ったときに起きること |
| --- | --- | --- |
| `backlog task list` / `backlog task view` / `backlog search` / `backlog milestone list` | 必ず付ける | 付けないと対話 UI が起動してセッションが止まる |
| `backlog config get` / `backlog config list` / `backlog instructions` | 付けない | 渡すと `error: unknown option '--plain'` を出して終了コード1で終わる |

`backlog config get` / `backlog config list` / `backlog instructions` は `--plain` 無しで実行する。
これらは `--plain` を受け付けないだけで、`--plain` が無くても対話 UI にはならず、
値をそのまま出力して終了コード0で終わる。

## この表に無いコマンドの判断

`backlog <サブコマンド> --help` の Input schema に `--plain` があるかで判断する。
