#!/usr/bin/env bats
# issue-1460-inject-target-format.bats
# Issue #1460: session-comm.sh inject の target 引数が session:window 形式
#              （window名が文字列）を拒否する問題
# Spec: issue-1460
# Coverage: --type=functional

# RED フェーズ:
#   AC1/AC3 は resolve_target() の正規表現 `^[A-Za-z0-9_./-]+:[0-9]+$` が
#   文字列 window 名を拒否するため FAIL する。
#   AC2 は bare window 名の regression テスト（現状 PASS 見込みだが RED stub として記述）。

setup() {
    PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$PLUGIN_ROOT/scripts/session-comm.sh"
    SANDBOX="$(mktemp -d)"
    export SANDBOX SCRIPT PLUGIN_ROOT

    # SANDBOX/bin/ に mock tmux を配置
    mkdir -p "$SANDBOX/bin" "$SANDBOX/scripts"

    # mock session-state.sh: 常に input-waiting を返す
    cat > "$SANDBOX/scripts/session-state.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "state" ]]; then
    echo "input-waiting"
fi
exit 0
EOF
    chmod +x "$SANDBOX/scripts/session-state.sh"

    # mock session-comm-backend-tmux.sh: send-keys 呼び出しを記録
    # _backend_tmux_send が呼ばれたとき SANDBOX/tmux-sent ファイルに引数を記録する
    cat > "$SANDBOX/scripts/session-comm-backend-tmux.sh" <<EOF
#!/usr/bin/env bash
_backend_tmux_send() {
    local target="\${1:-}"
    local content="\${2:-}"
    echo "target=\$target content=\$content" > "${SANDBOX}/tmux-sent"
    return 0
}
if [[ "\${BASH_SOURCE[0]}" == "\${0}" ]]; then
    case "\${1:-}" in
        send) shift; _backend_tmux_send "\$@" ;;
        *) exit 1 ;;
    esac
fi
EOF
    chmod +x "$SANDBOX/scripts/session-comm-backend-tmux.sh"
}

teardown() {
    [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

# ===========================================================================
# AC1: session:window_name（文字列 window 名）形式で inject が成功する
#
# RED: resolve_target() の正規表現 `^[A-Za-z0-9_./-]+:[0-9]+$` が
#      文字列 window 名（例: "testsession:main"）を拒否するため FAIL する。
# ===========================================================================

@test "ac1: session:window_name 形式（文字列 window 名）で inject が成功する" {
    # mock tmux: has-session が s1 に対して成功、send-keys を記録
    cat > "$SANDBOX/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
    has-session)
        # -t s1 の存在確認
        exit 0
        ;;
    send-keys)
        echo "\$@" > "${SANDBOX}/tmux-sent"
        exit 0
        ;;
    list-windows)
        echo "s1:0 main"
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$SANDBOX/bin/tmux"

    # inject "s1:main" "hello" — resolve_target が "s1:main" を受け付ける必要がある
    run env \
        PATH="$SANDBOX/bin:$PATH" \
        SESSION_COMM_LOCK_DIR="/tmp" \
        _TEST_MODE=1 \
        SESSION_COMM_SCRIPT_DIR="$SANDBOX/scripts" \
        bash "$SCRIPT" inject "s1:main" "hello" --force

    # RED: 現状の正規表現では "s1:main" を invalid format として拒否し exit 1 になる
    if [[ "$status" -ne 0 ]]; then
        echo "FAIL: inject s1:main がエラー終了した (exit=$status)" >&2
        echo "  出力: $output" >&2
        echo "  原因: resolve_target() の正規表現が文字列 window 名を拒否している" >&2
        echo "  修正: ^[A-Za-z0-9_./-]+:[0-9]+\$ → session:任意文字列 を受け付けるように変更" >&2
        return 1
    fi
}

# ===========================================================================
# AC2: bare window 名で inject が成功する（regression テスト）
#
# 現状動作する bare window 名解決（tmux list-windows 経由）が壊れていないことを確認。
# ===========================================================================

@test "ac2: bare window 名で inject が成功する（regression）" {
    # mock tmux: list-windows -a -F で resolve_target が期待する形式を返す
    cat > "$SANDBOX/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
    list-windows)
        echo "s1:0 worker"
        ;;
    send-keys)
        echo "\$@" > "${SANDBOX}/tmux-sent"
        exit 0
        ;;
    has-session)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$SANDBOX/bin/tmux"

    # inject "worker" "hello" — bare window 名は従来通り解決される
    run env \
        PATH="$SANDBOX/bin:$PATH" \
        SESSION_COMM_LOCK_DIR="/tmp" \
        _TEST_MODE=1 \
        SESSION_COMM_SCRIPT_DIR="$SANDBOX/scripts" \
        bash "$SCRIPT" inject "worker" "hello" --force

    if [[ "$status" -ne 0 ]]; then
        echo "FAIL: bare window 名 'worker' での inject がエラー終了した (exit=$status)" >&2
        echo "  出力: $output" >&2
        echo "  regression: bare window 名解決が壊れている可能性" >&2
        return 1
    fi
}

# ===========================================================================
# AC3: 複数 session に同名 window が存在するとき、session:window 指定で曖昧解決できる
#
# RED: resolve_target() が "s1:shared" を正規表現で拒否するため、
#      明示的な session 指定による曖昧解決が機能しない。
# ===========================================================================

@test "ac3: 複数 session 同名 window 存在時、s1:shared_window で s1 に inject できる" {
    # s1 と s2 の両方に "shared" window が存在する状況
    cat > "$SANDBOX/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
    list-windows)
        # bare 解決時は両方の session が返る（曖昧）
        echo "s1:0 shared"
        echo "s2:0 shared"
        ;;
    has-session)
        # -t s1 または -t s2 の確認
        exit 0
        ;;
    send-keys)
        # inject 先の target を記録
        echo "target=\${3:-}" > "${SANDBOX}/tmux-sent"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$SANDBOX/bin/tmux"

    # inject "s1:shared" "hello" — s1 の shared window に明示的に送信
    run env \
        PATH="$SANDBOX/bin:$PATH" \
        SESSION_COMM_LOCK_DIR="/tmp" \
        _TEST_MODE=1 \
        SESSION_COMM_SCRIPT_DIR="$SANDBOX/scripts" \
        bash "$SCRIPT" inject "s1:shared" "hello" --force

    # RED: 現状の正規表現では "s1:shared" を invalid format として拒否し exit 1 になる
    if [[ "$status" -ne 0 ]]; then
        echo "FAIL: inject s1:shared がエラー終了した (exit=$status)" >&2
        echo "  出力: $output" >&2
        echo "  原因: resolve_target() が session:window_name 形式を正規表現で拒否している" >&2
        echo "  期待: s1:shared を有効な target として受け付け、s1 session の shared window へ inject" >&2
        return 1
    fi

    # s1 に向けて inject されたことを確認
    # （bare 解決では s1 か s2 か不定になるが、明示指定では s1 になるべき）
    if [[ -f "$SANDBOX/tmux-sent" ]]; then
        local recorded_target
        recorded_target=$(grep 'target=' "$SANDBOX/tmux-sent" | sed 's/target=//')
        if [[ "$recorded_target" != *"s1"* ]]; then
            echo "FAIL: s1 に inject されるべきが '$recorded_target' に inject された" >&2
            return 1
        fi
    fi
}
