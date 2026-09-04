#!/usr/bin/env bash
# tests/test_syntax.sh
#
# improvement-loop の各スクリプト・SKILL.md 埋め込み bash ブロックに対する
# 構文チェック（bash -n / shellcheck）と、tests/ 配下が一時パスの後片付け作法に
# 揃っているかの横断チェック。単体で実行すると、このファイルの検証だけが走る。
# tests/run.sh から全体実行の一部としても呼ばれる。
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
#   bin/lib/list_opted_in_repos.sh・claude-code/workspace-skills/workspace-dispatch・
#   workspace-scout・workspace-scout-major の各 scripts/list-target-repos・
#   claude-code/skills/improvement-dispatch/scripts/check-forbidden-allowed-paths・
#   bin/lib/worktree_porcelain.sh を source するようになった
#   claude-code/skills/improvement-dispatch/scripts/create-worktree・
#   merge-reviewed-branch（TASK-64））である。
#   source 先を実際に追って検査させる指定で、無いと常に SC1091 で誤って失敗する。
# - install.zsh だけ hard failure にしない（4フィールド目が true）。zsh 専用
#   スクリプトで、shellcheck は zsh を直接サポートしないため（下のshellcheck
#   ループのコメントを参照）。
# - bin/lib/resolve_path.sh・bin/lib/list_opted_in_repos.sh・
#   bin/lib/yaml_unquote.sh・bin/lib/worktree_porcelain.sh は、bash/zsh 両方
#   から source される想定（resolve_path.sh）、または他のバッシュスクリプト
#   から source されるだけ（他の3つ）で、いずれもシバンを持たない（各ファイル
#   冒頭コメント参照）。そのため shellcheck にシバン無しのまま渡すと、対象
#   シェルが不明として SC2148 (error) になり必ず失敗する（シバンや shellcheck
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
  "$WORKTREE_PORCELAIN_SCRIPT|bin/lib/worktree_porcelain.sh|--shell=bash|false"
  "$WORKSPACE_DISPATCH_LIST_TARGET_REPOS_SCRIPT|claude-code/workspace-skills/workspace-dispatch/scripts/list-target-repos|-x -P SCRIPTDIR|false"
  "$WORKSPACE_SCOUT_LIST_TARGET_REPOS_SCRIPT|claude-code/workspace-skills/workspace-scout/scripts/list-target-repos|-x -P SCRIPTDIR|false"
  "$WORKSPACE_SCOUT_MAJOR_LIST_TARGET_REPOS_SCRIPT|claude-code/workspace-skills/workspace-scout-major/scripts/list-target-repos|-x -P SCRIPTDIR|false"
  "$CREATE_WORKTREE_SCRIPT|claude-code/skills/improvement-dispatch/scripts/create-worktree|-x -P SCRIPTDIR|false"
  "$MERGE_SCRIPT|claude-code/skills/improvement-dispatch/scripts/merge-reviewed-branch|-x -P SCRIPTDIR|false"
  "$SELECT_SCRIPT|claude-code/skills/improvement-dispatch/scripts/select-next-task||false"
  "$CHECK_HANDOFF_SCRIPT|claude-code/skills/improvement-work/scripts/check-handoff||false"
  "$PRECOMMIT_HOOK|githooks/pre-commit||false"
  "$CHECK_RECOVERY_SCRIPT|claude-code/skills/improvement-dispatch/scripts/check-progress-recovery||false"
  "$CHECK_FORBIDDEN_ALLOWED_SCRIPT|claude-code/skills/improvement-dispatch/scripts/check-forbidden-allowed-paths|-x -P SCRIPTDIR|false"
)

# bash -n の診断出力は一時ファイルではなくコマンド置換で変数に取る。以前は
# `/tmp/tests-run-sh-syntax-err.$$` を直接組み立てて 2> でそこへ捨て、正常経路の
# rm -f だけで消していたため、作成から削除までの間にシグナルで中断されると
# /tmp に残骸が残った（後片付けレジストリにも登録されていなかった。TASK-80）。
# 変数に取れば一時パスを一切作らないので、trap の発火に依存せず残骸が生じない。
# 変数代入の終了コードはコマンド置換の終了コードなので、if の判定はそのまま使える。
# 2>&1 でまとめるのは、下の SKILL.md 埋め込みブロック側の検査と同じ形である
# （bash -n は構文エラーを標準エラーにしか出さないため、混ざる標準出力は無い）。
for entry in "${CHECK_SCRIPTS[@]}"; do
  IFS='|' read -r script_path script_label _sc_flags _sc_allow_fail <<<"$entry"
  if syntax_err="$(bash -n "$script_path" 2>&1)"; then
    pass "bash -n $script_label"
  else
    fail "bash -n $script_label: $syntax_err"
  fi
done

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
# claude-code/skills/improvement-dispatch/SKILL.md、claude-code/skills/improvement-work/SKILL.md、
# claude-code/workspace-skills/workspace-dispatch/SKILL.md、
# claude-code/workspace-skills/workspace-scout/SKILL.md には、
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
      # 直後の rm -f で消しているが、その手前で中断された場合に備えて
      # 後片付けレジストリにも登録しておく（tests/lib/common.sh の作法）。
      register_tmp_cleanup "$block_tmp"
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

echo ""
echo "=== 1d. tests/ 配下の一時パスの後片付け作法 ==="
# tests/lib/common.sh は一時パスの後片付けレジストリ（register_tmp_cleanup /
# cleanup_registered_tmp_paths と trap ... EXIT）を提供し、同ファイル冒頭のコメントで
# 「一時パスは作った直後に register_tmp_cleanup へ渡す」を唯一の作法だと定めている。
# ところが作法から外れたことに気づける機械的な検査が無く、実際に tests/test_syntax.sh
# だけが登録漏れのまま残っていた（TASK-80）。同じ取りこぼしを繰り返さないための検査を
# ここに置く。新しいテストファイルを増やさないのは、このファイルが既に CHECK_SCRIPTS や
# SKILL.md 埋め込みブロックのようにリポジトリ全体を横断して検査する役割を持っているためである。
#
# 走査対象は tests/lib/common.sh を source するファイル、すなわち tests/test_*.sh と
# tests/lib/*.sh に限る。tests/run.sh は各テストファイルを子プロセスとして起動する
# ランナーであり common.sh を source しないので、レジストリをそもそも使えない（対象外）。
#
# 検査する規約は2つある。
# - 規約A: 一時パスを固定の絶対パスで組み立てない。作成は mktemp に任せる。
#   TASK-80 以前の tests/test_syntax.sh は PID を混ぜただけの予測可能なパスを
#   一時ディレクトリ直下に直接組み立てていた。
# - 規約B: mktemp の結果を代入した変数は、同じファイルの中で register_tmp_cleanup に渡す。
#   直後に mv で消費する場合でも登録する。登録の要否を呼び出し側の文脈から
#   判別しようとすると検査が脆くなるため、例外を設けず一律に登録側を揃える
#   （cleanup_registered_tmp_paths は rm -rf なので、既に無いパスの登録は無害である）。
check_tests_tmp_path_convention() {
  # 規約Aの検出パターンに使う一時ディレクトリ名を変数に持たせているのは、
  # パターンをこの行に直書きすると、このファイル自身も走査対象に含まれるため
  # 自分の grep パターンを規約A違反として検出してしまうからである。
  local tmp_dir_literal='/tmp'

  local scan_files=()
  local f
  for f in "$REPO_ROOT"/tests/test_*.sh "$REPO_ROOT"/tests/lib/*.sh; do
    [ -f "$f" ] && scan_files+=("$f")
  done

  if [ "${#scan_files[@]}" -eq 0 ]; then
    fail "一時パスの後片付け作法: 走査対象のファイルが1つも見つからない（走査条件の不具合の可能性がある）"
    return
  fi

  local violations=""
  local rel hits line var register_re
  for f in "${scan_files[@]}"; do
    rel="${f#"$REPO_ROOT"/}"

    # 規約A: コメント行を除いたうえで、一時ディレクトリ直下のパスを直書きしている行を探す。
    hits="$(grep -nE "$tmp_dir_literal/" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      violations+="  $rel:$line  → 規約A: 一時パスは mktemp で作る"$'\n'
    done <<<"$hits"

    # 規約B: mktemp の結果を代入している変数名を集め、同じファイル内に
    # register_tmp_cleanup への引き渡しがあるかを確かめる。
    hits="$(grep -nE '^[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*="\$\(mktemp' "$f" || true)"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      var="$(printf '%s\n' "$line" | sed -E 's/^[0-9]+:[[:space:]]*(local[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*$/\2/')"
      # 行頭（インデント可）から始まる register_tmp_cleanup の呼び出しに限定して探す。
      # コメントアウトされた登録行を有効な登録と誤認しないためである。
      register_re='^[[:space:]]*register_tmp_cleanup[[:space:]].*"\$\{?'"$var"'\}?"'
      if ! grep -qE "$register_re" "$f"; then
        violations+="  $rel:${line%%:*}: \$$var  → 規約B: mktemp の直後に register_tmp_cleanup へ登録する"$'\n'
      fi
    done <<<"$hits"
  done

  if [ -z "$violations" ]; then
    pass "tests/test_*.sh・tests/lib/*.sh の一時パスが後片付け作法（mktemp + register_tmp_cleanup）に揃っている（走査 ${#scan_files[@]} ファイル）"
  else
    fail "一時パスの後片付け作法に反する箇所がある（tests/lib/common.sh の register_tmp_cleanup を参照）:
${violations%$'\n'}"
  fi
}

check_tests_tmp_path_convention

finish_tests
