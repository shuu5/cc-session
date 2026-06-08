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

    # mock tmux: paste/send-keys/その他は exit 0、呼び出しを記録。
    # capture-pane は呼び出し回数で baseline（1回目）と poll（2回目以降）を出し分ける
    # （read-back の持続シグナル＝prompt 内容出現の baseline 差分を検証可能にする）。
    export CAP_COUNTER="$SANDBOX/cap_counter"; echo 0 > "$CAP_COUNTER"
    cat > "$SANDBOX/bin/tmux" <<'TMUX_EOF'
#!/bin/bash
echo "$*" >> "$TMUX_CALL_LOG"
case "$1" in
    -V) echo "tmux 3.4" ;;
    has-session) exit 0 ;;
    display-message) echo "session:0" ;;
    capture-pane)
        c=$(cat "$CAP_COUNTER" 2>/dev/null || echo 0); c=$((c + 1)); echo "$c" > "$CAP_COUNTER"
        if [[ "$c" -eq 1 ]]; then printf '%s\n' "${MOCK_BASELINE:-}"; else printf '%s\n' "${MOCK_PANE:-}"; fi
        ;;
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

@test "read-back: 持続シグナル — prompt 内容が画面に出現（baseline 差分）すれば processing 無しでも受理" {
    export MOCK_STATE=input-waiting          # processing 経路は使わない
    export MOCK_BASELINE=""                   # baseline に sentinel 無し
    export MOCK_PANE="> hello world prompt"   # poll で prompt 内容が出現（sentinel=hello world）
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]
}

@test "read-back: baseline に既にある内容では誤受理しない（baseline 差分が必須）" {
    export MOCK_STATE=input-waiting
    export MOCK_BASELINE="old hello world line"   # baseline に sentinel 在り
    export MOCK_PANE="old hello world line"        # poll でも同じ＝差分なし
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 1
    [ "$status" -eq 4 ]                            # 差分なし＋processing なし → 未着
}

@test "read-back: 空白のみ prompt でも sentinel 導出で abort しない（paste まで到達・回帰）" {
    # 空白のみ prompt: sentinel 導出 grep が no-match → 旧来は set -e で paste 前に silent abort（regression）。
    printf '   \n\t\n' > "$PROMPT_FILE"
    export MOCK_STATE=processing            # paste 後に受理されれば exit 0
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]                      # abort せず read-back を通過して受理
    grep -qE 'paste-buffer' "$TMUX_CALL_LOG" # paste まで到達している（abort していない）
}

@test "read-back: 完全空 prompt でも abort しない（grep no-match の set -e 回帰）" {
    : > "$PROMPT_FILE"                       # 0 バイト
    export MOCK_STATE=processing
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]
    grep -qE 'paste-buffer' "$TMUX_CALL_LOG"
}

@test "read-back: processing 単発では受理しない（2 連続要求で flicker を除去）" {
    export STATE_COUNTER="$SANDBOX/state_counter"; echo 0 > "$STATE_COUNTER"
    # 1 回目だけ processing、以降 input-waiting を返す＝単発 flicker を模す
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then
    n=$(cat "$STATE_COUNTER" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STATE_COUNTER"
    if [[ "$n" -eq 1 ]]; then echo "processing"; else echo "input-waiting"; fi
fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]   # 単発 processing は受理されず未着
}
