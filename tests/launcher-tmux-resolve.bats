#!/usr/bin/env bats
# launcher-tmux-resolve.bats
# Issue #1218: tech-debt: tmux kill-window / set-option
# AC2 — set-option で resolved target (session:index) が使われること
#
# RED テスト: lib/tmux-resolve.sh が実装され、orchestrator の set-option callsite が
# _resolve_window_target 経由で session:index 形式を使うまで fail する。
#
# 設計:
#   - issue-lifecycle-orchestrator.sh L368 の
#     "tmux set-option -t "$window_name" remain-on-exit on"
#     は window_name（名前のみ）を -t に渡しており、複数 session 環境で ambiguous になる。
#   - 修正後: _resolve_window_target で session:index に解決してから set-option を呼ぶ
#   - lib/tmux-resolve.sh の _resolve_window_target が呼ばれ、
#     set-option は "main:3"（session:index）形式で呼ばれること
#
# tmux mock 戦略:
#   - list-windows -a が "main:3 wt-target" を返す（unique 解決）
#   - set-option に渡される -t 引数を CALL_LOG に記録
#   - CALL_LOG に "set-option -t main:3" が含まれることを assert

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
LIB_PATH="$SCRIPT_DIR/lib/tmux-resolve.sh"

# ---------------------------------------------------------------------------
# AC2-set-option-resolved-target:
#   _resolve_window_target が成功するケースで set-option が session:index 形式で呼ばれる
#   RED: lib/tmux-resolve.sh が存在しないため source 失敗で fail する
# ---------------------------------------------------------------------------
@test "AC2-set-option-resolved-target: _resolve_window_target 成功時 set-option は session:index 形式で呼ばれる (RED)" {
    # RED: lib/tmux-resolve.sh が存在しない（実装前）のため source 失敗で fail する
    # 実装後: set-option -t "main:3" が呼ばれ、window_name 単体では呼ばれないことを確認
    CALL_LOG_FILE="$(mktemp)"
    STDERR_FILE="$(mktemp)"

    run bash <<EOF
exec 2>"$STDERR_FILE"
CALL_LOG_FILE="$CALL_LOG_FILE"

tmux() {
    case "\$1" in
        list-windows)
            if [[ "\${*}" == *"-a"* ]]; then
                printf 'main:3 wt-target\n'
            else
                printf 'main:3 wt-target\n'
            fi
            return 0
            ;;
        set-option)
            echo "set-option \${@}" >> "\$CALL_LOG_FILE"
            return 0
            ;;
        kill-window)
            echo "kill-window \${@}" >> "\$CALL_LOG_FILE"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux

source "$LIB_PATH"

# _resolve_window_target で解決した target で set-option を呼ぶ
resolved=\$(_resolve_window_target "wt-target")
if [[ -z "\$resolved" ]]; then
    echo "FAIL: _resolve_window_target が空を返した"
    exit 1
fi
tmux set-option -t "\$resolved" remain-on-exit on
EOF

    call_log=$(cat "$CALL_LOG_FILE" 2>/dev/null || echo "")
    stderr_content=$(cat "$STDERR_FILE" 2>/dev/null || echo "")
    rm -f "$CALL_LOG_FILE" "$STDERR_FILE"

    # RED: lib/tmux-resolve.sh が存在しないため source 失敗で exit != 0
    # 実装後: exit 0 かつ set-option が "main:3" (session:index) で呼ばれる
    [[ "$status" -eq 0 ]]
    echo "$call_log" | grep -q "set-option -t main:3 remain-on-exit on"
    # window 名のみで呼ばれていないことも確認
    ! echo "$call_log" | grep -q "set-option -t wt-target"
}

# ---------------------------------------------------------------------------
# AC2-set-option-ambiguous-abort:
#   複数 session に同名 window が存在する場合 set-option は呼ばれない
#   RED: lib/tmux-resolve.sh が存在しないため source 失敗で fail する
# ---------------------------------------------------------------------------
@test "AC2-set-option-ambiguous-abort: 複数 session 同名 window の場合 set-option は呼ばれない (RED)" {
    # RED: lib/tmux-resolve.sh が存在しない（実装前）のため source 失敗で fail する
    # 実装後: _resolve_window_target が exit 1 を返し set-option は呼ばれない
    CALL_LOG_FILE="$(mktemp)"
    STDERR_FILE="$(mktemp)"

    run bash <<EOF
exec 2>"$STDERR_FILE"
CALL_LOG_FILE="$CALL_LOG_FILE"

tmux() {
    case "\$1" in
        list-windows)
            # 複数 session に同名 window
            printf 's1:0 wt-target\ns2:0 wt-target\n'
            return 0
            ;;
        set-option)
            echo "set-option \${@}" >> "\$CALL_LOG_FILE"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux

source "$LIB_PATH"

# _resolve_window_target が失敗（exit 1）する場合 set-option を呼ばない
resolved=\$(_resolve_window_target "wt-target" 2>/dev/null) || {
    echo "resolve failed (expected for ambiguous case)"
    exit 0
}
# ここに到達した場合は実装が不正（ambiguous なのに成功した）
tmux set-option -t "\$resolved" remain-on-exit on
EOF

    call_log=$(cat "$CALL_LOG_FILE" 2>/dev/null || echo "")
    stderr_content=$(cat "$STDERR_FILE" 2>/dev/null || echo "")
    rm -f "$CALL_LOG_FILE" "$STDERR_FILE"

    # 実装後: exit 0（resolve 失敗を graceful に処理）かつ set-option は呼ばれない
    [[ "$status" -eq 0 ]]
    ! echo "$call_log" | grep -q "set-option"
}
