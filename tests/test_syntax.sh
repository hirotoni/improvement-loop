#!/usr/bin/env bash
# 各スクリプト・SKILL.md 埋め込み bash ブロックに対する構文チェック
# （bash -n と静的検査ツール）と、tests/ 配下が一時パスの後片付け作法に
# 揃っているかの横断チェック。単体でも tests/run.sh からも実行できる。
#
# 注意: このファイル自身も検査対象なので、字下げを含めてハッシュ記号の直後が
# あの静的検査ツールの名前で始まる行はディレクティブとして解釈され、
# SC1072/SC1073 (error) になる。コメントを書くときは語順を変えて避けること。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

check_test_dependencies

echo "=== 1. 構文チェック ==="

# CHECK_SCRIPTS: bash -n / shellcheck の対象スクリプトを列挙する単一の情報源。
# tests/ 配下**以外**をこの配列リテラルで、tests/ 配下を直後のブロックで実体から
# 動的に追記する。新しいスクリプトを対象に加えるにはここに1エントリ足す
# （パス変数の宣言は tests/lib/common.sh。他のテストからも使い回すためである）。
#
# 各要素はパイプ区切りの1行で
# 「<絶対パス>|<表示ラベル>|<shellcheck への追加フラグ>|<指摘を hard failure にしないか>」。
# 1フィールド目に $VAR と書いているのは値の書き方に過ぎず、格納されるのは展開後の
# パス文字列である。
#
# 追加フラグの使い分け:
# - `-x -P SCRIPTDIR`: 他のスクリプト/ライブラリを source するスクリプト。
#   source 先を実際に追って検査させる指定で、無いと常に SC1091 で誤って失敗する。
# - `--shell=bash`: bin/lib/*.sh のようなシバンを持たないファイル。シバン無しのまま
#   渡すと対象シェル不明として SC2148 (error) になり必ず失敗する。ファイル自身に
#   シバンやディレクティブを足すのは対象スクリプトへの変更になるので、フラグ側で解決する。
# - 4フィールド目が true なのは install.zsh だけ。zsh 専用で shellcheck が zsh を
#   直接サポートしないためである（下の shellcheck ループのコメントを参照）。
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

# ---- tests/ 配下のスクリプトを実体から動的に追記する ----
# tests/ はテストを増やすたびにファイルが増える場所なので、ここを列挙で持つと登録漏れが
# そのまま「静的検査を一度も通らないテストコード」になる。実体を単一の情報源として
# 動的に追記する（列挙方式は run.sh の網羅性検査や SKILL_NAMES と同じ nullglob 方式）。
# 上の静的な列挙がパス変数と1対1なのは他のテストからも使い回すためで、tests/ 配下の
# ファイルは構文チェック以外に参照されないので変数を増やす理由が無い。
#
# 追加フラグ（第3フィールド）はファイルの種類で決める。
# - tests/lib/*.sh: シバンを持たない共通基盤なので --shell=bash。加えて -e SC2034 も
#   渡す。ここが定義する共有変数の消費者は source する側にあり、単体で解析する側からは
#   見えないため、共有変数がすべて未使用として報告されるからである。
# - tests/test_*.sh: common.sh を source するので -x -P SCRIPTDIR。
# - それ以外の tests/*.sh（現状は run.sh のみ）: 他を source しないので追加フラグ不要。
#   将来 source するファイルが増えれば SC1091 で FAIL するが、無音で検査から漏れるより
#   失敗して気づける方を選ぶ。
# allow_fail はいずれも false とし、指摘はそのまま hard failure にする。
#
# 注意: このファイル自身も検査対象なので、コメントの語順に制約がある。字下げを含めて
# ハッシュ記号の直後があの検査ツールの名前で始まる行はディレクティブとして解釈され、
# SC1072/SC1073 (error) になる。書くときは語順を変えて避けること。
#
# TESTS_SC_EXTRA_FLAGS: 上の分類だけではクリーンに通らないファイルへの追加フラグ。
# 「<tests/ からの相対パス>|<追加フラグ>」の1行1エントリ。本来は対象ファイル自身に
# disable ディレクティブを書くのが解であり、これはそれができない場合の逃げ道である。
# 実体が消えたエントリが残らないよう、下で陳腐化を検査する。
TESTS_SC_EXTRA_FLAGS=(
  # sed 置換に含まれる後方参照に対する SC2016 (info)。後方参照はシングルクォートの
  # ままでなければ壊れるので、「展開されない」という指摘自体が誤検知である。
  "test_setup_improvement_loop.sh|-e SC2016"
)

TESTS_SCRIPT_RELPATHS=()
shopt -s nullglob
for tests_path in "$REPO_ROOT"/tests/*.sh "$REPO_ROOT"/tests/lib/*.sh; do
  [ -f "$tests_path" ] || continue
  TESTS_SCRIPT_RELPATHS+=("${tests_path#"$REPO_ROOT"/}")
done
shopt -u nullglob

for tests_rel in "${TESTS_SCRIPT_RELPATHS[@]}"; do
  case "$tests_rel" in
    tests/lib/*) tests_sc_flags="--shell=bash -e SC2034" ;;
    tests/test_*) tests_sc_flags="-x -P SCRIPTDIR" ;;
    *) tests_sc_flags="" ;;
  esac

  # ファイル単位の追加フラグを後ろに連結する。要素数で場合分けするのは、macOS 既定の
  # bash 3.2 が set -u 下で空配列を "${arr[@]}" と展開すると unbound variable になるため。
  if [ "${#TESTS_SC_EXTRA_FLAGS[@]}" -gt 0 ]; then
    for tests_extra_entry in "${TESTS_SC_EXTRA_FLAGS[@]}"; do
      IFS='|' read -r tests_extra_name tests_extra_flags <<<"$tests_extra_entry"
      if [ "$tests_rel" = "tests/$tests_extra_name" ]; then
        tests_sc_flags="${tests_sc_flags:+$tests_sc_flags }$tests_extra_flags"
      fi
    done
  fi

  CHECK_SCRIPTS+=("$REPO_ROOT/$tests_rel|$tests_rel|$tests_sc_flags|false")
done

# 列挙そのものが壊れていないかを検査する。0件のまま静かに通ると、tests/ 配下が
# 対象外だった状態へ無音で戻ってしまう。
tests_enum_problems=""
if [ "${#TESTS_SCRIPT_RELPATHS[@]}" -eq 0 ]; then
  tests_enum_problems+="  tests/ 配下にシェルスクリプトが1件も見つからない（列挙条件の不具合の可能性がある）"$'\n'
fi
if [ "${#TESTS_SC_EXTRA_FLAGS[@]}" -gt 0 ]; then
  for tests_extra_entry in "${TESTS_SC_EXTRA_FLAGS[@]}"; do
    IFS='|' read -r tests_extra_name _tests_extra_flags <<<"$tests_extra_entry"
    if [ ! -f "$REPO_ROOT/tests/$tests_extra_name" ]; then
      tests_enum_problems+="  TESTS_SC_EXTRA_FLAGS の $tests_extra_name に対応する実体が tests/ に無い（追加フラグの記述が実体から取り残されている）"$'\n'
    fi
  done
fi

if [ -z "$tests_enum_problems" ]; then
  pass "tests/ 配下のシェルスクリプト ${#TESTS_SCRIPT_RELPATHS[@]}件を実体から列挙して CHECK_SCRIPTS に取り込んだ"
else
  fail "tests/ 配下の CHECK_SCRIPTS への取り込みに問題がある:
${tests_enum_problems%$'\n'}"
fi

# bash -n の診断出力は一時ファイルではなくコマンド置換で変数に取る。一時パスを一切
# 作らないので、シグナルで中断されても残骸が生じない。変数代入の終了コードは
# コマンド置換の終了コードなので、if の判定にそのまま使える。
for entry in "${CHECK_SCRIPTS[@]}"; do
  IFS='|' read -r script_path script_label _sc_flags _sc_allow_fail <<<"$entry"
  if syntax_err="$(bash -n "$script_path" 2>&1)"; then
    pass "bash -n $script_label"
  else
    fail "bash -n $script_label: $syntax_err"
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  # まとめて1回の呼び出しで渡すと、zsh は対応外の shell なので SC1071 で即座に fatal
  # parse error になり、他のスクリプトも巻き添えで FAIL する。1エントリずつ実行する。
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
        # install.zsh は zsh 専用で、ファイル冒頭のディレクティブにより bash として
        # （精度は落ちるが）解析させている。zsh 固有構文による誤検知が出ることがある
        # ため、指摘は参考情報として報告するのみで hard failure にはしない。
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
  # 上の bash -n の層は shellcheck が無くても実行済みである（TASK-60）。ここで失われるのは
  # 静的検査の層だけなので、その規模と導入方法を1行で伝える。tests/run.sh 経由の実行では
  # 総合サマリーの「未導入の任意依存」にも再掲される（tests/run.sh の OPTIONAL_DEPENDENCIES）。
  skip "shellcheck が PATH に無いため、CHECK_SCRIPTS ${#CHECK_SCRIPTS[@]}件に対する静的検査を実行しなかった（bash -n は実行済み。導入するには: brew install shellcheck）"
fi

echo ""
echo "=== 1c. SKILL.md 埋め込み bash ブロックの構文チェック ==="
# SKILL.md には dispatch/work が実際に実行する bash コードブロックが埋め込まれている。
# 各 ```bash フェンスブロックを抽出して bash -n にかける。フェンスは箇条書きの入れ子で
# 書かれることがあるため、前後に空白を許した正規表現でマッチさせる。
#
# ブロックには <n> や <作業ブランチ> のようなプレースホルダが含まれる。山括弧をそのまま
# bash -n に渡すと、bash がリダイレクト演算子として誤解釈してプレースホルダ自体が構文
# エラーになる。そこでブロックを除外リストで持つ代わりに、検査前に `<...>` を安全な
# ダミートークンへ機械的に置換する。これで山括弧由来の偽陽性を消しつつ、クォートの
# 閉じ忘れのような本物の構文エラーは検出できる。置換パターンが `<(` を除外しているのは、
# `<(cmd1) <(cmd2) > out` のような行で2つ目のプロセス置換と実際のリダイレクトを1つの
# プレースホルダとして誤って飲み込まないようにするためである。
check_skill_bash_blocks() {
  local skill_file="$1"
  local label="$2"

  if [ ! -f "$skill_file" ]; then
    fail "$label: $skill_file が存在しない"
    return
  fi

  local open_re='^[[:space:]]*```bash[[:space:]]*$'
  local close_re='^[[:space:]]*```[[:space:]]*$'

  # 抽出ループとは独立に開始フェンスの総数を数え、ループ側の処理件数と突き合わせる。
  # ループのバグでブロックが黙って処理から漏れることを検出する二重チェックである。
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
      # 直後の rm -f で消すが、その手前で中断された場合に備えて登録しておく。
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
# SKILL.md ではないが、起票系3スキルが実行する bash を持つ正本なので同じ検査に乗せる。
check_skill_bash_blocks "$SOURCE_SKILLS_DIR/completed-tasks-lookup.md" "completed-tasks-lookup.md"

echo ""
echo "=== 1d. tests/ 配下の一時パスの後片付け作法 ==="
# tests/lib/common.sh が定める一時パスの後片付け作法から外れていないかを機械的に検査する。
# 走査対象は common.sh を source するファイル、すなわち tests/test_*.sh と tests/lib/*.sh に
# 限る。tests/run.sh は各テストファイルを子プロセスとして起動するランナーで common.sh を
# source しないため、レジストリをそもそも使えない（対象外）。
#
# 検査する規約は2つある。
# - 規約A: 一時パスを固定の絶対パスで組み立てない。作成は mktemp に任せる。
# - 規約B: mktemp の結果を代入した変数は、同じファイルの中で register_tmp_cleanup に渡す。
#   直後に mv で消費する場合でも登録する。登録の要否を呼び出し側の文脈から判別しようと
#   すると検査が脆くなるので、例外を設けず一律に揃える（cleanup は rm -rf なので、
#   既に無いパスの登録は無害である）。
check_tests_tmp_path_convention() {
  # 検出パターンに使う一時ディレクトリ名を変数に持たせているのは、直書きすると
  # このファイル自身が走査対象なので自分のパターンを規約A違反として検出してしまうため。
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
      # 行頭（インデント可）から始まる呼び出しに限定して探す。コメントアウトされた
      # 登録行を有効な登録と誤認しないためである。
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
