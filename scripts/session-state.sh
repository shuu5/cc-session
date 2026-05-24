#!/bin/bash
# =============================================================================
# session-state.sh - Claude Code セッション状態検出ライブラリ
#
# Usage:
#   session-state.sh state <window-name>          # 特定ウィンドウの状態取得
#   session-state.sh list [--json]                 # 全ウィンドウの状態一覧
#   session-state.sh wait <window-name> <state> [--timeout N]  # 状態待機
#
# States: idle | input-waiting | processing | error | exited
# =============================================================================
set -euo pipefail

# =============================================================================
# パターン定義（Claude Code UI変更時はここを更新）
# =============================================================================
# プロンプト: 入力待ちを示す末尾パターン
PROMPT_PATTERN='❯[[:space:]]'
# approval UI / AskUserQuestion パターン（tail -5 全体スキャン対象）
INPUT_WAITING_PATTERNS=(
    'Enter to select'        # Claude Code 選択 UI
    '↑/↓ to navigate'       # 選択 UI ナビゲーションヒント
    '承認しますか'             # 日本語 AskUserQuestion
    '確認しますか'             # 日本語 AskUserQuestion
    'Do you want to'         # 英語 AskUserQuestion
    '\[y/N\]'                # y/N プロンプト
    '\[Y/n\]'                # Y/n プロンプト
    'Type something'         # フリーテキスト入力
    'Waiting for user input' # generic input-waiting
)
# エラー: capture-pane末尾に現れるエラーパターン
ERROR_PATTERNS=(
    'Error:'
    'APIError:'
    'API Error'
)
# セパレータ: ツール出力区切り線（参考用）
SEPARATOR_PATTERN='─{10,}'

# =============================================================================
# ユーティリティ
# =============================================================================
usage() {
    cat <<'EOF'
Usage:
  session-state.sh state <window-name>
  session-state.sh list [--json]
  session-state.sh wait <window-name> <target-state> [--timeout SECONDS]

States: idle | input-waiting | processing | error | exited
EOF
    exit 1
}

# ウィンドウのtmuxターゲットを解決（session:window形式も対応）
resolve_target() {
    local window_name="$1"
    # session:window 形式: フォーマット検証してからtmuxで存在確認
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
    # ウィンドウ名で検索（最初にマッチしたもの）
    local target
    target=$(tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name}' 2>/dev/null \
        | awk -v name="$window_name" '$2 == name { print $1; exit }')
    if [[ -z "$target" ]]; then
        echo "Error: window '$window_name' not found" >&2
        return 1
    fi
    echo "$target"
}

# =============================================================================
# 状態検出
# =============================================================================
detect_state() {
    local target="$1"

    # pane情報を取得
    local pane_info
    pane_info=$(tmux list-panes -t "$target" \
        -F '#{pane_current_command}	#{pane_dead}	#{pane_id}	#{pane_current_path}' \
        2>/dev/null | head -1) || {
        echo "Error: target '$target' not found" >&2
        return 1
    }

    local pane_cmd pane_dead pane_id pane_path
    IFS=$'\t' read -r pane_cmd pane_dead pane_id pane_path <<< "$pane_info"
    # TSVカラムずれ防御: タブ文字をスペースに置換
    pane_path="${pane_path//$'\t'/ }"

    # exited: pane_dead == 1
    if [[ "$pane_dead" == "1" ]]; then
        echo "exited"
        return
    fi

    # idle: claudeプロセスが稼働していない
    # pane_current_command が claude でない場合でも、systemd-run 経由（cld ラッパー）で
    # 起動されている可能性があるため、pane のプロセスグループに claude が含まれるかを確認する
    local has_claude=false
    if [[ "$pane_cmd" == "claude" ]]; then
        has_claude=true
    else
        local pane_pid
        pane_pid=$(tmux list-panes -t "$target" -F '#{pane_pid}' 2>/dev/null | head -1)
        if [[ -n "$pane_pid" ]]; then
            # pane_pid のプロセスグループ内に claude が存在するか確認
            local pgid
            pgid=$(ps -o pgid= -p "$pane_pid" 2>/dev/null | tr -d ' ')
            if [[ -n "$pgid" ]] && pgrep -g "$pgid" 2>/dev/null | xargs -r ps -o comm= -p 2>/dev/null | grep -q "^claude$"; then
                has_claude=true
            fi
        fi
    fi

    if ! $has_claude; then
        echo "idle"
        return
    fi

    # capture-paneで末尾20行を取得
    local captured
    captured=$(tmux capture-pane -p -t "$target" -S -20 2>/dev/null) || {
        echo "processing"
        return
    }

    # 末尾の空行を除去して最後の非空行を取得
    local last_lines
    last_lines=$(echo "$captured" | sed '/^[[:space:]]*$/d' | tail -5)

    # input-waiting: プロンプトパターンが last_lines のいずれかの行にある
    # Claude Code TUI は capture-pane で UTF-8 バイト列を返すため、
    # ❯ (U+276F) の直接マッチを tail -5 全体に対して適用する
    if echo "$last_lines" | grep -qP "$PROMPT_PATTERN"; then
        echo "input-waiting"
        return
    fi
    # approval UI / AskUserQuestion パターンを tail -5 全体に対してスキャン
    local _iw_pattern
    for _iw_pattern in "${INPUT_WAITING_PATTERNS[@]}"; do
        if echo "$last_lines" | grep -qP "$_iw_pattern"; then
            echo "input-waiting"
            return
        fi
    done
    # フォールバック: TUI のステータスバーパターンで状態を検出
    # "bypass permissions" → 権限承認プロンプト（genuinely input-waiting）
    if echo "$last_lines" | grep -q "bypass permissions"; then
        echo "input-waiting"
        return
    fi
    # "esc to interrupt" → LLM 実行中（processing の証拠）
    if echo "$last_lines" | grep -q "esc to interrupt"; then
        echo "processing"
        return
    fi

    # error: エラーパターンが末尾に存在（プロンプトが不在の場合のみ）
    local pattern
    for pattern in "${ERROR_PATTERNS[@]}"; do
        if echo "$last_lines" | grep -qF "$pattern"; then
            echo "error"
            return
        fi
    done

    # processing: それ以外
    echo "processing"
}

# =============================================================================
# サブコマンド: state
# =============================================================================
cmd_state() {
    local window_name="${1:-}"
    if [[ -z "$window_name" ]]; then
        echo "Error: window name required" >&2
        usage
    fi

    local target
    target=$(resolve_target "$window_name") || exit 1
    detect_state "$target"
}

# =============================================================================
# サブコマンド: list
# =============================================================================
cmd_list() {
    local json_mode=false
    if [[ "${1:-}" == "--json" ]]; then
        json_mode=true
    fi

    local entries=()
    local target state

    while IFS= read -r sess_name; do
        [[ -z "$sess_name" ]] && continue
        while IFS=$'\t' read -r win_idx win_name pane_cmd pane_dead pane_id pane_path; do
            [[ -z "$win_idx" ]] && continue
            # claudeウィンドウ、またはdead paneのみ対象
            if [[ "$pane_cmd" == "claude" ]] || [[ "$pane_dead" == "1" ]]; then
                # TSVカラムずれ防御: タブ文字をスペースに置換
                win_name="${win_name//$'\t'/ }"
                pane_path="${pane_path//$'\t'/ }"
                target="${sess_name}:${win_idx}"
                state=$(detect_state "$target" 2>/dev/null) || continue
                if $json_mode; then
                    entries+=("$(jq -nc \
                        --arg wn "$win_name" \
                        --arg st "$state" \
                        --arg pi "$pane_id" \
                        --arg pd "$pane_path" \
                        '{window_name:$wn,state:$st,pane_id:$pi,project_dir:$pd}')")
                else
                    printf '%s\t%s\t%s\t%s\n' "$win_name" "$state" "$pane_id" "$pane_path"
                fi
            fi
        done < <(tmux list-windows -t "$sess_name" \
            -F $'#{window_index}\t#{window_name}\t#{pane_current_command}\t#{pane_dead}\t#{pane_id}\t#{pane_current_path}' 2>/dev/null)
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

    if $json_mode; then
        if [[ ${#entries[@]} -eq 0 ]]; then
            echo "[]"
        else
            local joined
            joined=$(printf ',%s' "${entries[@]}")
            echo "[${joined:1}]"
        fi
    fi
}

# =============================================================================
# サブコマンド: wait
# =============================================================================
cmd_wait() {
    local window_name="${1:-}"
    local target_state="${2:-}"
    local timeout=30

    if [[ -z "$window_name" ]] || [[ -z "$target_state" ]]; then
        echo "Error: window name and target state required" >&2
        usage
    fi

    # --timeout パース
    shift 2
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout)
                timeout="${2:-30}"
                if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
                    echo "Error: --timeout requires a positive integer" >&2
                    usage
                fi
                shift 2
                ;;
            *)
                echo "Error: unknown option '$1'" >&2
                usage
                ;;
        esac
    done

    local target
    target=$(resolve_target "$window_name") || exit 1

    local elapsed=0 current_state
    while [[ $elapsed -lt $timeout ]]; do
        current_state=$(detect_state "$target" 2>/dev/null) || {
            sleep 1
            elapsed=$((elapsed + 1))
            continue
        }
        if [[ "$current_state" == "$target_state" ]]; then
            exit 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    echo "Timeout: state did not reach '$target_state' within ${timeout}s" >&2
    exit 1
}

# =============================================================================
# メインディスパッチ（source 時はスキップ）
# =============================================================================
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

case "${1:-}" in
    state)
        shift
        cmd_state "$@"
        ;;
    list)
        shift
        cmd_list "$@"
        ;;
    wait)
        shift
        cmd_wait "$@"
        ;;
    -h|--help|"")
        usage
        ;;
    *)
        echo "Error: unknown subcommand '$1'" >&2
        usage
        ;;
esac
