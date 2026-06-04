#!/usr/bin/env bats
# session-comm-readback.bats — cmd_inject_file の送達 read-back（--confirm-receipt / --clear-first）unit tests
# ccs-ldt: tmux 層 paste 成功だけでは成功扱いにせず、claude が processing へ遷移＝受理を確認する。
# welcome 起動 race で paste が drop した場合（state が input-waiting/idle のまま）は非 0(=4) で返す。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
COMM="$SCRIPT_DIR/session-comm.sh"

setup() {
    SANDBOX="$(mktemp -d)"
    mkdir -p "$SANDBOX/bin" "$SANDBOX/mock_scripts"
    export TMUX_CALL_LOG="$SANDBOX/tmux_calls.log"
    : > "$TMUX_CALL_LOG"

    # mock tmux: paste/send-keys/その他は exit 0、呼び出しを記録
    cat > "$SANDBOX/bin/tmux" <<'TMUX_EOF'
#!/bin/bash
echo "$*" >> "$TMUX_CALL_LOG"
case "$1" in
    -V) echo "tmux 3.4" ;;
    has-session) exit 0 ;;
    display-message) echo "session:0" ;;
    *) exit 0 ;;
esac
TMUX_EOF
    chmod +x "$SANDBOX/bin/tmux"

    # mock session-state.sh: wait は常に成功、state は $MOCK_STATE を返す（既定 input-waiting）
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "${MOCK_STATE:-input-waiting}"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    export PATH="$SANDBOX/bin:$PATH"
    export _TEST_MODE=1
    export SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts"

    PROMPT_FILE="$SANDBOX/prompt.txt"
    printf 'hello world\n' > "$PROMPT_FILE"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

@test "read-back: state が processing に遷移したら受理＝exit 0" {
    export MOCK_STATE=processing
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]
}

@test "read-back: budget 内に processing 不達（input-waiting のまま）なら未着＝exit 4" {
    export MOCK_STATE=input-waiting
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 1
    [ "$status" -eq 4 ]
    [[ "$output" == *"not confirmed received"* ]]
}

@test "read-back: state=error は即 fail（exit 4）" {
    export MOCK_STATE=error
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 4 ]
}

@test "read-back: state=exited も fail（exit 4）" {
    export MOCK_STATE=exited
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 4 ]
}

@test "back-compat: --confirm-receipt 未指定なら read-back せず exit 0（state が processing でなくても）" {
    export MOCK_STATE=input-waiting
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 0 ]
}

@test "clear-first: paste 前に C-u（send-keys）を送る" {
    export MOCK_STATE=processing
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3 --clear-first
    [ "$status" -eq 0 ]
    grep -qE 'send-keys.*C-u' "$TMUX_CALL_LOG"
}

@test "clear-first 未指定なら C-u を送らない（既定）" {
    export MOCK_STATE=processing
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]
    ! grep -qE 'send-keys.*C-u' "$TMUX_CALL_LOG"
}

@test "read-back: --confirm-receipt は正の整数を要求する" {
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --confirm-receipt 0
    [ "$status" -ne 0 ]
    [[ "$output" == *"positive integer"* ]]
}

@test "read-back: --no-enter 時は read-back しない（Enter 未送出＝processing 遷移しない前提）" {
    export MOCK_STATE=input-waiting
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 1 --no-enter
    [ "$status" -eq 0 ]
}
