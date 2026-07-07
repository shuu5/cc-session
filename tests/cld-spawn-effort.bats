#!/usr/bin/env bats
# cld-spawn-effort.bats - --effort オプションの unit tests
#
# --effort オプション伝播のテスト（cld-spawn-model.bats と同型・ccs-jeb）。
# claude CLI は --effort <low|medium|high|xhigh|max> を正式サポートし、cld は
# PASS_ARGS を verbatim 透過するため、cld-spawn → LAUNCHER の 1 段だけ検証すればよい。
#
# Scenarios covered:
#   - --effort オプションを指定: 生成された LAUNCHER に `--effort high` が含まれる
#   - --effort オプションなし: 生成された LAUNCHER に `--effort` フラグが含まれない
#
# Edge cases:
#   - --effort に空文字を渡した場合のエラー処理
#   - --effort と --model の組み合わせ
#   - --inject-existing との併用拒否（spawn 専用オプション）

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
CLD_SPAWN="$SCRIPT_DIR/cld-spawn"

# ---------------------------------------------------------------------------
# セットアップ（cld-spawn-model.bats と同一のスタブ構成）
# ---------------------------------------------------------------------------

setup() {
    SANDBOX="$(mktemp -d)"
    export LAUNCHER_PATH="$SANDBOX/launcher.sh"
    export FAKE_BIN="$SANDBOX/bin"
    mkdir -p "$FAKE_BIN"

    # --- tmux stub ---
    cat > "$FAKE_BIN/tmux" <<'TMUX_STUB'
#!/bin/bash
case "${1:-}" in
    list-windows)
        echo "${WINDOW_NAME_STUB:-cld-spawn-test}"
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
    cat > "$FAKE_BIN/flock" <<'FLOCK_STUB'
#!/bin/bash
exit 0
FLOCK_STUB
    chmod +x "$FAKE_BIN/flock"

    # --- スタブスクリプトディレクトリ ---
    export STUB_SCRIPTS="$SANDBOX/scripts"
    mkdir -p "$STUB_SCRIPTS"

    cat > "$STUB_SCRIPTS/session-name.sh" <<'SESSION_STUB'
generate_window_name() { echo "cld-spawn-test"; }
find_existing_window()  { echo ""; }
SESSION_STUB

    touch "$STUB_SCRIPTS/window-manifest.sh"

    mkdir -p "$STUB_SCRIPTS/lib"
    cp "$SCRIPT_DIR/lib/session-env.sh" "$STUB_SCRIPTS/lib/session-env.sh"

    cat > "$STUB_SCRIPTS/session-comm.sh" <<'COMM_STUB'
#!/bin/bash
exit 0
COMM_STUB
    chmod +x "$STUB_SCRIPTS/session-comm.sh"

    cat > "$FAKE_BIN/cld-stub" <<'CLD_STUB'
#!/bin/bash
exit 0
CLD_STUB
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

_run_spawn() {
    run bash "$STUB_SCRIPTS/cld-spawn" "$@"
    LAUNCHER_CONTENT=""
    if [[ -f "$LAUNCHER_PATH" ]]; then
        LAUNCHER_CONTENT="$(cat "$LAUNCHER_PATH")"
    fi
}

# ===========================================================================
# Requirement: cld-spawn --effort オプション
# ===========================================================================

@test "effort-option: --effort オプションがコマンドラインパーサーに存在する" {
    _run_spawn --effort high
    [[ "$output" != *"不明なオプション"* ]] \
        || fail "--effort option not recognized by cld-spawn"
    [[ "$output" != *"unknown option"* ]] \
        || fail "--effort option not recognized by cld-spawn"
}

@test "effort-option: --effort high 指定時に正常終了する" {
    _run_spawn --effort high
    [[ "$status" -eq 0 ]] \
        || fail "cld-spawn --effort high should exit 0, got $status. Output: $output"
}

@test "effort-option: --effort high 指定時に LAUNCHER に '--effort high' が含まれる" {
    _run_spawn --effort high
    [[ "$LAUNCHER_CONTENT" == *"--effort high"* ]] \
        || fail "LAUNCHER does not contain '--effort high'. Content: $LAUNCHER_CONTENT"
}

@test "effort-option: --effort xhigh 指定時に LAUNCHER に '--effort xhigh' が含まれる" {
    _run_spawn --effort xhigh
    [[ "$status" -eq 0 ]] \
        || fail "cld-spawn --effort xhigh should exit 0, got $status"
    [[ "$LAUNCHER_CONTENT" == *"--effort xhigh"* ]] \
        || fail "LAUNCHER does not contain '--effort xhigh'. Content: $LAUNCHER_CONTENT"
}

# ---------------------------------------------------------------------------
# Scenario: --effort オプションなし（既存動作の不変）
# ---------------------------------------------------------------------------

@test "effort-option: --effort 未指定時に正常終了する" {
    _run_spawn
    [[ "$status" -eq 0 ]] \
        || fail "cld-spawn without --effort should exit 0, got $status. Output: $output"
}

@test "effort-option: --effort 未指定時に LAUNCHER に '--effort' フラグが含まれない" {
    _run_spawn
    [[ "$LAUNCHER_CONTENT" != *"--effort"* ]] \
        || fail "LAUNCHER should not contain '--effort' when not specified. Content: $LAUNCHER_CONTENT"
}

# ===========================================================================
# Edge cases
# ===========================================================================

@test "effort-option: --effort に空文字を渡した場合はエラーになる" {
    _run_spawn --effort ""
    [[ "$status" -ne 0 ]] \
        || [[ "$output" == *"--effort"* ]] \
        || fail "Expected error when --effort given empty string, got status=$status"
}

@test "effort-option: --effort の値スロットに '-' 始まりトークンが来たら拒否する" {
    # require_value の値取りこぼし検出（--effort --model sonnet のような打ち間違い）
    _run_spawn --effort --model
    [[ "$status" -ne 0 ]] \
        || fail "Expected error when --effort value slot holds '-...' token, got status=$status"
}

@test "effort-option: --model と --effort を併用した場合に両方 LAUNCHER に反映される" {
    _run_spawn --model opus --effort high
    [[ "$status" -eq 0 ]] \
        || fail "--model and --effort combination failed: $output"
    [[ "$LAUNCHER_CONTENT" == *"--model opus"* ]] \
        || fail "LAUNCHER missing --model opus with --effort. Content: $LAUNCHER_CONTENT"
    [[ "$LAUNCHER_CONTENT" == *"--effort high"* ]] \
        || fail "LAUNCHER missing --effort high with --model. Content: $LAUNCHER_CONTENT"
}

@test "effort-option: --effort は variadic な --disallowed-tools より前に置かれる" {
    # --disallowed-tools は claude 側で可変長のため必ず末尾＝--effort が後ろに来ると吸収される
    _run_spawn --effort high --disallowed-tools "AskUserQuestion"
    [[ "$status" -eq 0 ]] \
        || fail "--effort and --disallowed-tools combination failed: $output"
    local cld_line
    cld_line="$(grep -- '--effort' <<<"$LAUNCHER_CONTENT" || true)"
    [[ -n "$cld_line" ]] \
        || fail "LAUNCHER missing --effort with --disallowed-tools. Content: $LAUNCHER_CONTENT"
    # 同一行内で --effort が --disallowed-tools より前
    [[ "${cld_line%%--disallowed-tools*}" == *"--effort high"* ]] \
        || fail "--effort must precede --disallowed-tools. Line: $cld_line"
}

@test "effort-option: --inject-existing と --effort の併用は拒否される" {
    _run_spawn --inject-existing some-window --effort high -- "dummy prompt"
    [[ "$status" -ne 0 ]] \
        || fail "Expected conflict error for --inject-existing + --effort, got status=$status"
    [[ "$output" == *"--effort"* ]] \
        || fail "Conflict error should name --effort. Output: $output"
}
