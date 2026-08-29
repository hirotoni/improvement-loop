#!/usr/bin/env bash
# tests/test_syntax.sh
#
# improvement-loop の各スクリプト・SKILL.md 埋め込み bash ブロックに対する
# 構文チェック（bash -n / shellcheck）。単体で実行すると、このファイルの
# 検証だけが走る。tests/run.sh から全体実行の一部としても呼ばれる。
#
# 依存は bash/zsh・git・backlog のみ。いずれか欠けていれば、その旨を
# 報告してスキップする（テスト対象の不具合として失敗にはしない）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 1. 構文チェック ==="

# CHECK_SCRIPTS: bash -n / shellcheck の対象スクリプトを列挙する単一の情報源。
# 新しいスクリプトを構文チェック対象に加えるには、ここに1エントリ追加するだけでよい
# （変数宣言は tests/lib/common.sh で別途行う。パスと変数を1対1にしたのは、対象スクリプトの
# 実体パスが REPO_ROOT からの導出であり、かつ他ファイル（setup実行や
# select-next-task の直接呼び出し等）でも同じ変数を使い回すため）。
#
# 各要素はパイプ区切りの1行で「<パス変数>|<表示ラベル>|<shellcheckへの追加フラグ>|<shellcheck指摘をhard failureにしないか(true/false)>」。
# - `-x -P SCRIPTDIR` が必要なのは、他のスクリプト/ライブラリを source する
#   スクリプト（bin/setup-improvement-loop・install.zsh・
#   bin/lib/list_opted_in_repos.sh・claude-skills-workspace/workspace-dispatch・
#   workspace-scout・workspace-scout-major の各 scripts/list-target-repos・
#   claude-skills/improvement-dispatch/scripts/check-forbidden-allowed-paths）
#   である。source 先を実際に追って検査させる指定で、無いと常に SC1091 で
#   誤って失敗する。
# - install.zsh だけ hard failure にしない（4フィールド目が true）。zsh 専用
#   スクリプトで、shellcheck は zsh を直接サポートしないため（下のshellcheck
#   ループのコメントを参照）。
# - bin/lib/resolve_path.sh・bin/lib/list_opted_in_repos.sh・
#   bin/lib/yaml_unquote.sh は、bash/zsh 両方から source される想定
#   （resolve_path.sh）、または他のバッシュスクリプトから source される
#   だけ（他の2つ）で、いずれもシバンを持たない（各ファイル冒頭コメント
#   参照）。そのため shellcheck にシバン無しのまま渡すと、対象シェルが
#   不明として SC2148 (error) になり必ず失敗する（シバンや shellcheck
#   ディレクティブをファイル自体に足すのは対象スクリプトへの変更になるため、
#   CHECK_SCRIPTS 側のフラグだけで解決する）。`--shell=bash` を渡すことで、
#   実際に bash から source される実態に沿って解析させ、クリーンに通ることを
#   確認済み。bin/lib/list_opted_in_repos.sh は自身も bin/lib/resolve_path.sh を
#   source するため、`-x -P SCRIPTDIR` と `--shell=bash` の両方を渡す。
CHECK_SCRIPTS=(
  "$INSTALL_SCRIPT|install.zsh|-x -P SCRIPTDIR|true"
  "$SETUP_SCRIPT|bin/setup-improvement-loop|-x -P SCRIPTDIR|false"
  "$RESOLVE_PATH_SCRIPT|bin/lib/resolve_path.sh|--shell=bash|false"
  "$YAML_UNQUOTE_SCRIPT|bin/lib/yaml_unquote.sh|--shell=bash|false"
  "$LIST_OPTED_IN_REPOS_SCRIPT|bin/lib/list_opted_in_repos.sh|-x -P SCRIPTDIR --shell=bash|false"
  "$WORKSPACE_DISPATCH_LIST_TARGET_REPOS_SCRIPT|claude-skills-workspace/workspace-dispatch/scripts/list-target-repos|-x -P SCRIPTDIR|false"
  "$WORKSPACE_SCOUT_LIST_TARGET_REPOS_SCRIPT|claude-skills-workspace/workspace-scout/scripts/list-target-repos|-x -P SCRIPTDIR|false"
  "$WORKSPACE_SCOUT_MAJOR_LIST_TARGET_REPOS_SCRIPT|claude-skills-workspace/workspace-scout-major/scripts/list-target-repos|-x -P SCRIPTDIR|false"
  "$CREATE_WORKTREE_SCRIPT|claude-skills/improvement-dispatch/scripts/create-worktree||false"
  "$MERGE_SCRIPT|claude-skills/improvement-dispatch/scripts/merge-reviewed-branch||false"
  "$SELECT_SCRIPT|claude-skills/improvement-dispatch/scripts/select-next-task||false"
  "$CHECK_HANDOFF_SCRIPT|claude-skills/improvement-work/scripts/check-handoff||false"
  "$PRECOMMIT_HOOK|githooks/pre-commit||false"
  "$CHECK_RECOVERY_SCRIPT|claude-skills/improvement-dispatch/scripts/check-progress-recovery||false"
  "$CHECK_FORBIDDEN_ALLOWED_SCRIPT|claude-skills/improvement-dispatch/scripts/check-forbidden-allowed-paths|-x -P SCRIPTDIR|false"
)

SYNTAX_ERR_FILE="/tmp/tests-run-sh-syntax-err.$$"
: > "$SYNTAX_ERR_FILE"
for entry in "${CHECK_SCRIPTS[@]}"; do
  IFS='|' read -r script_path script_label _sc_flags _sc_allow_fail <<<"$entry"
  if bash -n "$script_path" 2>"$SYNTAX_ERR_FILE"; then
    pass "bash -n $script_label"
  else
    fail "bash -n $script_label: $(cat "$SYNTAX_ERR_FILE")"
  fi
done
rm -f "$SYNTAX_ERR_FILE"

if command -v shellcheck >/dev/null 2>&1; then
  # install.zsh とその他のスクリプトをまとめて1回の shellcheck 呼び出しで渡すと、
  # zsh は shellcheck が対応しない shell のため SC1071 で即座に fatal
  # parse error になり、他のスクリプト側も一切linterされずに巻き添えで FAIL
  # してしまう。そのため CHECK_SCRIPTS の各エントリに対して個別に実行する。
  for entry in "${CHECK_SCRIPTS[@]}"; do
    IFS='|' read -r script_path script_label sc_flags sc_allow_fail <<<"$entry"
    # shellcheck disable=SC2086  # sc_flags は複数フラグをそのまま単語分割させたいので意図的
    if shellcheck $sc_flags "$script_path"; then
      if [ "$sc_allow_fail" = "true" ]; then
        pass "shellcheck $script_label (shell=bash として、精度は参考程度)"
      else
        pass "shellcheck $script_label"
      fi
    else
      if [ "$sc_allow_fail" = "true" ]; then
        # install.zsh は zsh 専用スクリプトで、shellcheck は zsh を直接サポート
        # しない。ファイル冒頭の `# shellcheck shell=bash` ディレクティブにより
        # bash として（精度は落ちるが）解析させている。zsh 固有構文
        # （${0:A:h} や print 組み込みなど）による誤検知が出ることがあるため、
        # ここでの指摘は参考情報として報告するのみで、テスト全体の
        # hard failure にはしない。
        echo "NOTE: shellcheck $script_label に指摘あり。$script_label は zsh 専用のため" \
             "zsh 構文由来の誤検知を含みうる。上の出力を参照し、実際のバグかどうかは" \
             "目視で判断すること（この結果だけでテストを失敗にはしない）。"
        skip "shellcheck $script_label (指摘あり。zsh 構文の誤検知の可能性があるため参考情報扱い)"
      else
        fail "shellcheck $script_label (指摘あり。上の出力を参照)"
      fi
    fi
  done
else
  skip "shellcheck が PATH に無いため実行しなかった"
fi

echo ""
echo "=== 1c. SKILL.md 埋め込み bash ブロックの構文チェック ==="
# claude-skills/improvement-dispatch/SKILL.md、claude-skills/improvement-work/SKILL.md、
# claude-skills-workspace/workspace-dispatch/SKILL.md、
# claude-skills-workspace/workspace-scout/SKILL.md には、
# dispatch/work が実際に実行する bash コードブロックが埋め込まれている
# （例: improvement-dispatch の手順3・手順5）。ここでは各 ```bash フェンスブロックを抽出し、
# bash -n で構文チェックする。フェンスは箇条書きの入れ子（行頭に空白のインデント）で
# 書かれていることがあるため、行頭が完全に ```bash / ``` と一致する場合だけでなく、
# 前後に空白を許した正規表現でマッチさせる。
#
# ブロックには <n> や <作業ブランチ> のようなプレースホルダが含まれることがある。この山括弧を
# そのまま bash -n に渡すと、bash がリダイレクト演算子（`<`/`>`）として誤解釈し、プレース
# ホルダ自体が原因の構文エラーになる（例: `git worktree remove <ワークツリーのパス>` は、
# `<`/`>` の後に続くはずのファイル名が無いというエラーになる）。これは TASK-6 実装時に手動で
# `bash -n` を17ブロック（dispatch 9個、work 8個）に対して実行した際、4ブロックを
# プレースホルダ由来として個別に除外した対象と一致する。
# ここではブロックを除外する代わりに、構文チェック前に `<...>`（山括弧を含まない中身）を
# 安全なダミートークンへ機械的に置換する。これにより山括弧に起因する偽陽性を消しつつ、
# クォートの閉じ忘れ等の本物の構文エラーはそのまま検出できるので、個別のブロック除外リストを
# 保守せずに恒常的な自動チェックの対象へ含められる。置換パターンは `<(` で始まる箇所
# （プロセス置換 `<(cmd)`）を除外しており、`<(cmd1) <(cmd2) > out` のような行で
# 2つ目のプロセス置換と実際のリダイレクトを1つのプレースホルダとして誤って飲み込まないようにする。
check_skill_bash_blocks() {
  local skill_file="$1"
  local label="$2"

  if [ ! -f "$skill_file" ]; then
    fail "$label: $skill_file が存在しない"
    return
  fi

  local open_re='^[[:space:]]*```bash[[:space:]]*$'
  local close_re='^[[:space:]]*```[[:space:]]*$'

  # 抽出ループとは独立に開始フェンス（```bash、インデント許容）の総数を数え、
  # ループ側の処理件数と突き合わせる。ループのバグ（フェンスの見落とし、閉じフェンスが
  # 無いまま終端する 等）でブロックが黙って処理から漏れることを検出するための二重チェック。
  local expected_count
  expected_count="$(grep -Ec "$open_re" "$skill_file" || true)"

  local in_block=0
  local block_num=0
  local block=""
  local line
  local found_any=0

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_block" -eq 0 ]; then
      if [[ "$line" =~ $open_re ]]; then
        in_block=1
        block=""
      fi
      continue
    fi

    if [[ "$line" =~ $close_re ]]; then
      in_block=0
      block_num=$((block_num + 1))
      found_any=1

      local sanitized
      sanitized="$(printf '%s\n' "$block" | sed -E 's/<[^<>(][^<>]*>/PLACEHOLDER_TOKEN/g')"

      if [ -z "$(printf '%s' "$sanitized" | tr -d '[:space:]')" ]; then
        fail "$label: bash ブロック #$block_num が空である（内容の抽出漏れの可能性がある）"
        continue
      fi

      local block_tmp
      block_tmp="$(mktemp)"
      printf '%s' "$sanitized" > "$block_tmp"

      local err_out
      err_out="$(bash -n "$block_tmp" 2>&1)"
      local rc=$?
      rm -f "$block_tmp"

      if [ "$rc" -eq 0 ]; then
        pass "$label: bash ブロック #$block_num の構文チェック"
      else
        fail "$label: bash ブロック #$block_num の構文エラー: $err_out"
      fi
      continue
    fi

    block+="$line"$'\n'
  done < "$skill_file"

  if [ "$in_block" -eq 1 ]; then
    fail "$label: 閉じフェンス（\`\`\`）が見つからないまま bash ブロックが終端した（ブロック #$((block_num + 1)) 相当）"
  fi

  if [ "$found_any" -eq 0 ]; then
    fail "$label: \`\`\`bash ブロックが1つも見つからない（抽出ロジックの不具合の可能性がある）"
  elif [ "$block_num" -ne "$expected_count" ]; then
    fail "$label: 抽出できたブロック数（$block_num）が開始フェンスの総数（$expected_count）と一致しない（見落としの可能性がある）"
  fi
}

check_skill_bash_blocks "$SOURCE_SKILLS_DIR/improvement-dispatch/SKILL.md" "improvement-dispatch/SKILL.md"
check_skill_bash_blocks "$SOURCE_SKILLS_DIR/improvement-work/SKILL.md" "improvement-work/SKILL.md"
check_skill_bash_blocks "$SOURCE_WORKSPACE_SKILLS_DIR/workspace-dispatch/SKILL.md" "workspace-dispatch/SKILL.md"
check_skill_bash_blocks "$SOURCE_WORKSPACE_SKILLS_DIR/workspace-scout/SKILL.md" "workspace-scout/SKILL.md"

finish_tests
