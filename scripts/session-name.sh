#!/usr/bin/env bash
# session-name.sh - 意味論的 tmux window 命名ヘルパー
#
# 提供関数:
#   generate_window_name <prefix> <worktree_path> <cwd>
#     → <prefix>-<repo>-<branch>[-i<issue>]-<h8> (max 50文字)
#   slugify <str> [<maxlen>]
#     → ASCII英数ハイフンのみのslug
#   find_existing_window <name> [session]
#     → session:index (未発見なら空文字。session 指定時はその session 内のみ探索)
#
# Note: set -e なし（source 時の親スクリプトに影響しないため）
# Note: 本スクリプトは source で読み込む（直接実行不可）

# slugify <str> [<maxlen>]
# 英数ハイフンのみのslugを生成。非ASCII・禁止文字は'-'に変換。空文字時は'x'。
slugify() {
  local s="$1" maxlen="${2:-50}"
  s=$(printf '%s' "$s" | LC_ALL=C tr -c '[:alnum:]-' '-' | sed -e 's/--\+/-/g' -e 's/^-//' -e 's/-$//')
  [ -z "$s" ] && s="x"
  s="${s:0:$maxlen}"
  s="${s%-}"
  printf '%s' "$s"
}

# generate_window_name <prefix> <worktree_path> <cwd>
# tmux window名を決定的に生成する。
# - prefix: "wt"(spawn) / "fk"(fork)
# - worktree_path: gitリポジトリ/worktreeの絶対パス
# - cwd: 実際の作業ディレクトリの絶対パス
# Returns: 非ゼロ終了 → 非gitディレクトリなどで生成不可
generate_window_name() {
  local prefix="$1"
  local worktree_path="$2"
  local cwd="$3"

  # リポジトリ同定: bare+worktree 両対応
  local common_dir repo_root repo_name
  common_dir=$(git -C "$worktree_path" rev-parse --git-common-dir 2>/dev/null) || return 1
  # common_dir が相対パスの場合は worktree_path 起点で解決
  case "$common_dir" in
    /*) ;;
    *) common_dir="${worktree_path}/${common_dir}" ;;
  esac
  repo_root=$(dirname "$(realpath -m "$common_dir")")
  repo_name=$(basename "$repo_root")
  repo_name=$(slugify "$repo_name" 16)

  # ブランチ名 (detached HEAD fallback: short SHA)
  local branch
  branch=$(git -C "$worktree_path" symbolic-ref --short -q HEAD 2>/dev/null \
    || git -C "$worktree_path" rev-parse --short HEAD 2>/dev/null) || return 1
  branch=$(slugify "$branch" 24)

  # Issue 番号 (厳格パターン: slug後の末尾 -<NNN> または ^<NNN>)
  local issue=""
  if [[ "$branch" =~ (^|-|_)([0-9]+)$ ]]; then
    issue="${BASH_REMATCH[2]}"
  fi

  # canonical_context hash (sha256の先頭8文字)
  local ctx hash
  ctx="${worktree_path}|${cwd}|${prefix}"
  hash=$(printf '%s' "$ctx" | sha256sum | cut -c1-8)

  # 名前組み立て
  local name="${prefix}-${repo_name}-${branch}"
  [ -n "$issue" ] && name="${name}-i${issue}"
  name="${name}-${hash}"

  # 最大長 50: 超過時は branch を truncate（hash は末尾固定）
  if [ ${#name} -gt 50 ]; then
    local overflow=$(( ${#name} - 50 ))
    local new_branch_len=$(( ${#branch} - overflow ))
    [ "$new_branch_len" -lt 4 ] && new_branch_len=4
    branch="${branch:0:$new_branch_len}"
    branch="${branch%-}"
    name="${prefix}-${repo_name}-${branch}"
    [ -n "$issue" ] && name="${name}-i${issue}"
    name="${name}-${hash}"
  fi

  printf '%s' "$name"
}

# ---------------------------------------------------------------------------
# spawn 命名（bd id 連動）— fleet-monitor.sh の worker↔window 完全一致照合の producer 側
#
# consumer（ubuntu-note-system/scripts/fleet-monitor.sh）は in_progress な bd issue id を
#   - window 名  wt-<id>             （"wt-" を厳密に剥がした残りを候補 id に）
#   - worktree   spawn/<id>-<HHMMSS> （ANCHOR/.worktrees/ 配下の最終セグメントから
#                                       末尾 -<数字> を剥がした残りを候補 id に）
# と awk $1==id / grep -qxF の **完全一致** で照合し ◆ を点灯する（部分一致しない＝誤検出ゼロ）。
# 本セクションはその producer。id を含む branch/worktree/window 名を本規約どおりに生成しないと
# 実 worker は点灯しない。並列 spawn 衝突回避の HHMMSS サフィックスは規約として維持する。
# ---------------------------------------------------------------------------

# normalize_bd_id <raw>
# 生の id トークンを canonical id へ正規化する（前後空白除去・先頭 # を剥がす）。
# 妥当な id（^[A-Za-z0-9][A-Za-z0-9.-]*$）でなければ空文字 + 非ゼロ終了。
# 階層 bd id（dotted, 例 un-3sh.3 / un-3sh.3.2）を許容する: consumer（fleet-monitor.sh）は
# "wt-" 剥がし + 末尾 -<数字> 剥がしで候補 id を作り、文字クラス検証をしない＝dotted id を完全一致で
# 復元できる。よって producer も '.' を内部文字として通す必要がある（拒否すると階層 worker が点灯しない）。
# 一方 path/window 名へ直接埋め込むため、path traversal 系（'/' を含む・'..' を含む）は構造的に拒否する。
# ('.' 単体や 'a.b' は traversal ではない＝許容。危険なのは '/' と '..' のみ。)
normalize_bd_id() {
  local raw="${1:-}"
  raw="${raw#"${raw%%[![:space:]]*}"}"   # 先頭空白除去
  raw="${raw%"${raw##*[![:space:]]}"}"   # 末尾空白除去
  raw="${raw#\#}"                          # 先頭 # を剥がす（#123 → 123）
  [[ "$raw" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || return 1
  [[ "$raw" == *".."* ]] && return 1       # '..' を含む id は path traversal なので拒否
  [[ "$raw" == *"/"* ]]  && return 1       # '/' を含む id は path separator なので拒否（char class で既に除外だが防御的に明示）
  printf '%s' "$raw"
}

# extract_bd_id <text>
# プロンプト/引数テキストから bd issue id を抽出する。**明示アンカー優先**で
# bare-slug フォールバックは最終手段（hyphenated 英単語の誤検出を避けるため）。
# 対応形式（優先順）:
#   1. #123                  → 123     （明示 issue 参照。先頭 # を剥がす）
#   2. アンカー付き id        → <id>    （"cell: <id>" / "bd id: <id>" / "issue: <id>" の直後トークン。
#                                          dotted 階層 id も '.' 込みで丸ごと捕捉）
#   3. bare-slug <prefix>-<slug> → <id> （最終手段。dotted id も '.' 込みで捕捉。
#                                          "read-only" 等の hyphenated 英単語も一致しうるため確実性は低い）
# 該当なしは空文字 + 非ゼロ終了。
# 注: 確実性が要る箇所では呼出側（spawn スキルの NLU / --bd-id）が明示特定した id を渡すこと
#     （args 経路が一次・信頼境界）。bare-slug フォールバック（優先3）は best-effort の last resort。
extract_bd_id() {
  local text="${1:-}" tok norm anchored
  # 英数・# ・- ・. ・: 以外を空白へ（glob/特殊文字を無害化しつつトークン境界を作る。
  # '.' は dotted 階層 id を丸ごと捕捉するため・':' はアンカー検出のため保持）
  norm=$(printf '%s' "$text" | LC_ALL=C tr -c '[:alnum:]#.:-' ' ')

  # 各トークンの末尾句読点（'.'/':'/'-' 等の非英数の連なり）を剥がす。文末ピリオド等を id に
  # 取り込むと consumer 照合不一致（wt-un-cbi. ≠ bd id un-cbi）を起こすため。bd id は必ず英数で
  # 終わる（dotted 階層 id も最終セグメントは英数）ので末尾非英数の除去は安全。アンカー語 'cell:'
  # 等も 'cell' へ正規化され case 判定はそのまま通る（両形を列挙済み）。
  # 実装: ${t##*[A-Za-z0-9]} は最後の英数より後ろの非英数 suffix、それを ${t%...} で除去。

  # 優先1: #<digits>（明示 issue 参照は曖昧さがなく最優先）
  for tok in $norm; do
    tok="${tok%"${tok##*[A-Za-z0-9]}"}"
    if [[ "$tok" =~ ^#([0-9]+)$ ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  done

  # 優先2: 明示アンカー（cell: / bd id: / issue: / id:）の直後の id トークン。
  # アンカー語の直後に来る最初の id 形トークンを採る（hyphenated 英単語の誤検出を構造的に避ける）。
  anchored=0
  for tok in $norm; do
    tok="${tok%"${tok##*[A-Za-z0-9]}"}"
    if (( anchored )); then
      # アンカー直後トークンが id 形なら採用、そうでなければアンカー状態を解除して継続探索
      if [[ "$tok" =~ ^[a-z][a-z0-9]*(-[a-z0-9.]+)+$ ]]; then
        printf '%s' "$tok"
        return 0
      fi
      if [[ "$tok" =~ ^[0-9]+$ ]]; then
        printf '%s' "$tok"
        return 0
      fi
      anchored=0
    fi
    case "$tok" in
      cell:|cell|bd:|bd|issue:|issue|id:|id) anchored=1 ;;
    esac
  done

  # 優先3: bare-slug <prefix>-<slug>（最終手段。dotted id も '.' 込みで捕捉）。
  # "read-only" / "multi-line" 等の hyphenated 英単語も構造的には一致しうるため、
  # 既知の常用 hyphenated 英単語は denylist で除外する（誤った wt-read-only window を防ぐ）。
  # ここを通り抜ける誤検出は確実性が要る箇所では呼出側 --bd-id の明示指定で回避すること。
  for tok in $norm; do
    tok="${tok%"${tok##*[A-Za-z0-9]}"}"
    if [[ "$tok" =~ ^[a-z][a-z0-9]*(-[a-z0-9.]+)+$ ]]; then
      case "$tok" in
        read-only|read-write|multi-line|multi-stage|multi-step|multi-agent|\
        single-line|end-to-end|up-to-date|opt-in|opt-out|fail-open|fail-closed|\
        well-known|so-called|long-term|short-term|left-right|top-down|bottom-up)
          continue ;;
      esac
      printf '%s' "$tok"
      return 0
    fi
  done
  return 1
}

# spawn_branch_name <bd_id> [<hhmmss>] [<pid>]
# spawn worktree/branch 名を生成する。
#   bd_id 有り: spawn/<id>-<HHMMSS>   （fleet-monitor が末尾 -<数字> を剥がして id を復元）
#   bd_id 空/無効: spawn/<HHMMSS>-<pid> （現行フォールバック。id 非含有＝点灯しないが衝突回避は維持）
# hhmmss/pid は決定論的テストのため引数で注入可（既定は date +%H%M%S / $$）。
spawn_branch_name() {
  local bd_id="${1:-}" hhmmss="${2:-}" pid="${3:-}"
  [[ -z "$hhmmss" ]] && hhmmss=$(date +%H%M%S)
  [[ -z "$pid" ]] && pid=$$
  if [[ -n "$bd_id" ]] && bd_id=$(normalize_bd_id "$bd_id"); then
    printf 'spawn/%s-%s' "$bd_id" "$hhmmss"
  else
    printf 'spawn/%s-%s' "$hhmmss" "$pid"
  fi
}

# spawn_window_name <bd_id>
# spawn tmux window 名を生成する。
#   bd_id 有り: wt-<id>  （fleet-monitor が "wt-" を剥がして id を復元）
#   bd_id 空/無効: 空文字 （呼出側が generate_window_name / 時刻フォールバックへ委譲）
spawn_window_name() {
  local bd_id="${1:-}"
  [[ -z "$bd_id" ]] && return 0
  bd_id=$(normalize_bd_id "$bd_id") || return 0
  printf 'wt-%s' "$bd_id"
}

# find_existing_window <name> [session]
# 指定名のtmux windowを検索し、"session:index"形式で返す。未発見なら空文字。
# 第2引数 session を渡すと **その session 内のみ** 探索する（window 再利用の session-scope 化・
# ccs-y9h: 全 session 横断の bare 名一致再利用は別プロジェクト session の同名 window を掴む
# topology drift の一因だったため、生成スコープ＝再利用スコープに揃える）。
# 省略時は従来どおり全 session 横断（後方互換）。session は '=' 前置の exact match で解決する
# （tmux の -t は既定 prefix match のため）。session 不在時はエラーにせず空文字（未発見扱い）。
find_existing_window() {
  local name="$1" session="${2:-}" out=""
  # tmux の exit status を pipeline に伝播させない（session 不在で list-windows は exit 1 になる。
  # 呼び出し元 cld-spawn は set -euo pipefail のため、直結 pipeline だと create-if-absent に
  # 到達する前に silent 死する——ライブ e2e で実証・ccs-y9h）。出力を先に確保し || で吸収する。
  if [ -n "$session" ]; then
    out=$(tmux list-windows -t "=$session" -F '#{session_name}:#{window_index} #{window_name}' 2>/dev/null) || out=""
  else
    out=$(tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name}' 2>/dev/null) || out=""
  fi
  printf '%s\n' "$out" | awk -v n="$name" '$2==n {print $1; exit}'
}
