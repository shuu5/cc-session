#!/usr/bin/env bats
# cld-spawn-readback-retry.bats — cld-spawn の送達リトライ（ccs-ldt）unit tests
# inject-file が read-back で「未着」を非 0 で返したとき、cld-spawn が settle 後に再送し、
# 偽 "prompt injected" を出さずに確実に着弾させる（または全試行失敗で非 0 終了）ことを検証する。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
CLD_SPAWN="$SCRIPT_DIR/cld-spawn"

setup() {
    SANDBOX="$(mktemp -d)"
    export LAUNCHER_PATH="$SANDBOX/launcher.sh"
    export FAKE_BIN="$SANDBOX/bin"
    mkdir -p "$FAKE_BIN"

    export WINDOW_NAME_STUB="cld-spawn-test"
    # --- tmux stub（window 作成/検証をパス） ---
    cat > "$FAKE_BIN/tmux" <<'TMUX_STUB'
#!/bin/bash
case "${1:-}" in
    list-windows) echo "${WINDOW_NAME_STUB:-cld-spawn-test}" ;;
    display-message) echo "main" ;;
esac
exit 0
TMUX_STUB
    chmod +x "$FAKE_BIN/tmux"

    # --- mktemp stub（LAUNCHER は固定パス・prompt ファイルは実体） ---
    cat > "$FAKE_BIN/mktemp" <<MKTEMP_STUB
#!/bin/bash
if [[ "\$*" == *"cld-spawn-XXXXXX.sh"* ]]; then
    touch "${LAUNCHER_PATH}"; echo "${LAUNCHER_PATH}"
else
    /usr/bin/mktemp "\$@"
fi
MKTEMP_STUB
    chmod +x "$FAKE_BIN/mktemp"

    # --- flock stub ---
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/flock"; chmod +x "$FAKE_BIN/flock"

    export STUB_SCRIPTS="$SANDBOX/scripts"
    mkdir -p "$STUB_SCRIPTS/lib"
    printf 'generate_window_name() { echo "cld-spawn-test"; }\nfind_existing_window() { echo ""; }\n' \
        > "$STUB_SCRIPTS/session-name.sh"
    touch "$STUB_SCRIPTS/window-manifest.sh"
    cp "$SCRIPT_DIR/lib/session-env.sh" "$STUB_SCRIPTS/lib/session-env.sh"

    # --- session-comm.sh stub: inject-file を counter で fail/success ---
    export COMM_CALL_LOG="$SANDBOX/comm_calls.log"; : > "$COMM_CALL_LOG"
    export INJECT_COUNTER="$SANDBOX/inject_counter"; echo 0 > "$INJECT_COUNTER"
    cat > "$STUB_SCRIPTS/session-comm.sh" <<'COMM_STUB'
#!/bin/bash
if [[ "$1" == "inject-file" ]]; then
    echo "$*" >> "$COMM_CALL_LOG"
    n=$(cat "$INJECT_COUNTER" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$INJECT_COUNTER"
    if [[ "$n" -le "${FAIL_TIMES:-0}" ]]; then exit 4; fi   # 未着（welcome drop 相当）
    exit 0                                                  # 受理
fi
exit 0
COMM_STUB
    chmod +x "$STUB_SCRIPTS/session-comm.sh"

    printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/cld-stub"; chmod +x "$FAKE_BIN/cld-stub"
    export CLD_PATH="$FAKE_BIN/cld-stub"

    cp "$CLD_SPAWN" "$STUB_SCRIPTS/cld-spawn"; chmod +x "$STUB_SCRIPTS/cld-spawn"

    export HOME="$SANDBOX/home"; mkdir -p "$HOME/.local/state/claude-session"
    export TMUX="fake-tmux-socket,12345,0"
    export PATH="$FAKE_BIN:$PATH"

    # リトライを高速化（sleep を最小化できないが試行数は制御）
    export CLD_INJECT_ATTEMPTS=3
    export CLD_CONFIRM_BUDGET=1
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

_inject_calls() { wc -l < "$COMM_CALL_LOG" | tr -d ' '; }

@test "retry: 初回未着→2回目受理で成功（prompt injected・inject-file 2回）" {
    export FAIL_TIMES=1
    run bash "$STUB_SCRIPTS/cld-spawn" "test prompt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"prompt injected"* ]]
    [ "$(_inject_calls)" -eq 2 ]
    # 2 回目（再送）は --clear-first 付き、初回は無し
    [[ "$(sed -n '2p' "$COMM_CALL_LOG")" == *"--clear-first"* ]]
    [[ "$(sed -n '1p' "$COMM_CALL_LOG")" != *"--clear-first"* ]]
}

@test "retry: 全試行未着なら非 0 終了・偽 prompt injected を出さない（inject-file 3回）" {
    export FAIL_TIMES=99
    run bash "$STUB_SCRIPTS/cld-spawn" "test prompt"
    [ "$status" -ne 0 ]
    [[ "$output" != *"prompt injected"* ]]
    [[ "$output" == *"送達に失敗"* ]]
    [ "$(_inject_calls)" -eq 3 ]
}

@test "retry: 初回受理なら 1 回で成功・--clear-first を付けない" {
    export FAIL_TIMES=0
    run bash "$STUB_SCRIPTS/cld-spawn" "test prompt"
    [ "$status" -eq 0 ]
    [[ "$output" == *"prompt injected"* ]]
    [ "$(_inject_calls)" -eq 1 ]
    [[ "$(sed -n '1p' "$COMM_CALL_LOG")" != *"--clear-first"* ]]
}

@test "inject-file 呼び出しに --confirm-receipt と --wait が含まれる" {
    export FAIL_TIMES=0
    run bash "$STUB_SCRIPTS/cld-spawn" "test prompt"
    [ "$status" -eq 0 ]
    [[ "$(sed -n '1p' "$COMM_CALL_LOG")" == *"--confirm-receipt"* ]]
    [[ "$(sed -n '1p' "$COMM_CALL_LOG")" == *"--wait"* ]]
}
