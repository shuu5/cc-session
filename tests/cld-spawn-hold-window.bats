#!/usr/bin/env bats
# cld-spawn-hold-window.bats - new-session 再建分岐の hold（番兵）window 生成（orch-oktg / ccs-abk）
#
# 背景: tmux は window 0 枚の session を許さず、最後の window の kill-window は session ごと
# 破棄する（remain-on-exit は明示 kill に無力）。window 1 枚運用の respawn で session 消滅 →
# attach client 蹴り出し + 宛先断絶が起きるため、cld-spawn が session を新規作成するときに
# hold window（exec sleep infinity・-d・名前は素 'hold'）を同時生成する。
#
# Scenarios covered:
#   - 不在 session の create-if-absent 時に hold window が -d で併設される
#   - 既存 session への spawn では hold を生成しない（scope＝session 新規作成時のみ）
#   - 再利用 hit 時は hold を生成しない
#   - 既に hold が居れば生成しない（idempotent）
#   - hold 生成失敗でも spawn は成功し、警告を stderr へ出す（沈黙 fail-open にしない）
#
# スタブ方針は cld-spawn-session.bats と同型。差分: list-windows は $LIST_WINDOWS_STUB
# （改行区切り・未設定時は従来の単一名）を出力し、new-window は $HOLD_NEW_WINDOW_FAIL=1 かつ
# '-n hold' を含む呼び出しのとき exit 1 を返す（hold 生成失敗の注入）。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
CLD_SPAWN="$SCRIPT_DIR/cld-spawn"

setup() {
    SANDBOX="$(mktemp -d)"
    export LAUNCHER_PATH="$SANDBOX/launcher.sh"
    export FAKE_BIN="$SANDBOX/bin"
    export TMUX_LOG="$SANDBOX/tmux.log"
    : > "$TMUX_LOG"
    mkdir -p "$FAKE_BIN"

    # --- tmux stub: 呼び出しを記録し、コマンド別に応答 ---
    cat > "$FAKE_BIN/tmux" <<'TMUX_STUB'
#!/bin/bash
echo "tmux $*" >> "$TMUX_LOG"
case "${1:-}" in
    has-session)
        tgt=""; prev=""
        for a in "$@"; do
            [[ "$prev" == "-t" ]] && tgt="${a#=}"
            prev="$a"
        done
        for s in ${EXISTING_SESSIONS:-}; do
            [[ "$s" == "$tgt" ]] && exit 0
        done
        exit 1
        ;;
    list-windows)
        printf '%b\n' "${LIST_WINDOWS_STUB:-cld-spawn-test}"
        ;;
    new-window)
        if [[ "${HOLD_NEW_WINDOW_FAIL:-0}" == "1" && "$*" == *"-n hold"* ]]; then
            exit 1
        fi
        ;;
    display-message)
        echo "${CURRENT_SESSION_STUB:-cursess}"
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
find_existing_window()  { echo "FEW:$*" >> "$TMUX_LOG"; echo "${FEW_RESULT:-}"; }
SESSION_STUB

    touch "$STUB_SCRIPTS/window-manifest.sh"

    mkdir -p "$STUB_SCRIPTS/lib"
    cp "$SCRIPT_DIR/lib/session-env.sh" "$STUB_SCRIPTS/lib/session-env.sh"

    cat > "$STUB_SCRIPTS/session-comm.sh" <<'COMM_STUB'
#!/bin/bash
echo "COMM:$*" >> "$TMUX_LOG"
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

    unset EXISTING_SESSIONS FEW_RESULT LIST_WINDOWS_STUB HOLD_NEW_WINDOW_FAIL || true
    export EXISTING_SESSIONS=""
    export FEW_RESULT=""
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

_run_spawn() {
    run bash "$STUB_SCRIPTS/cld-spawn" "$@"
}

@test "hold: 不在 session の create-if-absent 時に hold window が -d で併設される" {
    export EXISTING_SESSIONS=""
    _run_spawn --session proj
    [ "$status" -eq 0 ]
    grep -q "tmux new-session -d -s proj -n cld-spawn-test" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
    grep -q "tmux new-window -d -t =proj: -n hold exec sleep infinity" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
}

@test "hold: 既存 session への spawn では hold を生成しない（scope＝session 新規作成時のみ）" {
    export EXISTING_SESSIONS="proj"
    _run_spawn --session proj
    [ "$status" -eq 0 ]
    grep -q "tmux new-window -t =proj: -n cld-spawn-test" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
    ! grep -q -- "-n hold" "$TMUX_LOG"
}

@test "hold: 再利用 hit 時は hold を生成しない" {
    export EXISTING_SESSIONS="proj"
    export FEW_RESULT="proj:5"
    _run_spawn --session proj
    [ "$status" -eq 0 ]
    [[ "$output" == *"reusing existing window: proj:5"* ]]
    ! grep -q -- "-n hold" "$TMUX_LOG"
}

@test "hold: 既に hold が居れば生成しない（idempotent）" {
    export EXISTING_SESSIONS=""
    export LIST_WINDOWS_STUB="cld-spawn-test\nhold"
    _run_spawn --session proj
    [ "$status" -eq 0 ]
    grep -q "tmux new-session -d -s proj -n cld-spawn-test" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
    ! grep -q -- "-n hold" "$TMUX_LOG"
}

@test "hold: hold 生成失敗でも spawn は成功し警告を出す（沈黙 fail-open にしない）" {
    export EXISTING_SESSIONS=""
    export HOLD_NEW_WINDOW_FAIL=1
    _run_spawn --session proj
    [ "$status" -eq 0 ]
    grep -q "tmux new-window -d -t =proj: -n hold exec sleep infinity" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
    [[ "$output" == *"Warning: hold window を生成できませんでした"* ]]
    [[ "$output" == *"spawned → tmux window 'cld-spawn-test' (session: proj)"* ]]
}
