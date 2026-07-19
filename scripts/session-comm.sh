#!/bin/bash
# =============================================================================
# session-comm.sh - Claude Code セッション間通信プリミティブ
#
# Usage:
#   session-comm.sh capture <window> [--lines N] [--raw]
#   session-comm.sh inject <window> <text> [--force] [--no-enter]
#   session-comm.sh inject-file <window> <file> [--force] [--no-enter] [--wait SECONDS] [--confirm-receipt SECONDS] [--clear-first]
#   session-comm.sh wait-ready <window> [--timeout N]
#
# Dependencies: session-state.sh (#277)
# =============================================================================
set -euo pipefail

# SCRIPT_DIR は常に実スクリプトディレクトリを指す（バックエンド読み込みに使用）
# _state_script_dir はテスト時に SESSION_COMM_SCRIPT_DIR で session-state.sh のみを差し替える
# Issue #1048: SESSION_COMM_SCRIPT_DIR は信頼境界として「実在ディレクトリ」かつ
# 「session-state.sh を含む」ことを検証し、攻撃者による任意パス上書きを拒否する
# M2 (#1048 follow-up): realpath で symlink を解決して実 path に固定し、
# check と use の間に symlink 差し替えされる TOCTOU race window を縮小する
# Fix #1679: SCRIPT_DIR を上書きしないことで session-comm-backend-tmux.sh の
# source に失敗するバグを修正（SESSION_COMM_SCRIPT_DIR は state script 専用）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${_TEST_MODE:-}" ]] && [[ -n "${SESSION_COMM_SCRIPT_DIR:-}" ]] \
    && [[ -d "$SESSION_COMM_SCRIPT_DIR" ]] \
    && [[ -f "$SESSION_COMM_SCRIPT_DIR/session-state.sh" ]]; then
    _resolved_state=""
    if command -v realpath >/dev/null 2>&1; then
      _resolved_state=$(realpath "$SESSION_COMM_SCRIPT_DIR/session-state.sh" 2>/dev/null || true)
    fi
    if [[ -z "$_resolved_state" ]] && command -v greadlink >/dev/null 2>&1; then
      _resolved_state=$(greadlink -f "$SESSION_COMM_SCRIPT_DIR/session-state.sh" 2>/dev/null || true)
    fi
    if [[ -z "$_resolved_state" ]] && command -v python3 >/dev/null 2>&1; then
      _resolved_state=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$SESSION_COMM_SCRIPT_DIR/session-state.sh" 2>/dev/null || true)
    fi
    if [[ -n "$_resolved_state" && -f "$_resolved_state" ]]; then
      _state_script_dir=$(dirname "$_resolved_state")
    else
      _state_script_dir="$SESSION_COMM_SCRIPT_DIR"
    fi
    unset _resolved_state
else
    _state_script_dir="$SCRIPT_DIR"
fi
MAX_INJECT_LEN=4096
DEFAULT_CAPTURE_LINES=50
DEFAULT_TIMEOUT=30

# =============================================================================
# ユーティリティ
# =============================================================================
usage() {
    cat <<'EOF'
Usage:
  session-comm.sh capture <window> [--lines N] [--all] [--raw]
  session-comm.sh inject <window> <text> [--force] [--no-enter]
  session-comm.sh inject-file <window> <file> [--force] [--no-enter] [--wait SECONDS] [--confirm-receipt SECONDS] [--clear-first]
  session-comm.sh wait-ready <window> [--timeout SECONDS]

Subcommands:
  capture      Capture pane content (ANSI stripped by default)
               --all   Capture full scrollback (mutually exclusive with --lines)
  inject       Send single-line text to a window (state-checked)
  inject-file  Send file content to a window via tmux load-buffer (multi-line safe)
               --wait SECONDS             Wait for input-waiting state before injecting
               --confirm-receipt SECONDS  After Enter, confirm claude accepted the prompt
                                          (prompt content appears OR processing observed);
                                          exit 4 if not confirmed within SECONDS (ccs-ldt)
               --clear-first              Send C-u before paste to clear stale input (for re-send)
  wait-ready   Wait until window is input-waiting

Exit codes (inject-file / --confirm-receipt read-back — SSOT of the delivery contract; ccs-3bj):
  0  accepted     Submit の積極証拠あり（clean submit）。caller は再送しない。
  1  error         引数不正 / lock / resolve / paste 失敗など一般エラー。
  2  gate          宛先が input-waiting に到達しない（--wait timeout / state 不一致）。未 paste。
  4  未着(vanished) read-back が submit の積極証拠を得られず（真の消失/boot-race）。caller は再送する。
  5  queued        busy 宛先で paste が CC message queue に積まれ受理された積極証拠あり（ccs-3bj）。
                   caller は**再送禁止**（再送は重複 queue＝--clear-first では dequeue 不能）。
                   ★既定 OFF＝opt-in（GATE ROUND-1・2026-07-20）: SESSION_COMM_QUEUED_MARKER_RE を**非空 set**
                   したときのみ本経路が有効。未 set / 空 set は queued 検知 OFF＝旧挙動（証拠不在→4→再送＝安全側）。
                   opt-in 時の検知条件=「live turn 観測 ∧ queued マーカーが outside view に baseline 新規 echo
                   ∧ sentinel 未 echo」の積極証拠のみ（証拠不在→4）。既定 OFF の理由: live e2e 実測で現行 TUI の
                   queued 実表示は interior=『Press up to edit queued messages』で、本経路の位置前提（marker=
                   outside ∧ interior 空）と逆＝regex 差替えだけでは有効化できず真陽性ゼロ（述語 rework は
                   follow-up）。mid-busy paste は (A)/(B) が受理し重複ゼロを実測ゆえ既定 OFF は機能損失ゼロで
                   fail-open（汎用語 default-on の偽 exit5=silent 消失）だけを除去する。実マーカー実測形は
                   ccs-3bj notes 2026-07-20 参照。※exit 3 は将来の busy 前 gate(a) 用に予約（未使用）。

Environment:
  SESSION_COMM_SUBMIT_ENTER_MAX  paste 後に未 submit（input-waiting 滞留）なら撃つ追い Enter の上限
                                 （既定 3, 0=無効）。複数行 paste が [Pasted text +M lines] に
                                 折りたたまれ既定 Enter が吸収される事象の救済（un-iur）。承認/質問
                                 ダイアログ可視時は modality ガードで送らない。leading-zero 無しの非負整数のみ。
  SESSION_COMM_LOCK_WAIT         inject / inject-file が同一 pane で共有する flock の acquire 上限秒を
                                 上書きする（正整数）。既定は inject=90 / inject-file=wait+confirm+30。
                                 inject-file の長時間送達を待つ単一行 inject の spurious 失敗を調停する。
EOF
    exit 1
}

# ウィンドウのtmuxターゲットを解決
resolve_target() {
    local window_name="$1"
    if [[ "$window_name" == *:* ]]; then
        local session="${window_name%%:*}"
        local win="${window_name#*:}"
        if ! [[ "$session" =~ ^[A-Za-z0-9_./\-]+$ ]]; then
            echo "Error: invalid target format '$window_name'" >&2
            return 1
        fi
        if [[ -z "$win" ]]; then
            echo "Error: invalid target format '$window_name'" >&2
            return 1
        fi
        if ! tmux has-session -t "$session" 2>/dev/null; then
            echo "Error: session '$session' not found" >&2
            return 1
        fi
        # numeric window index: use session:index directly
        if [[ "$win" =~ ^[0-9]+$ ]]; then
            echo "$window_name"
            return
        fi
        # window name allowlist: reject characters that could cause issues
        if ! [[ "$win" =~ ^[A-Za-z0-9_./\-]+$ ]]; then
            echo "Error: invalid window name '$win'" >&2
            return 1
        fi
        # window name: resolve to session:index within the specified session
        local target=""
        target=$(tmux list-windows -t "$session" -F '#{session_name}:#{window_index} #{window_name}' 2>/dev/null \
            | awk -v name="$win" '$2 == name { print $1; exit }')
        if [[ -z "$target" ]]; then
            echo "Error: window '$win' not found in session '$session'" >&2
            return 1
        fi
        echo "$target"
        return
    fi
    local target
    target=$(tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name}' 2>/dev/null \
        | awk -v name="$window_name" '$2 == name { print $1; exit }')
    if [[ -z "$target" ]]; then
        echo "Error: window '$window_name' not found" >&2
        return 1
    fi
    echo "$target"
}

# ANSI エスケープコード除去
strip_ansi() {
    sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b(B//g'
}

# 制御文字サニタイズ（タブ以外の 0x00-0x1F を除去。改行・CRも除去: 単一行入力のみ）
sanitize_text() {
    tr -d '\000-\010\012-\015\016-\037'
}

# =============================================================================
# _resolve_lock_file <target>
#   SESSION_COMM_LOCK_DIR を検証・作成し、target 用の flock ロックファイルパスを stdout に返す。
#   cmd_inject（単一行）と cmd_inject_file（複数行）の**共通 SSOT**（un-7nw part2）。
#   同一 target への並列送信を直列化するロックファイル名を両者で一致させ、inject と inject-file が
#   同じ pane を同時に触る lost-update も相互に防ぐ（両サブコマンドが同一ロックを掴む）。
#
#   バリデーション方針（cmd_inject から移設した既存挙動を byte 等価で保持）:
#     - 相対パス / '..' を含む → Warning を出し /tmp へフォールバック（exit しない・従来挙動）。
#     - 絶対パスだが allowlist 外（/tmp・/run/user/<uid> 以外）→ Error + return 1（fail-closed）。
#       ※ XDG_RUNTIME_DIR は攻撃者制御可能なため allowlist に使わず、id -u で実解決する（#1239）。
#     - mkdir -p 失敗 → Error + return 1。
#   返り値: 成功時 0（stdout=ロックファイルパス）／不許可・作成不可時 1（stdout 空）。
# =============================================================================
_resolve_lock_file() {
    local target="$1"
    local lock_dir="${SESSION_COMM_LOCK_DIR:-/tmp}"
    if [[ -n "${SESSION_COMM_LOCK_DIR:-}" ]]; then
        if [[ "${SESSION_COMM_LOCK_DIR}" != /* ]] || [[ "${SESSION_COMM_LOCK_DIR}" =~ \.\. ]]; then
            echo "Warning: SESSION_COMM_LOCK_DIR '${SESSION_COMM_LOCK_DIR}' is invalid (must be absolute path without '..'), using /tmp" >&2
            lock_dir="/tmp"
        else
            # OWASP A01: allowlist で許可パスを制限（#1239）
            # /tmp または /run/user/<uid> プレフィックスのみ許可
            # XDG_RUNTIME_DIR は攻撃者制御可能なため使用しない（環境変数汚染対策）
            local xdg_runtime="/run/user/$(id -u)"
            local is_allowed=false
            [[ "${SESSION_COMM_LOCK_DIR}" == /tmp || "${SESSION_COMM_LOCK_DIR}" == /tmp/* ]] && is_allowed=true
            [[ "${SESSION_COMM_LOCK_DIR}" == "${xdg_runtime}" || "${SESSION_COMM_LOCK_DIR}" == "${xdg_runtime}/"* ]] && is_allowed=true
            if ! $is_allowed; then
                echo "Error: SESSION_COMM_LOCK_DIR '${SESSION_COMM_LOCK_DIR}' is not allowed (allowlist: /tmp, ${xdg_runtime})" >&2
                return 1
            fi
        fi
    fi
    mkdir -p "$lock_dir" 2>/dev/null || {
        echo "Error: lock directory '$lock_dir' (SESSION_COMM_LOCK_DIR) is not creatable" >&2
        return 1
    }
    printf '%s/session-comm-%s.lock' "$lock_dir" "${target//[^a-zA-Z0-9]/-}"
}

# _lock_wait_for <default>
#   flock の acquire 上限秒を返す。SESSION_COMM_LOCK_WAIT が設定されていれば（正整数検証して）それを、
#   無ければ引数の既定値を返す。cmd_inject と cmd_inject_file は同一 target で**共有ロック**を掴むため
#   （_resolve_lock_file が同名を返す）、片側の長時間ホールド（inject-file は最長 wait_timeout+confirm_receipt
#   秒保持しうる）を待てる acquire 上限が要る。単一行 inject 側の既定は inject-file の cld-spawn 既定ホールド
#   （--wait 60 + --confirm-receipt 10 = ~70s）を越える値にする（gate round-1 CONFIRMED #5 の修正）。
#   両者を SESSION_COMM_LOCK_WAIT で一括調停でき、非整数は fail-closed で弾く。
_lock_wait_for() {
    local _default="$1"
    local _w="${SESSION_COMM_LOCK_WAIT:-$_default}"
    if ! [[ "$_w" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: SESSION_COMM_LOCK_WAIT requires a positive integer (got '$_w')" >&2
        return 1
    fi
    printf '%s' "$_w"
}

# =============================================================================
# サブコマンド: capture
# =============================================================================
cmd_capture() {
    local window_name=""
    local lines=$DEFAULT_CAPTURE_LINES
    local lines_set=false
    local raw=false
    local all=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --lines)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --lines requires a value" >&2
                    exit 1
                fi
                lines="$2"
                lines_set=true
                if ! [[ "$lines" =~ ^[0-9]+$ ]] || [[ "$lines" -eq 0 ]]; then
                    echo "Error: --lines requires a positive integer" >&2
                    exit 1
                fi
                shift 2
                ;;
            --all)
                all=true
                shift
                ;;
            --raw)
                raw=true
                shift
                ;;
            -*)
                echo "Error: unknown option '$1'" >&2
                usage
                ;;
            *)
                if [[ -z "$window_name" ]]; then
                    window_name="$1"
                else
                    echo "Error: unexpected argument '$1'" >&2
                    usage
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$window_name" ]]; then
        echo "Error: window name required" >&2
        usage
    fi

    # --all と --lines は排他
    if $all && $lines_set; then
        echo "Error: --all and --lines are mutually exclusive" >&2
        exit 1
    fi

    local target
    target=$(resolve_target "$window_name") || exit 1

    local captured
    if $all; then
        captured=$(tmux capture-pane -p -t "$target" -S - 2>/dev/null) || {
            echo "Error: failed to capture pane for '$window_name'" >&2
            exit 1
        }
    else
        captured=$(tmux capture-pane -p -t "$target" -S "-${lines}" 2>/dev/null) || {
            echo "Error: failed to capture pane for '$window_name'" >&2
            exit 1
        }
    fi

    if $raw; then
        printf '%s\n' "$captured"
    else
        printf '%s\n' "$captured" | strip_ansi
    fi
}

# =============================================================================
# サブコマンド: inject
# =============================================================================
cmd_inject() {
    local window_name=""
    local text=""
    local force=false
    local no_enter=false

    # 最初の2つの位置引数を取得
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                force=true
                shift
                ;;
            --no-enter)
                no_enter=true
                shift
                ;;
            -*)
                echo "Error: unknown option '$1'" >&2
                usage
                ;;
            *)
                if [[ -z "$window_name" ]]; then
                    window_name="$1"
                elif [[ -z "$text" ]]; then
                    text="$1"
                else
                    echo "Error: unexpected argument '$1'" >&2
                    usage
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$window_name" ]]; then
        echo "Error: window name required" >&2
        usage
    fi
    if [[ -z "$text" ]]; then
        echo "Error: text required" >&2
        usage
    fi

    # サニタイズ
    text=$(printf '%s' "$text" | sanitize_text)

    # 最大長チェック
    if [[ ${#text} -gt $MAX_INJECT_LEN ]]; then
        echo "Error: text exceeds maximum length of ${MAX_INJECT_LEN} bytes" >&2
        exit 1
    fi

    local target
    target=$(resolve_target "$window_name") || exit 1

    # 状態チェック + retry（AC2: non-input-waiting 時は 5 秒後に retry）
    local max_retry_count=1
    local retry_count=0
    local state
    while true; do
        if ! state=$("${_state_script_dir}/session-state.sh" state "$window_name" 2>/dev/null); then
            echo "Warning: session-state.sh failed for '$window_name'" >&2
            state="unknown"
        fi

        if [[ "$state" == "input-waiting" ]]; then
            break
        fi

        if $force; then
            echo "Warning: target '$window_name' is in state '$state' (not input-waiting), sending anyway" >&2
            break
        fi

        if [[ "$retry_count" -ge "$max_retry_count" ]]; then
            echo "Error: target '$window_name' is in state '$state' (expected: input-waiting)" >&2
            exit 2
        fi

        sleep "${SESSION_COMM_RETRY_DELAY:-5}"  # AC2: 5 秒待機後に retry
        ((retry_count++)) || true
    done

    # flock で排他制御（AC1: 同一 pane への並列送信を直列化）
    # lock_dir 検証・作成とロックファイル名導出は _resolve_lock_file（cmd_inject_file と共通の SSOT）に委譲。
    # acquire 上限（gate round-1 CONFIRMED #5 の修正）: このロックは inject-file と**共有**され、inject-file は
    # 同一 target を最長 wait_timeout+confirm_receipt 秒（cld-spawn 既定 ~70s）保持しうる。旧 30s では正当な
    # inject-file 送達中に単一行 inject が spurious に取得失敗したため、既定を 90s（~70s ホールド＋余裕）へ引き上げる。
    # SESSION_COMM_LOCK_WAIT で inject / inject-file 双方の上限を一括調停できる（非整数は fail-closed）。
    local lock_file _lock_wait
    lock_file=$(_resolve_lock_file "$target") || exit 1
    _lock_wait=$(_lock_wait_for 90) || exit 1
    {
        flock -w "$_lock_wait" 9 || {
            echo "Error: failed to acquire send lock for '$window_name' (waited ${_lock_wait}s)" >&2
            exit 1
        }
        if $no_enter; then
            session_msg send "$target" "$text" --no-enter || {
                echo "Error: failed to send keys to '$window_name'" >&2
                exit 1
            }
        else
            session_msg send "$target" "$text" || {
                echo "Error: failed to send keys to '$window_name'" >&2
                exit 1
            }
        fi
    } 9>"$lock_file"
}

# =============================================================================
# read-back 判定ヘルパ（ccs-mxv・positive-proof 化）
#
# 受理述語から sentinel-presence（＝到着の証拠）を排除する。sentinel の pane 出現は
# 「paste が届いた」ことしか証明せず「submit（turn 開始）」を証明しない——boot 中の
# promo/TUI 再描画が初回 Enter を食うと、入力欄残留や一過性フレームの sentinel で
# 偽『受理』を返し spawn kickoff が silent 消失する（orch-sm6p/sc-8g5 verified・orch-ttqe）。
# 設計原本は scribe-inject do_verify の実証済み核（入力欄 interior 抽出 + 3 値分類・
# DJ-b「Enter は RESIDUAL のときだけ」）。
# =============================================================================

# bracketed paste の折りたたみ placeholder（scribe-inject PASTE_PLACEHOLDER_RE と同型・
# 入力欄内に見えたら「我々の paste が未 submit で滞留」＝RESIDUAL 扱い＝un-iur の救済対象）
_RB_PASTE_PLACEHOLDER_RE='\[[Pp]asted text|\[[0-9]+ (more )?lines?( pasted)?\]|[Pp]asted [0-9]+ lines?'

# _rb_is_input_rule <line> — 入力欄を囲む水平罫線行か（─×10 連以上・box 側面/角 glyph を含まない）
_rb_is_input_rule() {
    case "$1" in
        *"│"*|*"┌"*|*"┐"*|*"└"*|*"┘"*|*"├"*|*"┤"*|*"┬"*|*"┴"*|*"┼"*|*"╭"*|*"╮"*|*"╰"*|*"╯"*) return 1 ;;
    esac
    case "$1" in
        *"──────────"*) return 0 ;;
    esac
    return 1
}

# _rb_extract_input_box [--outside] — stdin の pane capture から入力欄 interior（既定）を抽出して
#   stdout へ。--outside は逆に **入力欄（枠含む）を除いた残り**（transcript/status 領域）を出す
#   （(A)/(B) の受理判定はこの outside view に対して行う＝入力欄残留の内容を積極証拠に混ぜない）。
#   Type A: 最下部の水平罫線ペア / Type B: 最下部の corner box（╰/└ → 直上の ╭/┌）。
#   見つからなければ exit 4（interior 不明＝呼出側は INCONCLUSIVE 扱い・受理も Enter もしない）。
_rb_extract_input_box() {
    local outside=0
    [[ "${1:-}" == "--outside" ]] && outside=1
    local -a lines=()
    mapfile -t lines
    local n=${#lines[@]} i start=-1 end=-1 bt=-1 bb=-1
    # Type A 候補（最下部の水平罫線ペア）と Type B 候補（最下部の corner box）を**両方**探し、
    # 「入力欄は常に pane 最下部の box」という不変条件で bottom edge がより下の候補を採用する。
    # Type A を無条件優先すると、corner 入力欄の pane で transcript の markdown 水平線ペアを
    # 入力欄と誤認し、実在の残留 corner box が outside へ漏れて偽受理する（round-3 review
    # wf_d526dfaa が決定論再現・box 誤帰属の封鎖）。
    local r2=-1 r1=-1
    for ((i = n - 1; i >= 0; i--)); do
        if _rb_is_input_rule "${lines[i]}"; then r2=$i; break; fi
    done
    if (( r2 >= 0 )); then
        for ((i = r2 - 1; i >= 0; i--)); do
            if _rb_is_input_rule "${lines[i]}"; then r1=$i; break; fi
        done
    fi
    local bot=-1 top=-1
    for ((i = n - 1; i >= 0; i--)); do
        case "${lines[i]}" in *"╰"*|*"└"*) bot=$i; break ;; esac
    done
    if (( bot >= 0 )); then
        for ((i = bot - 1; i >= 0; i--)); do
            case "${lines[i]}" in *"╭"*|*"┌"*) top=$i; break ;; esac
        done
    fi
    local a_ok=0 b_ok=0
    (( r2 >= 0 && r1 >= 0 )) && a_ok=1
    (( bot >= 0 && top >= 0 )) && b_ok=1
    if (( a_ok && b_ok )); then
        if (( bot > r2 )); then
            start=$((top + 1)); end=$((bot - 1)); bt=$top; bb=$bot
        else
            start=$((r1 + 1)); end=$((r2 - 1)); bt=$r1; bb=$r2
        fi
    elif (( a_ok )); then
        start=$((r1 + 1)); end=$((r2 - 1)); bt=$r1; bb=$r2
    elif (( b_ok )); then
        start=$((top + 1)); end=$((bot - 1)); bt=$top; bb=$bot
    else
        return 4
    fi
    if (( outside )); then
        for ((i = 0; i < n; i++)); do
            if (( i >= bt && i <= bb )); then continue; fi
            printf '%s\n' "${lines[i]}"
        done
        return 0
    fi
    local first=1 line stripped
    for ((i = start; i <= end; i++)); do
        line="${lines[i]}"
        # 枠側面・box-drawing・交差 glyph を除去（内容だけ残す）
        line="${line//│/}"; line="${line//─/}"
        line="${line//╭/}"; line="${line//╮/}"; line="${line//╰/}"; line="${line//╯/}"
        line="${line//┌/}"; line="${line//┐/}"; line="${line//└/}"; line="${line//┘/}"
        line="${line//├/}"; line="${line//┤/}"; line="${line//┬/}"; line="${line//┴/}"; line="${line//┼/}"
        if (( first )); then
            # 先頭 interior 行のプロンプト記号（❯ / >）を 1 つ剥ぐ
            line="${line#"${line%%[![:space:]]*}"}"
            stripped="${line#❯}"; line="$stripped"
            stripped="${line#>}"; line="$stripped"
            first=0
        fi
        printf '%s\n' "$line"
    done
}

# _rb_classify_interior <interior> <head_sentinel> <tail_marker> — 入力欄 interior の 3 値分類。
#   return 3 = RESIDUAL（我々の注入テキスト or paste placeholder が入力欄に居る＝「未 submit」の積極証明。
#              救済 Enter の唯一の発火条件・DJ-b。RESIDUAL とダイアログ表示は**原則**排他——ダイアログは
#              interior を占め marker 不在→INCONCLUSIVE になる——が、ダイアログ文言が marker 断片を
#              偶発包含する衝突があるため、呼出側は dialog modality ガードを belt で併用すること）
#   return 0 = DELIVERED（interior 空＝入力欄クリア）
#   return 2 = INCONCLUSIVE（帰属不能な非空内容＝ダイアログ/他者入力。受理も Enter もしない）
_rb_classify_interior() {
    local interior="$1" head_sent="$2" tail_marker="$3"
    if [[ -n "$head_sent" ]] && printf '%s' "$interior" | grep -qF -- "$head_sent"; then return 3; fi
    if [[ -n "$tail_marker" ]] && printf '%s' "$interior" | grep -qF -- "$tail_marker"; then return 3; fi
    if printf '%s' "$interior" | grep -qE -- "$_RB_PASTE_PLACEHOLDER_RE"; then return 3; fi
    # 空判定: 空白・NBSP（実 CC TUI の空入力欄は「❯ + NBSP」）・余剰プロンプト記号のみなら DELIVERED
    local core
    core="$(printf '%s' "$interior" | tr -d '[:space:]')"
    core="${core//$'\xc2\xa0'/}"
    core="${core//>/}"
    core="${core//❯/}"
    [[ -z "$core" ]] && return 0
    return 2
}

# =============================================================================
# サブコマンド: inject-file
# =============================================================================
cmd_inject_file() {
    local window_name=""
    local file_path=""
    local force=false
    local no_enter=false
    local wait_timeout=0       # 0 = 待機なし（単発チェック）
    local confirm_receipt=0    # 0 = 送達 read-back なし（後方互換・既定）。>0 で paste 後に受理を確認（ccs-ldt）
    local clear_first=false    # true で paste 前に C-u 送出（再送時の部分入力クリア・重複防止）

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                force=true
                shift
                ;;
            --no-enter)
                no_enter=true
                shift
                ;;
            --wait)
                wait_timeout="${2:-10}"
                if ! [[ "$wait_timeout" =~ ^[1-9][0-9]*$ ]]; then
                    echo "Error: --wait requires a positive integer" >&2
                    exit 1
                fi
                shift 2
                ;;
            --confirm-receipt)
                confirm_receipt="${2:-8}"
                if ! [[ "$confirm_receipt" =~ ^[1-9][0-9]*$ ]]; then
                    echo "Error: --confirm-receipt requires a positive integer" >&2
                    exit 1
                fi
                shift 2
                ;;
            --clear-first)
                clear_first=true
                shift
                ;;
            -*)
                echo "Error: unknown option '$1'" >&2
                usage
                ;;
            *)
                if [[ -z "$window_name" ]]; then
                    window_name="$1"
                elif [[ -z "$file_path" ]]; then
                    file_path="$1"
                else
                    echo "Error: unexpected argument '$1'" >&2
                    usage
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$window_name" ]]; then
        echo "Error: window name required" >&2
        usage
    fi
    if [[ -z "$file_path" ]]; then
        echo "Error: file path required" >&2
        usage
    fi
    if [[ ! -f "$file_path" ]]; then
        echo "Error: file not found: $file_path" >&2
        exit 1
    fi

    # 追い Enter（un-iur）の上限。paste 前に検証する＝fail-closed（兄弟の --confirm-receipt/--wait と対称）。
    # paste 後の算術文脈で初めて評価すると、malformed 値（例 'abc'）が set -u 下で `unbound variable` を
    # 投げて『paste 済み・初回 Enter 送出済み』の状態で abort し、confirm_receipt==0 経路（read-back 無し）の
    # 呼び出し側に『送達済みか未送達か』を判別不能にする fail-confusing パスになる。ここで弾けばその窓を閉じる。
    # 受理: 正準な非負整数のみ（0 または leading-zero 無しの正整数）。0 は『追い Enter を意図的に無効化』
    # として許す（=複数行 paste 折りたたみ時に Enter 吸収が起きても submit は初回 Enter 任せ＝未送信のまま
    # 返りうる）。負値は un-iur を無音で殺すため拒否。
    # leading-zero 拒否（errata un-iur）: `^[0-9]+$` だと 008/009 を通すが、下の算術文脈
    #   [[ "$_se_i" -lt "$_se_max" ]] / [[ "$_rb_resub" -lt "$_se_max" ]] で bash が leading-zero を
    # 不正 octal と解釈し `value too great for base` → 条件が偽になり追い Enter/救済 Enter が 0 回・exit 0、
    # つまり本修正自体が無音で disable される fail-open になる。兄弟 --confirm-receipt/--wait（^[1-9][0-9]*$）と
    # 対称に leading-zero を明示 exit 1 で拒否し、silent 再解釈ではなく fail-closed で弾く。0=disable は温存。
    local _se_max="${SESSION_COMM_SUBMIT_ENTER_MAX:-3}"
    if ! [[ "$_se_max" =~ ^(0|[1-9][0-9]*)$ ]]; then
        echo "Error: SESSION_COMM_SUBMIT_ENTER_MAX requires a non-negative integer without leading zeros (got '$_se_max')" >&2
        exit 1
    fi

    # modality ガードの dialog 判別 regex を session-state.sh の INPUT_WAITING_PATTERNS（SSOT）から導出する。
    # 手書き複製は drift で fail-open（新 dialog 文言が片側だけに追加されると detect_state は input-waiting と
    # 分類するのに regex は一致せず、real dialog へ空 Enter を撃って既定選択/空回答を勝手に確定する）。配列を
    # 直接 source して単一 SSOT 化することで構造的に防ぐ。confirm_receipt==0 の追い Enter ループと
    # confirm_receipt>0 の read-back 救済 Enter の両方で共有する（両経路に同一の modality ガードを効かせる）。
    #   - source 元は実スクリプトディレクトリ（$SCRIPT_DIR）固定: state 呼び出しは mock 差し替え可能な
    #     $_state_script_dir 経由だが、パターン配列は real SSOT を使う（テストの state mock は
    #     INPUT_WAITING_PATTERNS を定義しないため $_state_script_dir から source すると空になる）。
    #   - subshell で source する: session-state.sh は usage()/resolve_target() を定義し session-comm.sh の
    #     同名関数を clobber しうる（現状は実装一致だが drift で挙動が変わる latent footgun）。subshell に
    #     隔離して配列だけを stdout で取り出すことで、関数/変数の漏洩を構造的に排除する。
    #     BASH_SOURCE ガードで dispatch はしない＝副作用は subshell 内の定義のみ。
    #   - PROMPT_PATTERN（❯ の素の入力欄）は INPUT_WAITING_PATTERNS の要素ではない＝自動的に除外され、
    #     『未 submit の滞留＝追い Enter で submit すべき正当ケース』は抑止されない。
    #   - source 失敗/空配列時は既知良好なリテラルへ fail-closed（modality ガードを silently 消さない）。
    local _se_dialog_re=''
    _se_dialog_re=$(
        source "${SCRIPT_DIR}/session-state.sh" 2>/dev/null || exit 0
        [[ -n "${INPUT_WAITING_PATTERNS+x}" ]] && [[ "${#INPUT_WAITING_PATTERNS[@]}" -gt 0 ]] || exit 0
        IFS='|'; printf '%s' "${INPUT_WAITING_PATTERNS[*]}"
    ) || _se_dialog_re=''
    if [[ -z "$_se_dialog_re" ]]; then
        # fail-closed: SSOT source に失敗しても modality ガードを無効化しない（既知良好な複製を使う）。
        _se_dialog_re='Enter to select|↑/↓ to navigate|承認しますか|確認しますか|Do you want to|\[y/N\]|\[Y/n\]|Type something|Waiting for user input'
    fi

    # 強 processing マーカー（ccs-mxv → ccs-pwr で TUI ドリフト追随）: detect_state の既定 fallthrough は
    # processing（パターン不在の残余クラス）のため、state==processing は「turn 実行中」の積極証拠に
    # ならない（boot splash も processing と読める）。受理に使えるのは **turn 固有**のマーカーのみ:
    #   - TURN_SPINNER_PATTERN（現行 TUI のスピナー行・行頭 glyph + gerund… + 経過タイマー。
    #     SSOT=session-state.sh。現行 TUI は 'esc to interrupt' を表示しない——2026-07-15 の走行中
    #     pane 実測で不在を verified＝旧マーカー単独では (A) が構造的に死んでいた・ccs-pwr）
    #   - esc to interrupt（旧 TUI の中断 UI・後方互換で維持）
    #   - compaction フェーズ名（COMPACTION_INDICATORS・SSOT=session-state.sh 経由）
    # THINKING_PROGRESS_PATTERN は**使わない**——英語進行形+省略記号の汎用形は boot スピナー語彙
    # （Loading…/Starting…/Initializing…/Connecting…/Baking… 等）にも一致し、boot 中に 2 連続で
    # 偽成立して RESIDUAL 分岐へ到達する前に偽受理する（live e2e で実測再現・ccs-mxv）。
    # TURN_SPINNER_PATTERN は行頭 glyph + '(' 経過タイマーまで要求する厳格形状のため boot 語彙
    # とは一致しない（live boot 標本 100 frames〔~20s・実 MCP 設定込み・2026-07-15〕で一致ゼロ・
    # glyph+gerund+… 形も括弧タイマー行も出現ゼロを verified＝「boot はタイマー括弧を出さない」は
    # 主張でなく実測）。
    # scribe sc-8g5 が busy-regex の再利用を拒否した判断と同根。
    # SSOT を subshell source する流儀は上の _se_dialog_re と同一・失敗時は既知良好リテラルへ fail-closed。
    local _rb_strong_re=''
    _rb_strong_re=$(
        source "${SCRIPT_DIR}/session-state.sh" 2>/dev/null || exit 0
        _p="esc to interrupt"
        if [[ -n "${TURN_SPINNER_PATTERN:-}" ]]; then
            _p="${_p}|${TURN_SPINNER_PATTERN}"
        fi
        if [[ -n "${COMPACTION_INDICATORS+x}" ]] && [[ "${#COMPACTION_INDICATORS[@]}" -gt 0 ]]; then
            IFS='|'
            _p="${_p}|${COMPACTION_INDICATORS[*]}"
        fi
        printf '%s' "$_p"
    ) || _rb_strong_re=''
    if [[ -z "$_rb_strong_re" ]]; then
        _rb_strong_re='esc to interrupt|^[^[:alnum:][:space:]] [\p{Lu}][\p{Ll}]+(…|\.{3}) \(([0-9]+h )?([0-9]+m )?[0-9]+s|Compacting|Snapshotting|Externalizing|Restoring|Summarizing'
    fi

    local target
    target=$(resolve_target "$window_name") || exit 1

    # flock で排他制御（un-7nw part2: 同一 pane への並列 inject-file を直列化して lost-update を防ぐ）。
    # cmd_inject（単一行）と同じ _resolve_lock_file（SSOT）でロックファイルを導出し、同一 target への
    # inject / inject-file が同じロックを掴む＝両サブコマンド間の paste 競合も相互に直列化される。
    #
    # クリティカルセクションの範囲（重要）: 状態待機（--wait）〜 paste 〜 submit(Enter/追い Enter) 〜
    # read-back までの**送達全体**をロック下に置く。paste-buffer は共有の入力欄へ書き込み、追い Enter /
    # read-back 救済 Enter も pane へ Enter を撃つため、これらが別 writer の paste と混線すると
    # 「片方の Enter が他方の内容を submit する / 部分入力が混ざる」lost-update を起こす。よって送達の
    # 全 mutation を 1 ロックで囲う。異なる window はロックファイルが別なので相互にブロックしない。
    #
    # 待機タイムアウト: クリティカルセクションの保持は最長 wait_timeout + confirm_receipt 秒になりうるため、
    # 後続 writer がその 1 周期分＋余裕を待てるよう acquire 上限を wait_timeout + confirm_receipt + 30 とする
    # （両値とも検証済みの非負整数）。超過時は fail-loud（沈黙の取りこぼしを作らない）。
    #
    # グループコマンド `{ ...; } 9>"$lock_file"`（cmd_inject と同型）: リダイレクト失敗を非致命に扱える
    # （exec 9> は非対話 shell で redirection error が即 fatal になりうるため使わない）。fd 9 はグループ終端
    # またはスクリプト exit で閉じられ、ロックは自動解放される（body 内の exit も同様に解放する）。
    # body は再インデントせず既存の字下げのまま囲う（差分を送達ロジックの変更に限定し、レビュー可能性を保つ）。
    local _lock_file _lock_wait
    _lock_file=$(_resolve_lock_file "$target") || exit 1
    # 既定は wait_timeout + confirm_receipt + 30（保持最長＋余裕）。SESSION_COMM_LOCK_WAIT で上書き可
    # （inject と共通調停・#5 修正）。両値とも検証済みの非負整数のため既定式は安全。
    _lock_wait=$(_lock_wait_for "$(( wait_timeout + confirm_receipt + 30 ))") || exit 1
    {
    flock -w "$_lock_wait" 9 || {
        echo "Error: failed to acquire send lock for '$window_name' (waited ${_lock_wait}s)" >&2
        exit 1
    }

    # 状態チェック: --wait 指定時は input-waiting までアクティブ待機
    if [[ "$wait_timeout" -gt 0 ]]; then
        if ! "${_state_script_dir}/session-state.sh" wait "$window_name" input-waiting --timeout "$wait_timeout"; then
            echo "Error: target '$window_name' did not reach input-waiting within ${wait_timeout}s" >&2
            exit 2
        fi
    else
        local state
        if ! state=$("${_state_script_dir}/session-state.sh" state "$window_name" 2>/dev/null); then
            echo "Warning: session-state.sh failed for '$window_name'" >&2
            state="unknown"
        fi

        if [[ "$state" != "input-waiting" ]]; then
            if $force; then
                echo "Warning: target '$window_name' is in state '$state' (not input-waiting), sending anyway" >&2
            else
                echo "Error: target '$window_name' is in state '$state' (expected: input-waiting)" >&2
                exit 2
            fi
        fi
    fi

    # read-back（--confirm-receipt 時）用の baseline と sentinel を paste 前に準備（ccs-ldt）。
    # baseline = paste 前の画面。sentinel = prompt 先頭非空行の先頭 24 字（pane 折返しに耐えるよう短め）。
    # 「sentinel が paste 後に出現し baseline には無い」を持続シグナルとして使い、processing が一瞬で
    # 終わる fast-complete でも受理を取りこぼさない（false-negative→cld-spawn 再送による二重投入の防止）。
    local _rb_baseline="" _rb_sentinel="" _rb_tail_marker="" _rb_multiline=false _rb_ph_base=0
    if [[ "$confirm_receipt" -gt 0 ]] && ! $no_enter; then
        _rb_baseline=$(tmux capture-pane -p -t "$target" 2>/dev/null || true)
        # 空/空白のみ prompt では grep が no-match で exit 1 → set -euo pipefail 下で代入行が abort し
        # paste 前に silent 失敗する。baseline 行と対称に `|| true` で吸収する（空 sentinel は下で無効化）。
        # 24 字への切詰は bash substring（文字単位・UTF-8 safe）で行う。cut -c は GNU では byte 単位の
        # ため、日本語等の multibyte 先頭行を文字境界で破断し「pane に絶対一致しない sentinel」を作る
        # ＝(B) が盲目化し vanished 誤診→再送重複の残存経路になっていた（live e2e で xxd 実証・ccs-pwr）。
        _rb_sentinel=$(grep -m1 -v '^[[:space:]]*$' "$file_path" 2>/dev/null | sed 's/^[[:space:]]*//' || true)
        _rb_sentinel="${_rb_sentinel:0:24}"
        if [[ "${#_rb_sentinel}" -lt 8 ]]; then _rb_sentinel=""; fi  # 短い先頭行は誤一致回避でスキップ
        # tail marker（ccs-mxv・scribe _derive_marker 同型）: 最終非空行の末尾 24 字＝cursor が座る箇所。
        # 入力欄 interior の RESIDUAL 検出は末尾側が可視になりやすい（長文は先頭が隠れる）ため head と併用する。
        _rb_tail_marker=$(awk 'NF{l=$0} END{if(l!="")print l}' "$file_path" 2>/dev/null || true)
        _rb_tail_marker="${_rb_tail_marker%"${_rb_tail_marker##*[![:space:]]}"}"
        if [[ "${#_rb_tail_marker}" -gt 24 ]]; then _rb_tail_marker="${_rb_tail_marker: -24}"; fi
        if [[ "${#_rb_tail_marker}" -lt 8 ]]; then _rb_tail_marker=""; fi
        # 複数行 prompt フラグ + baseline の paste placeholder 行数（ccs-pwr・(B') 用）。
        # TUI は複数行 paste を入力欄でも transcript でも '[Pasted text #N +M lines]' placeholder に
        # 折りたたむ＝submit 後も本文 sentinel は pane に原理的に現れない。(B') は「outside view の
        # placeholder 行数が baseline より増えた」ことを transcript への新規 echo＝submit の積極証拠
        # として使う。行数比較（存在比較でない）のは、baseline に過去 paste の placeholder が既に
        # 見えているケースで新規 echo を検出するため。
        _rb_multiline=false
        if [[ "$(grep -c '' "$file_path" 2>/dev/null || echo 0)" -ge 2 ]]; then _rb_multiline=true; fi
        # baseline 側は意図的に full-pane（interior 含む）で数える: outside 限定にすると
        # 「baseline の入力欄に居た残留 placeholder が transcript へ移動しただけ」を新規 echo と
        # 誤カウントし fail-open（偽受理）を招く。full-pane baseline は閾値を上げる方向にしか
        # 働かない＝fail-closed（取りこぼしは budget→再送＝二重投入側の既定トレードオフに合流）。
        # 対称化リファクタ禁止（cell-quality wf_e6b1331d の adversarial 検証で有害と確認済み）。
        _rb_ph_base=0
        if $_rb_multiline; then
            _rb_ph_base=$(printf '%s' "$_rb_baseline" | grep -cE -- "$_RB_PASTE_PLACEHOLDER_RE") || _rb_ph_base=0
        fi
    fi

    # --clear-first: 再送時に入力欄へ残る部分 paste を C-u でクリアし、再 paste の重複を防ぐ（ccs-ldt）。
    # 入力欄が空なら C-u は no-op。初回送達では通常不要（cld-spawn は再送時のみ付与）。
    if $clear_first; then
        tmux send-keys -t "$target" C-u 2>/dev/null || true
    fi

    # tmux load-buffer + paste-buffer で改行を含むテキストを安全に送達
    # 前提: tmux >= 2.0 (delete-buffer -b は tmux 2.0+ で追加)
    # named buffer でバッファ衝突を防止 (#1050)
    local _buf_name="session-comm-$$-$(date +%s%N)"

    # 信号ハンドラ: SIGTERM/SIGHUP/SIGINT で buffer を削除して終了する (#1420)
    # _buf_name 代入直後（load-buffer 呼び出し前）に設定する（AC2）
    # 各信号で個別に handler を設定し、信号別の exit code (128+signum) を保つ（AC3）
    # shellcheck disable=SC2064
    trap "tmux delete-buffer -b $_buf_name 2>/dev/null || true; exit 143" TERM
    # shellcheck disable=SC2064
    trap "tmux delete-buffer -b $_buf_name 2>/dev/null || true; exit 129" HUP
    # shellcheck disable=SC2064
    trap "tmux delete-buffer -b $_buf_name 2>/dev/null || true; exit 130" INT

    tmux load-buffer -b "$_buf_name" "$file_path" || {
        tmux delete-buffer -b "$_buf_name" 2>/dev/null || true
        trap - TERM HUP INT
        echo "Error: failed to load buffer from '$file_path'" >&2
        exit 1
    }

    # tmux >= 3.2 では -p フラグで bracketed paste mode を有効化
    local tmux_major tmux_minor
    tmux_major=$(tmux -V | sed 's/tmux \([0-9]*\)\..*/\1/')
    tmux_minor=$(tmux -V | sed 's/tmux [0-9]*\.\([0-9]*\).*/\1/')
    if [[ "$tmux_major" -gt 3 ]] || { [[ "$tmux_major" -eq 3 ]] && [[ "$tmux_minor" -ge 2 ]]; }; then
        tmux paste-buffer -b "$_buf_name" -p -t "$target" || {
            tmux delete-buffer -b "$_buf_name" 2>/dev/null || true
            trap - TERM HUP INT
            echo "Error: failed to paste buffer to '$window_name'" >&2
            exit 1
        }
    else
        tmux paste-buffer -b "$_buf_name" -t "$target" || {
            tmux delete-buffer -b "$_buf_name" 2>/dev/null || true
            trap - TERM HUP INT
            echo "Error: failed to paste buffer to '$window_name'" >&2
            exit 1
        }
    fi
    tmux delete-buffer -b "$_buf_name" 2>/dev/null || true
    trap - TERM HUP INT

    if ! $no_enter; then
        # paste-buffer 後に待機（Ink の非同期イベントループがペースト処理を
        # 完了する前に Enter が到着するタイミング問題を回避。#234）
        sleep 0.3
        session_msg send "$target" "" --enter-only

        # 追い Enter（un-iur）: 複数行 paste を Claude Code TUI が [Pasted text #N +M lines] に
        # 折りたたむ際、上で送った既定 Enter が paste 折りたたみ処理に吸収され未送信のまま入力欄に
        # 滞留することがある（25 行 paste で観測）。submit 済みなら state は input-waiting を抜ける
        # （processing/idle/error/exited）ので、抜けていなければ未 submit と判断して追い Enter を有界回数送る。
        #
        # 適用範囲は --confirm-receipt 非指定の経路のみ（confirm_receipt == 0）に限定する。理由:
        #   (c) --confirm-receipt 経路は下の read-back が input-waiting 滞留（未着）を exit 4 で検知し、
        #       cld-spawn が --clear-first でフル再 paste リトライして着弾させる既存機構を持つ。そこへ
        #       追い Enter を差し込むと read-back が見る state 系列がずれ（counter ベース mock を desync）、
        #       かつ二重 submit のリスクを生むため、read-back 経路の挙動は一切変えない（回帰なし）。
        # 二重 submit 防止: state が input-waiting でない（=submit 済み）と分かった時点で即停止する。
        #   submit 後すぐ processing へ遷移する cld-spawn 正常経路では初回 poll で抜けて追い Enter 0 回。
        #   空 Enter は Claude Code TUI の入力欄に対しては no-op のため、万一 submit 済みでも無害。
        #
        # modality ガード（重要）: 『空 Enter は no-op』は素の入力欄に対してのみ真。承認 UI / AskUserQuestion
        # （選択 UI も フリーテキスト 'Type something' も）/ y/N 等のダイアログでの Enter は no-op ではなく
        # 『既定選択の確定』『空入力の確定』という実アクションになる。detect_state はこれらも input-waiting と
        # 分類するため、paste した prompt が初回 Enter で正常 submit された直後にダイアログが出た（=正当な
        # post-submit input-waiting）ケースでは、state だけでは『未 submit』と誤認し追い Enter がダイアログを
        # 勝手に確定しうる。これを防ぐため、pane に detect_state の input-waiting 系パターン（❯ の素の入力欄を
        # 除く）が見えている間は追い Enter を抑止する（state==input-waiting でも送らない）。
        # 区別: 素の入力欄（❯）に滞留 = 未 submit なので追い Enter で submit。ダイアログ = 実アクションなので skip。
        # （注: 'bypass permissions' は --dangerously-skip-permissions の常時ステータスバーでありダイアログ
        #  識別子ではないため、抑止マーカーに含めない。下の _se_dialog_re 参照。）
        if [[ "$confirm_receipt" -eq 0 ]]; then
            # 承認 / AskUserQuestion / 選択 UI / y/N / フリーテキスト入力など『Enter が実アクションになる』
            # ダイアログのマーカー（pane 直読みで判定）。detect_state が input-waiting に分類するパターン
            # （session-state.sh:INPUT_WAITING_PATTERNS）のうち、素の入力欄を示す ❯（PROMPT_PATTERN・配列外）
            # だけは『未 submit の滞留＝追い Enter で submit すべき正当ケース』なので作用させず、それ以外
            # （承認系＋フリーテキスト 'Type something'／generic 'Waiting for user input'）は全て『Enter が
            # 実アクション』として抑止する。漏れがあると post-submit ダイアログへ空 Enter を撃って既定選択や
            # 空入力を確定させる fail-open になるため、下では INPUT_WAITING_PATTERNS を直接 source して
            # _se_dialog_re を導出し、手書き複製による drift を構造的に排除する。
            #
            # 重要: 'bypass permissions' は含めない。cld は `claude --dangerously-skip-permissions` で起動し、
            # この mode では `⏵⏵ bypass permissions on (shift+tab to cycle)` がステータスバーに常時表示される
            # （ダイアログ識別子ではない）。これを抑止マーカーにすると、修正が狙う『素の入力欄に滞留した
            # 未 submit』状態の実 pane でも毎ループ break し、追い Enter が 0 回＝実機で no-op になる。
            local _se_i=0 _se_state _se_pane
            # _se_dialog_re は cmd_inject_file 冒頭で INPUT_WAITING_PATTERNS（SSOT）から導出済み（共有）。
            while [[ "$_se_i" -lt "$_se_max" ]]; do
                _se_state=$("${_state_script_dir}/session-state.sh" state "$window_name" 2>/dev/null) || _se_state="unknown"
                # input-waiting 以外（processing/idle/error/exited/unknown）に抜けていれば submit 済み＝停止。
                # unknown は state 取得失敗時の安全側（追い Enter で二重 submit するより、no-op 前提で停止）。
                [[ "$_se_state" != "input-waiting" ]] && break
                # modality ガード: 承認/質問ダイアログが見えていれば、これは未 submit ではなく正当な
                # post-submit input-waiting。追い Enter は既定選択を確定する実アクションになるため送らず停止。
                _se_pane=$(tmux capture-pane -p -t "$target" 2>/dev/null || true)
                if printf '%s' "$_se_pane" | grep -qE -- "$_se_dialog_re"; then
                    break
                fi
                # 依然 input-waiting かつダイアログ無し＝paste 折りたたみで Enter が吸収され未 submit。
                # 素の入力欄への空 Enter は no-op のため安全に追い Enter で submit する。
                session_msg send "$target" "" --enter-only
                sleep 0.3
                ((_se_i++)) || true
            done
        fi
    fi

    # 送達 read-back（ccs-ldt → ccs-mxv で positive-proof 化）: --confirm-receipt 指定かつ Enter 送出時のみ。
    # paste 成功（tmux 層）だけでは「claude が prompt を受理した」ことを意味しない。さらに sentinel の
    # pane 出現も「到着」しか証明せず「submit（turn 開始）」を証明しない——boot 中の promo/TUI 再描画が
    # 初回 Enter を食うと、入力欄残留や一過性フレームの sentinel で偽『受理』を返し、spawn kickoff が
    # silent 消失する（orch-sm6p/sc-8g5 verified・orch-ttqe の根治対象）。受理は submit の積極証拠のみ:
    #   (A) 強 processing 2 連続: pane 直読で turn 固有マーカー（esc to interrupt / compaction フェーズ名・
    #       SSOT=session-state.sh）を 2 連続観測＝turn 実行中。state==processing は使わない（detect_state
    #       の既定 fallthrough が processing のため splash 滞留も processing と読める＝弱い証拠）。
    #       thinking 進行形 pattern も使わない（boot スピナー語彙と同形＝e2e で偽受理を実測・下の導出部参照）。
    #   (B) echo-outside-interior: sentinel が入力欄 interior の**外**（transcript）に出現 ∧ baseline に
    #       不在＝submit されて会話履歴に載った証拠。fast-complete / post-submit ダイアログの
    #       false-negative（→再送二重投入）を防ぐ。
    #   (B') folded-paste echo（ccs-pwr）: 複数行 paste は transcript echo も placeholder 表示のため
    #       (B) が構造的に盲目になる。outside view の placeholder 行数が baseline より増えたことを
    #       新規 echo＝submit の積極証拠として受理する（vanished 誤診より先に評価）。
    # 非受理側:
    #   - RESIDUAL（interior に head sentinel / tail marker / paste placeholder）＝「未 submit」の積極証明
    #     → 有界（_se_max）の救済 Enter で submit を flush（un-iur の折りたたみ吸収救済を包含）。
    #     Enter は RESIDUAL のときだけ撃つ（DJ-b）。RESIDUAL とダイアログは**原則**排他だが、ダイアログ
    #     文言が marker 断片を偶発包含すると誤分類しうるため、_se_dialog_re の modality ガードを belt で併用。
    #   - INCONCLUSIVE（帰属不能な interior / interior 抽出不能）＝判定保留（受理も Enter もしない）。
    #   - vanished（interior 空 ∧ sentinel が pane 全体に不在）2 連続＝paste が boot 再描画で飲まれた
    #     → 早期 fail（budget を待たず exit 4）→ 呼出側（cld-spawn）が --clear-first で再送。
    #   - error/exited 2 連続＝未着確定（単発の transient 誤判定は無視・ccs-e0i item3 不変）。
    #   - budget 失効＝未着（exit 4）。
    # 既知の限界: 折りたたみ paste は (B') が塞いだ（ccs-pwr）。残る余地は「baseline に placeholder が
    # 可視 ∧ submit と同時に旧 placeholder が scroll out して行数が増えない」極端な競合のみで、その場合も
    # budget 失効→再送＝二重投入側に倒れる（安全側＝silent 消失より二重投入を選ぶ・旧実装から不変の方針）。
    if [[ "$confirm_receipt" -gt 0 ]] && ! $no_enter; then
        local _rb_deadline _rb_state="" _rb_pane _rb_ok=false _rb_strong_streak=0 _rb_err_streak=0 _rb_vanish_streak=0 _rb_resub=0 _rb_interior="" _rb_scan="" _rb_cls _rb_xrc _rb_strong_new _rb_sline _rb_ph_out=0 _rb_saw_live_turn=0 _rb_queued=false _rb_queued_new=0 _rb_qline=""
        # queued 受理述語（ccs-3bj）: busy 宛先で paste が CC message queue に積まれたときの pane マーカー。
        # ★★既定 OFF＝opt-in（GATE ROUND-1 mandate・admin+live e2e 実測・ccs-3bj notes 2026-07-20）★★
        #   本経路は SESSION_COMM_QUEUED_MARKER_RE を **非空 set** したときのみ有効。未 set / 空 set は共に
        #   queued 検知 OFF＝旧挙動（証拠不在→vanished→exit4→再送＝安全側）へ戻る。
        #   なぜ既定 OFF か（fail-open 除去・機能損失ゼロ）:
        #     - live e2e 実測で現行 TUI の queued 実表示は **interior=『Press up to edit queued messages』**（本文
        #       echo は入力欄の**上**＝outside）。本経路の成立条件（cls0=interior 空 ∧ marker が outside の新規
        #       echo）とは**位置が逆**で、かつ従前の仮説既定 regex（message queued|will be sent 等）は語順も実表示に
        #       一致しない＝**既定経路の真陽性はゼロ**。regex 差替えだけでは有効化できない（interior 配置に対応する
        #       述語 rework は follow-up）。
        #     - 一方で汎用英語句（will be sent / to be sent / pending message 等）を default-on にすると、baseline
        #       捕捉**後**に running turn が stream した散文に一致し（baseline-newness ガードは baseline 時点の既存語
        #       しか除外できない）× sticky saw_live_turn × 真の消失（cls0・sentinel 不在）の合流で **偽 exit5＝再送
        #       禁止＝silent 消失**（不変量『silent 消失より二重投入』の反転＝fail-open）を可到達にする。
        #     - mid-busy paste は現行 TUI では (A)/(B) が受理し重複ゼロを実測（非 busy・spawn 回帰も green）。
        #   ゆえに既定 OFF は fail-open だけを除去し機能を落とさない。実マーカー live 確定後の opt-in 有効化は
        #   SESSION_COMM_QUEUED_MARKER_RE の非空 set（env 上書き）で行う。boot-race は saw_live_turn=0 で構造除外済み。
        local _rb_queued_re="${SESSION_COMM_QUEUED_MARKER_RE:-}"
        _rb_deadline=$(( $(date +%s) + confirm_receipt ))
        while [[ "$(date +%s)" -lt "$_rb_deadline" ]]; do
            _rb_pane=$(tmux capture-pane -p -t "$target" 2>/dev/null || true)
            # 入力欄 interior と outside view（interior・枠を除いた transcript/status 領域）を先に確定する。
            # 受理判定（A/B）は **outside view のみ**を見る——pane 全体を grep すると、prompt 本文が
            # 強マーカー語（Summarizing / esc to interrupt 等）や sentinel を含む場合に、未 submit の
            # 入力欄残留そのものへヒットして偽受理する（round-2 review wf_58b5c18e が決定論再現）。
            _rb_xrc=0
            _rb_interior=$(printf '%s\n' "$_rb_pane" | _rb_extract_input_box) || _rb_xrc=$?
            _rb_scan=""
            if [[ "$_rb_xrc" -eq 0 ]]; then
                _rb_scan=$(printf '%s\n' "$_rb_pane" | _rb_extract_input_box --outside) || _rb_scan=""
            fi

            # (A) 強 processing マーカー 2 連続＝turn 実行中の積極証拠（受理）。
            # interior を特定できないフレーム（boot splash・描画途中）は評価しない（積極証拠にしない。
            # 実 turn は入力欄を常に描画する〔実 TUI 検証済み〕ため正当受理は outside view で成立する）。
            # baseline 行差分要件（round-3 review wf_d526dfaa）: マッチ行が baseline（paste 前の pane）にも
            # 逐語で存在する場合は積極証拠にしない——compaction フェーズ名（Summarizing/Restoring）は
            # 一般英単語で、既存 transcript の静的な出力に居るだけで発火する（inject-existing 経路で
            # 決定論再現）。実 turn の spinner/status 行は経過秒数等を含み毎 poll 変化する＝baseline と
            # 逐語一致しないため正当受理は阻害されない。
            _rb_strong_new=0
            if [[ "$_rb_xrc" -eq 0 ]]; then
                while IFS= read -r _rb_sline; do
                    [[ -z "${_rb_sline//[[:space:]]/}" ]] && continue
                    if ! printf '%s' "$_rb_baseline" | grep -qF -- "$_rb_sline"; then
                        _rb_strong_new=1
                        break
                    fi
                done < <(printf '%s' "$_rb_scan" | grep -P -- "$_rb_strong_re" 2>/dev/null || true)
            fi
            if [[ "$_rb_strong_new" -eq 1 ]]; then
                # live running turn の積極証拠を蓄積する（queued 受理の前提・ccs-3bj）。boot splash は
                # timer-spinner を出さない（_rb_strong_re の verified 前提）ため、このフラグが立つのは
                # 実 turn 実行中のみ＝boot-race を構造的に除外する。baseline 行差分要件は _rb_strong_new が
                # 既に担保（round-3 wf_d526dfaa）ゆえ queued 経路もその要件を継承する。
                _rb_saw_live_turn=1
                _rb_strong_streak=$(( _rb_strong_streak + 1 ))
                _rb_vanish_streak=0
                if [[ "$_rb_strong_streak" -ge 2 ]]; then _rb_ok=true; break; fi
                sleep 0.3
                continue
            fi
            _rb_strong_streak=0

            _rb_state=$("${_state_script_dir}/session-state.sh" state "$window_name" 2>/dev/null) || _rb_state="unknown"
            case "$_rb_state" in
                error|exited)
                    _rb_err_streak=$(( _rb_err_streak + 1 ))
                    if [[ "$_rb_err_streak" -ge 2 ]]; then break; fi   # 2 連続で異常終了確定＝未着（fail）
                    ;;
                input-waiting)
                    _rb_err_streak=0
                    if [[ "$_rb_xrc" -eq 0 ]]; then
                        _rb_cls=0
                        _rb_classify_interior "$_rb_interior" "$_rb_sentinel" "$_rb_tail_marker" || _rb_cls=$?
                        case "$_rb_cls" in
                            3)  # RESIDUAL: 未 submit の積極証明 → 有界の救済 Enter（DJ-b・唯一の Enter 発火条件）。
                                # belt: dialog パターンが pane に可視なら RESIDUAL 判定でも撃たない——RESIDUAL と
                                # ダイアログは原則排他（ダイアログは interior を占め INCONCLUSIVE になる）だが、
                                # ダイアログ文言が prompt の 8-24 字断片を偶発包含すると marker 一致で RESIDUAL に
                                # 誤分類されうる（review wf_618b9ea7 が決定論再現・既定選択の確定＝fail-open）。
                                # 抑止時は budget 失効 → 呼出側再送に委ねる（旧実装の modality ガードを復帰）。
                                _rb_vanish_streak=0
                                if [[ "$_rb_resub" -lt "$_se_max" ]] \
                                   && ! printf '%s' "$_rb_pane" | grep -qE -- "$_se_dialog_re"; then
                                    session_msg send "$target" "" --enter-only
                                    ((_rb_resub++)) || true
                                fi
                                ;;
                            0|2)
                                # (B) echo-outside-interior: sentinel が outside view（transcript）に出現
                                #     ∧ baseline に不在 ＝ submit の積極証拠（fast-complete / post-submit dialog）
                                if [[ -n "$_rb_sentinel" ]] \
                                   && printf '%s' "$_rb_scan" | grep -qF -- "$_rb_sentinel" \
                                   && ! printf '%s' "$_rb_baseline" | grep -qF -- "$_rb_sentinel"; then
                                    _rb_ok=true; break
                                fi
                                # (B') folded-paste echo（ccs-pwr）: 複数行 paste は submit 後の transcript にも
                                # 本文でなく placeholder（[Pasted text #N +M lines]）が載る＝(B) の sentinel は
                                # 原理的に outside へ現れず、(B) 単独では折りたたみ paste の submit を観測できない
                                # （→ 下の vanished が「消失」と誤診し早期 exit 4 → 呼出側再送 → 実 submit 済み
                                # prompt の重複投入。orch-8rn8 偽陰性 2026-07-15 の実測機序）。outside view の
                                # placeholder 行数が baseline より**増えた**ことを新規 echo＝submit の積極証拠と
                                # して受理する。vanished 判定より必ず先に評価する（受理が誤診に先行する）。
                                if $_rb_multiline; then
                                    _rb_ph_out=$(printf '%s' "$_rb_scan" | grep -cE -- "$_RB_PASTE_PLACEHOLDER_RE") || _rb_ph_out=0
                                    if [[ "${_rb_ph_out:-0}" -gt "$_rb_ph_base" ]]; then
                                        _rb_ok=true; break
                                    fi
                                fi
                                # (queued) busy 宛先で paste が CC message queue に積まれた積極証拠（ccs-3bj）。
                                # vanished より必ず**先に**評価する（誤診 exit 4→呼出側再送→重複 queue を preempt）。
                                # 成立条件（下記すべて・boot-race を構造排除する保守形）:
                                #   (1) cls 0（interior 空＝DELIVERED）: paste が入力欄に残らず queue へ抜けた状態。
                                #       vanished と同じ interior 相のみを対象にし、cls 2（ダイアログ占有）を除外。
                                #   (2) _rb_saw_live_turn: live running turn を観測済み（timer-spinner。boot splash は
                                #       出さない＝boot-race を構造除外）。(A) が 2 連続を得られず flicker でこぼれた
                                #       turn を queued として救う。
                                #   (3) queued 固有 pane マーカーが **outside view(_rb_scan) に新規 echo** で可視
                                #       （_rb_queued_new。表示形態は live 未確認＝env 上書き可・空文字なら本分岐は
                                #       無効化＝旧挙動）。★baseline-newness 要件（round-3 wf_d526dfaa と同型・
                                #       ccs-3bj major fix）: マーカー行が baseline（paste 前 pane）に逐語存在する
                                #       なら静的 transcript（前 turn 出力・running turn ストリーム）の一般語＝
                                #       積極証拠にしない。既定 regex は 'queued'/'will be sent' 等の一般英語句で、
                                #       pane 全走査 grep だと静的 transcript に居るだけで一致し偽 exit 5（silent
                                #       消失＝本モジュール不変量違反）を招くため。strong マーカー (A) が同理由で
                                #       baseline 行差分を必須化しているのを queued も継承する（whole-pane grep は
                                #       使わず outside view のみを走査する）。
                                #   (4) sentinel が outside(transcript) に未 echo（clean submit なら (B) が先に受理済み
                                #       ＝ここへ来ない。二重の belt）。sentinel が短く無効化されている場合は本分岐は
                                #       不発→vanished へ落ちる（安全側）。
                                # 証拠不在（新規 marker 不可視 / live turn 未観測）なら不発→下の vanished へ落ちる
                                # ＝安全側（silent 消失より二重投入）。既存 vanished 述語は一切変更しない（加算分岐のみ）。
                                _rb_queued_new=0
                                if [[ -n "$_rb_queued_re" ]]; then
                                    while IFS= read -r _rb_qline; do
                                        [[ -z "${_rb_qline//[[:space:]]/}" ]] && continue
                                        if ! printf '%s' "$_rb_baseline" | grep -qF -- "$_rb_qline"; then
                                            _rb_queued_new=1; break
                                        fi
                                    done < <(printf '%s' "$_rb_scan" | grep -E -- "$_rb_queued_re" 2>/dev/null || true)
                                fi
                                if [[ "$_rb_cls" -eq 0 ]] \
                                   && [[ "$_rb_saw_live_turn" -eq 1 ]] \
                                   && [[ -n "$_rb_queued_re" ]] \
                                   && [[ -n "$_rb_sentinel" ]] \
                                   && [[ "$_rb_queued_new" -eq 1 ]] \
                                   && ! printf '%s' "$_rb_scan" | grep -qF -- "$_rb_sentinel"; then
                                    _rb_queued=true; break
                                fi
                                # vanished: 入力欄は空で prompt が pane から全消失＝boot 再描画で paste が
                                # 飲まれた。2 連続で早期 fail し呼出側の再送を早める（INCONCLUSIVE=cls2 は
                                # ダイアログ等が interior を占める場合で、budget 失効に委ねる＝再送が
                                # ダイアログへ paste する事故を急がせない）。
                                # 複数行 paste でも本判定は残す: 真の消失（placeholder が interior にも outside
                                # にも無い）は上の (B') が受理しないまま sentinel 不在でここへ来る＝boot-race の
                                # 早期再送は維持される。submit 済みなら (B')/(A) が先に受理して到達しない。
                                if [[ "$_rb_cls" -eq 0 ]] && [[ -n "$_rb_sentinel" ]] \
                                   && ! printf '%s' "$_rb_pane" | grep -qF -- "$_rb_sentinel"; then
                                    _rb_vanish_streak=$(( _rb_vanish_streak + 1 ))
                                    if [[ "$_rb_vanish_streak" -ge 2 ]]; then break; fi
                                else
                                    _rb_vanish_streak=0
                                fi
                                ;;
                        esac
                    else
                        _rb_vanish_streak=0   # interior 不明（描画途中等）＝判定保留
                    fi
                    ;;
                *)  # processing（弱＝fallthrough の可能性）/idle/unknown: 受理せず判定保留
                    _rb_err_streak=0; _rb_vanish_streak=0 ;;
            esac
            sleep 0.3
        done
        if $_rb_ok; then
            : # accepted（clean submit）＝正常 exit 0（関数末尾へ）
        elif $_rb_queued; then
            # queued: busy 宛先で CC message queue へ着弾（積極証拠あり）。exit 5 で caller に「再送禁止」を伝える
            # （deliver_prompt は exit 5 を terminal-success 扱い＝内部リトライ不発。ccs-3bj）。
            echo "Info: prompt queued to '$window_name' (busy target; CC message queue へ着弾・turn 終了後に配送) — caller must NOT resend (ccs-3bj)" >&2
            exit 5
        else
            echo "Error: prompt not confirmed received by '$window_name' (state=${_rb_state:-unknown} after ${confirm_receipt}s / submit の積極証拠なし・ccs-mxv)" >&2
            exit 4
        fi
    fi
    } 9>"$_lock_file"  # flock クリティカルセクション終端（un-7nw part2）
}

# =============================================================================
# サブコマンド: wait-ready
# =============================================================================
cmd_wait_ready() {
    local window_name=""
    local timeout=$DEFAULT_TIMEOUT

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --timeout requires a value" >&2
                    exit 1
                fi
                timeout="$2"
                if ! [[ "$timeout" =~ ^[1-9][0-9]*$ ]]; then
                    echo "Error: --timeout requires a positive integer" >&2
                    usage
                fi
                shift 2
                ;;
            -*)
                echo "Error: unknown option '$1'" >&2
                usage
                ;;
            *)
                if [[ -z "$window_name" ]]; then
                    window_name="$1"
                else
                    echo "Error: unexpected argument '$1'" >&2
                    usage
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$window_name" ]]; then
        echo "Error: window name required" >&2
        usage
    fi

    exec "${_state_script_dir}/session-state.sh" wait "$window_name" input-waiting --timeout "$timeout"
}

# =============================================================================
# session_msg API — send を backend に dispatch する。
# 汎用 plugin では tmux backend のみサポート（SESSION_MSG_BACKEND=tmux, default）。
# =============================================================================
session_msg() {
    local _subcmd="${1:-}"
    shift || true

    case "$_subcmd" in
        send)
            local _backend="${SESSION_MSG_BACKEND:-tmux}"
            case "$_backend" in
                tmux)
                    # shellcheck source=./session-comm-backend-tmux.sh
                    source "${SCRIPT_DIR}/session-comm-backend-tmux.sh"
                    _backend_tmux_send "$@"
                    ;;
                *)
                    echo "Error: session_msg: unsupported SESSION_MSG_BACKEND '${_backend}' (tmux のみサポート)" >&2
                    return 1
                    ;;
            esac
            ;;
        recv|ack|list)
            echo "Warning: session_msg ${_subcmd}: not implemented (backend=${SESSION_MSG_BACKEND:-tmux})" >&2
            return 0
            ;;
        *)
            echo "Error: session_msg: unknown subcommand '${_subcmd}'" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# メインディスパッチ（source ガード: source 時は実行しない）
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        capture)
            shift
            cmd_capture "$@"
            ;;
        inject|send)
            shift
            cmd_inject "$@"
            ;;
        inject-file|send-file)
            shift
            cmd_inject_file "$@"
            ;;
        wait-ready)
            shift
            cmd_wait_ready "$@"
            ;;
        session_msg)
            shift
            session_msg "$@"
            ;;
        -h|--help|"")
            usage
            ;;
        *)
            echo "Error: unknown subcommand '$1'" >&2
            usage
            ;;
    esac
fi
