#!/usr/bin/env bats
# cld-spawn-bd-id.bats — cld-spawn --bd-id オプションの unit tests
#
# Scenarios:
#   - --bd-id un-cbi（--window-name 無し）→ window 名 wt-un-cbi で new-window される
#   - --bd-id #123 → window 名 wt-123（# 正規化・既存挙動と整合）
#   - --window-name が明示されていれば --bd-id より優先
#   - --bd-id 未指定 → 従来の意味論的命名（後方互換）
#   - --bd-id に空文字 → エラー
#
# tmux new-window の引数から window 名を観測するため、tmux stub が呼び出しを記録する。
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
CLD_SPAWN="$SCRIPT_DIR/cld-spawn"

setup() {
    SANDBOX="$(mktemp -d)"
    export LAUNCHER_PATH="$SANDBOX/launcher.sh"
    export FAKE_BIN="$SANDBOX/bin"
    export TMUX_LOG="$SANDBOX/tmux-calls.log"
    mkdir -p "$FAKE_BIN"

    # --- tmux stub: new-window の -n <name> を記録 ---
    cat > "$FAKE_BIN/tmux" <<TMUX_STUB
#!/bin/bash
echo "\$@" >> "${TMUX_LOG}"
case "\${1:-}" in
    new-window)
        # -n の次トークンが window 名
        shift
        while [[ \$# -gt 0 ]]; do
            if [[ "\$1" == "-n" ]]; then echo "\$2" >> "${TMUX_LOG}.winname"; fi
            shift
        done
        ;;
    list-windows)
        # 作成済み window として登録した名前を返す（cld-spawn の存在検証用）
        cat "${TMUX_LOG}.winname" 2>/dev/null || echo "fallback"
        ;;
    display-message)
        echo "main"
        ;;
esac
exit 0
TMUX_STUB
    chmod +x "$FAKE_BIN/tmux"

    # --- mktemp stub: LAUNCHER パスを固定 ---
    cat > "$FAKE_BIN/mktemp" <<MKTEMP_STUB
#!/bin/bash
if [[ "\$*" == *"cld-spawn-XXXXXX.sh"* ]]; then
    touch "${LAUNCHER_PATH}"
    echo "${LAUNCHER_PATH}"
else
    /usr/bin/mktemp "\$@"
fi
MKTEMP_STUB
    chmod +x "$FAKE_BIN/mktemp"

    # --- flock stub ---
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/flock"
    chmod +x "$FAKE_BIN/flock"

    export STUB_SCRIPTS="$SANDBOX/scripts"
    mkdir -p "$STUB_SCRIPTS"

    # session-name.sh: 実体をコピー（spawn_window_name / normalize_bd_id を本物で評価）し、
    # generate_window_name / find_existing_window のみテスト用にスタブ上書きする。
    cp "$SCRIPT_DIR/session-name.sh" "$STUB_SCRIPTS/session-name.sh"
    cat >> "$STUB_SCRIPTS/session-name.sh" <<'SESSION_STUB'
generate_window_name() { echo "semantic-fallback-name"; }
find_existing_window()  { echo ""; }
SESSION_STUB

    # window-manifest.sh: source されても安全な空スタブ
    touch "$STUB_SCRIPTS/window-manifest.sh"

    # lib/session-env.sh: namespace 定義（実体をコピー）
    mkdir -p "$STUB_SCRIPTS/lib"
    cp "$SCRIPT_DIR/lib/session-env.sh" "$STUB_SCRIPTS/lib/session-env.sh"

    # session-comm.sh: inject-file を無効化（即成功）
    printf '#!/bin/bash\nexit 0\n' > "$STUB_SCRIPTS/session-comm.sh"
    chmod +x "$STUB_SCRIPTS/session-comm.sh"

    # cld stub
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/cld-stub"
    chmod +x "$FAKE_BIN/cld-stub"
    export CLD_PATH="$FAKE_BIN/cld-stub"

    cp "$CLD_SPAWN" "$STUB_SCRIPTS/cld-spawn"
    chmod +x "$STUB_SCRIPTS/cld-spawn"

    export HOME="$SANDBOX/home"
    mkdir -p "$HOME/.local/state/claude-session"
    export TMUX="fake-tmux-socket,12345,0"
    export PATH="$FAKE_BIN:$PATH"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

# 観測された window 名（tmux new-window -n の値）
_winname() {
    cat "${TMUX_LOG}.winname" 2>/dev/null | head -n1
}

# ---------------------------------------------------------------------------
# --bd-id 指定
# ---------------------------------------------------------------------------

@test "bd-id: --bd-id un-cbi で window 名が wt-un-cbi になる" {
    run bash "$STUB_SCRIPTS/cld-spawn" --bd-id un-cbi
    [ "$status" -eq 0 ] || fail "exit $status: $output"
    [ "$(_winname)" = "wt-un-cbi" ] || fail "window name = '$(_winname)' (expected wt-un-cbi)"
}

@test "bd-id: --bd-id '#123' で window 名が wt-123 になる（# 正規化）" {
    run bash "$STUB_SCRIPTS/cld-spawn" --bd-id '#123'
    [ "$status" -eq 0 ] || fail "exit $status: $output"
    [ "$(_winname)" = "wt-123" ] || fail "window name = '$(_winname)' (expected wt-123)"
}

@test "bd-id: --window-name が --bd-id より優先される" {
    run bash "$STUB_SCRIPTS/cld-spawn" --bd-id un-cbi --window-name "explicit-name"
    [ "$status" -eq 0 ] || fail "exit $status: $output"
    [ "$(_winname)" = "explicit-name" ] || fail "window name = '$(_winname)' (expected explicit-name)"
}

@test "bd-id: --bd-id 未指定なら意味論的命名（後方互換）" {
    run bash "$STUB_SCRIPTS/cld-spawn"
    [ "$status" -eq 0 ] || fail "exit $status: $output"
    [ "$(_winname)" = "semantic-fallback-name" ] \
        || fail "window name = '$(_winname)' (expected semantic-fallback-name)"
}

@test "bd-id: --bd-id に空文字を渡すとエラー終了する" {
    run bash "$STUB_SCRIPTS/cld-spawn" --bd-id ""
    [ "$status" -ne 0 ] || fail "expected non-zero exit for empty --bd-id"
    [[ "$output" == *"--bd-id"* ]] || fail "expected error mentioning --bd-id: $output"
}

@test "bd-id: --bd-id と --cd を組み合わせても wt-<id> 命名になる" {
    run bash "$STUB_SCRIPTS/cld-spawn" --bd-id un-cbi --cd "$SANDBOX"
    [ "$status" -eq 0 ] || fail "exit $status: $output"
    [ "$(_winname)" = "wt-un-cbi" ] || fail "window name = '$(_winname)' (expected wt-un-cbi)"
}
