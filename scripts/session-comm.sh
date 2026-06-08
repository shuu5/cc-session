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
                exit 1
            fi
        fi
    fi
    mkdir -p "$lock_dir" 2>/dev/null || {
        echo "Error: lock directory '$lock_dir' (SESSION_COMM_LOCK_DIR) is not creatable" >&2
        exit 1
    }
    local lock_file="${lock_dir}/session-comm-${target//[^a-zA-Z0-9]/-}.lock"
    {
        flock -w 30 9 || {
            echo "Error: failed to acquire send lock for '$window_name'" >&2
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

    local target
    target=$(resolve_target "$window_name") || exit 1

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
    local _rb_baseline="" _rb_sentinel=""
    if [[ "$confirm_receipt" -gt 0 ]] && ! $no_enter; then
        _rb_baseline=$(tmux capture-pane -p -t "$target" 2>/dev/null || true)
        # 空/空白のみ prompt では grep が no-match で exit 1 → set -euo pipefail 下で代入行が abort し
        # paste 前に silent 失敗する。baseline 行と対称に `|| true` で吸収する（空 sentinel は下で無効化）。
        _rb_sentinel=$(grep -m1 -v '^[[:space:]]*$' "$file_path" 2>/dev/null | sed 's/^[[:space:]]*//' | cut -c1-24 || true)
        if [[ "${#_rb_sentinel}" -lt 8 ]]; then _rb_sentinel=""; fi  # 短い先頭行は誤一致回避でスキップ
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
    fi

    # 送達 read-back（ccs-ldt）: --confirm-receipt 指定かつ Enter 送出時のみ。
    # paste 成功（tmux 層）だけでは「claude が prompt を受理した」ことを意味しない（起動時 welcome は
    # bracketed paste を drop しうる）。受理を 2 つのシグナルで確認し、どちらも取れなければ非 0(=4) で返す:
    #   (1) 持続: 我々の prompt 内容（sentinel）が画面に出現し baseline には無い＝確実に受理。fast-complete
    #            でも会話履歴に残るため取りこぼさない（false-negative→cld-spawn 再送による二重投入を防ぐ）。
    #   (2) 遷移: state==processing を 2 連続観測＝claude 実行中。detect_state の既定 fallthrough も
    #            processing のため、welcome 遷移の単発 flicker による false-accept を「2 連続要求」で除去する。
    # error/exited は未着扱い。budget 失効も未着（exit 4）。呼び出し側（cld-spawn）は非 0 を受けて再送する。
    # 既知の限界: sentinel が pane で折返し/スクロール退避し、かつ processing を 2 連続で観測できないほど
    # 高速完了する prompt（spawn の実タスクでは非現実的）では false-negative→再送で二重投入の余地が残る。
    if [[ "$confirm_receipt" -gt 0 ]] && ! $no_enter; then
        local _rb_deadline _rb_state _rb_pane _rb_ok=false _rb_streak=0
        _rb_deadline=$(( $(date +%s) + confirm_receipt ))
        while [[ "$(date +%s)" -lt "$_rb_deadline" ]]; do
            # (1) 持続シグナル: prompt 内容が画面に出現（baseline 差分）
            if [[ -n "$_rb_sentinel" ]]; then
                _rb_pane=$(tmux capture-pane -p -t "$target" 2>/dev/null || true)
                if printf '%s' "$_rb_pane" | grep -qF -- "$_rb_sentinel" \
                   && ! printf '%s' "$_rb_baseline" | grep -qF -- "$_rb_sentinel"; then
                    _rb_ok=true; break
                fi
            fi
            # (2) 遷移シグナル: processing の 2 連続観測（単発 flicker を除去）
            _rb_state=$("${_state_script_dir}/session-state.sh" state "$window_name" 2>/dev/null) || _rb_state="unknown"
            case "$_rb_state" in
                processing)
                    _rb_streak=$(( _rb_streak + 1 ))
                    if [[ "$_rb_streak" -ge 2 ]]; then _rb_ok=true; break; fi
                    ;;
                error|exited) break ;;                # 異常終了は未着扱い（fail）
                *)            _rb_streak=0 ;;          # input-waiting/idle/unknown は streak リセット
            esac
            sleep 0.3
        done
        if ! $_rb_ok; then
            echo "Error: prompt not confirmed received by '$window_name' (state=${_rb_state:-unknown} after ${confirm_receipt}s)" >&2
            exit 4
        fi
    fi
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
