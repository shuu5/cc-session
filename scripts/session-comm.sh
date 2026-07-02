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

    # 送達 read-back（ccs-ldt）: --confirm-receipt 指定かつ Enter 送出時のみ。
    # paste 成功（tmux 層）だけでは「claude が prompt を受理した」ことを意味しない（起動時 welcome は
    # bracketed paste を drop しうる）。受理を 2 つのシグナルで確認し、どちらも取れなければ非 0(=4) で返す:
    #   (1) 持続: 我々の prompt 内容（sentinel）が画面に出現し baseline には無い＝確実に受理。fast-complete
    #            でも会話履歴に残るため取りこぼさない（false-negative→cld-spawn 再送による二重投入を防ぐ）。
    #   (2) 遷移: state==processing を 2 連続観測＝claude 実行中。detect_state の既定 fallthrough も
    #            processing のため、welcome 遷移の単発 flicker による false-accept を「2 連続要求」で除去する。
    # error/exited は 2 連続観測で未着確定（単発の transient 誤判定は無視＝processing と対称）。
    # budget 失効も未着（exit 4）。呼び出し側（cld-spawn）は非 0 を受けて再送する。
    # 複数行 paste 折りたたみ吸収の救済（un-iur, read-back 経路）: cld-spawn の初期 inject は常に
    # --confirm-receipt 経由（confirm_receipt>0）なので、上の confirm_receipt==0 限定の追い Enter ループは
    # 効かない。決定論的な折りたたみ吸収（25 行 paste で初回 Enter が常に吸収・再 paste でも吸収）の場合、
    # read-back は毎回 input-waiting を見て exit 4 → cld-spawn が同一『paste＋単発 Enter』を再送するだけで
    # 各リトライも同じく吸収され、MAX_ATTEMPTS 後に送達失敗（exit 1）に陥りうる。これを塞ぐため、read-back
    # ループ内で input-waiting（=未 submit の滞留）を観測したら、上の追い Enter と同一の modality ガード下で
    # 有界（_se_max）の救済 Enter を撃って吸収された submit を flush する。
    #   - desync 回避: input-waiting は従来どおり両 streak をリセットする（processing/error の連続判定ロジックは
    #     一切変えない＝counter ベース mock を desync させない）。救済 Enter は受理判定に介入しない。
    #   - 二重 submit 回避: sentinel が見えれば(1)で、processing 2 連続なら(2)で先に break＝救済 Enter は
    #     『sentinel 不可視（折りたたみ）かつ input-waiting かつ dialog 不可視』のときのみ撃つ。dialog 可視時は
    #     modality ガードで撃たない（post-submit ダイアログの既定確定を防ぐ）。空 Enter は素入力欄では no-op。
    # 既知の限界: sentinel が pane で折返し/スクロール退避し、かつ processing を 2 連続で観測できないほど
    # 高速完了する prompt（spawn の実タスクでは非現実的）では false-negative→再送で二重投入の余地が残る。
    if [[ "$confirm_receipt" -gt 0 ]] && ! $no_enter; then
        local _rb_deadline _rb_state _rb_pane _rb_ok=false _rb_streak=0 _rb_err_streak=0 _rb_resub=0
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
            # (2) 遷移シグナル: processing/error をどちらも 2 連続観測で確定（単発 flicker を除去）。
            #     detect_state は screen-scraping ヒューリスティックで単発の誤判定がありうるため、
            #     processing（受理）も error/exited（未着）も「2 連続」を要求して対称化する（ccs-e0i item3）。
            #     これにより transient な error 誤判定での premature break→再送（二重投入）を防ぐ。
            #     非連続の振動（error→processing→error 等）はどちらの streak も 2 に達さず budget 失効へ。
            _rb_state=$("${_state_script_dir}/session-state.sh" state "$window_name" 2>/dev/null) || _rb_state="unknown"
            case "$_rb_state" in
                processing)
                    _rb_streak=$(( _rb_streak + 1 )); _rb_err_streak=0
                    if [[ "$_rb_streak" -ge 2 ]]; then _rb_ok=true; break; fi
                    ;;
                error|exited)
                    _rb_err_streak=$(( _rb_err_streak + 1 )); _rb_streak=0
                    if [[ "$_rb_err_streak" -ge 2 ]]; then break; fi   # 2 連続で異常終了確定＝未着（fail）
                    ;;
                input-waiting)
                    _rb_streak=0; _rb_err_streak=0  # 受理判定ロジックは不変（desync 防止）
                    # 折りたたみ吸収の救済: 未 submit の滞留に有界の救済 Enter を撃つ（dialog 可視時は撃たない）。
                    if [[ "$_rb_resub" -lt "$_se_max" ]]; then
                        _rb_pane=$(tmux capture-pane -p -t "$target" 2>/dev/null || true)
                        if ! printf '%s' "$_rb_pane" | grep -qE -- "$_se_dialog_re"; then
                            session_msg send "$target" "" --enter-only
                            ((_rb_resub++)) || true
                        fi
                    fi
                    ;;
                *)            _rb_streak=0; _rb_err_streak=0 ;;  # idle/unknown は両 streak リセット
            esac
            sleep 0.3
        done
        if ! $_rb_ok; then
            echo "Error: prompt not confirmed received by '$window_name' (state=${_rb_state:-unknown} after ${confirm_receipt}s)" >&2
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
