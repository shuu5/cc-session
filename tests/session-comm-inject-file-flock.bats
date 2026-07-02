#!/usr/bin/env bats
# session-comm-inject-file-flock.bats
# Requirement (un-7nw part2 / ccs-izx): cmd_inject_file の送達（paste + submit + read-back）を flock で
#   直列化し、同一 pane への複数 writer による inject 競合（lost-update）を防ぐ。
#   ロックファイル導出は cmd_inject と共通の _resolve_lock_file（SSOT）に委譲する。
# Coverage: --type=unit --coverage=concurrency,security,structural

setup() {
    PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$PLUGIN_ROOT/scripts/session-comm.sh"
    SANDBOX="$(mktemp -d)"
    export SANDBOX SCRIPT PLUGIN_ROOT
}

teardown() {
    [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    rm -f /tmp/session-comm-session-0.lock 2>/dev/null || true
}

# mock session-state.sh: 常に input-waiting（wait も即成功）
_mock_state_input_waiting() {
    mkdir -p "$SANDBOX/mock_scripts"
    cat > "$SANDBOX/mock_scripts/session-state.sh" << 'MOCK'
#!/bin/bash
if [[ "$1" == "state" ]]; then echo "input-waiting"; exit 0; fi
if [[ "$1" == "wait" ]]; then exit 0; fi
exit 0
MOCK
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"
}

# ===========================================================================
# 構造テスト: cmd_inject_file が flock で直列化し、SSOT ヘルパを使う
# ===========================================================================

@test "inject-file-flock[structural]: _resolve_lock_file ヘルパが定義されている" {
    grep -qE '^_resolve_lock_file\(\)' "$SCRIPT" || {
        echo "FAIL: session-comm.sh に _resolve_lock_file ヘルパ定義が無い" >&2
        return 1
    }
}

@test "inject-file-flock[structural]: cmd_inject と cmd_inject_file の双方が _resolve_lock_file を使う" {
    # ロックファイル導出が SSOT に一本化されていること（呼び出し 2 箇所以上）
    local count
    count=$(grep -c '_resolve_lock_file "\$target"' "$SCRIPT")
    [[ "$count" -ge 2 ]] || {
        echo "FAIL: _resolve_lock_file の呼び出しが 2 箇所未満（count=$count）＝inject/inject-file の一方が共通化されていない" >&2
        return 1
    }
}

@test "inject-file-flock[structural]: cmd_inject_file 内に flock 取得とグループ終端 9>lock_file が存在する" {
    grep -qF 'flock -w "$_lock_wait" 9' "$SCRIPT" || {
        echo "FAIL: cmd_inject_file の flock 取得行が無い" >&2
        return 1
    }
    grep -qF '} 9>"$_lock_file"' "$SCRIPT" || {
        echo "FAIL: cmd_inject_file の flock グループ終端 } 9>\"\$_lock_file\" が無い" >&2
        return 1
    }
}

# ===========================================================================
# 機能テスト（allowlist・security）: inject-file も SESSION_COMM_LOCK_DIR allowlist に従う
# ===========================================================================

@test "inject-file-flock[security]: allowlist 外 lock_dir では paste 前に exit 1 する" {
    _mock_state_input_waiting
    # mock tmux（resolve_target 用に list-windows / has-session を返す。paste には到達しない想定）
    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/tmux" << 'MOCK'
#!/bin/bash
case "$1" in
    -V) echo "tmux 3.4" ;;
    has-session) exit 0 ;;
    list-windows) echo "session:0 mock-window" ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$SANDBOX/bin/tmux"

    local pf="$SANDBOX/prompt.txt"; printf 'hello\n' > "$pf"
    local exit_code=0 stderr
    stderr=$(
        PATH="$SANDBOX/bin:$PATH" \
        _TEST_MODE=1 \
        SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        SESSION_COMM_LOCK_DIR="/home/attacker_lock_$$" \
            bash "$SCRIPT" inject-file "session:0" "$pf" 2>&1 >/dev/null
    ) || exit_code=$?

    [[ "$exit_code" -eq 1 ]] || {
        echo "FAIL: allowlist 外 lock_dir で exit 1 が返らなかった (exit=$exit_code)" >&2
        return 1
    }
    echo "$stderr" | grep -qE 'not allowed|allowlist' || {
        echo "FAIL: allowlist 外エラーメッセージが stderr に無い: $stderr" >&2
        return 1
    }
}

@test "inject-file-flock[regression]: /tmp（allowlist 内）では inject-file が正常終了する" {
    _mock_state_input_waiting
    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/tmux" << 'MOCK'
#!/bin/bash
case "$1" in
    -V) echo "tmux 3.4" ;;
    has-session) exit 0 ;;
    list-windows) echo "session:0 mock-window" ;;
    load-buffer) exit 0 ;;
    paste-buffer) exit 0 ;;
    delete-buffer) exit 0 ;;
    send-keys) exit 0 ;;
    capture-pane) exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$SANDBOX/bin/tmux"

    local pf="$SANDBOX/prompt.txt"; printf 'hello world\n' > "$pf"
    local exit_code=0
    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
    SESSION_COMM_LOCK_DIR="/tmp" \
    SESSION_COMM_SUBMIT_ENTER_MAX=0 \
        bash "$SCRIPT" inject-file "session:0" "$pf" 2>/dev/null || exit_code=$?

    [[ "$exit_code" -eq 0 ]] || {
        echo "FAIL: /tmp lock_dir で inject-file が失敗した (exit=$exit_code)" >&2
        return 1
    }
}

# ===========================================================================
# 機能テスト（concurrency）: 同一 window への並列 inject-file が直列化される
#   mock tmux が paste-buffer で START マーカーを書き 0.4s 保持 → send-keys で ENTER マーカーを書く。
#   flock が効いていれば START/ENTER は writer 毎に連続し、混線（START A → START B）は起きない。
# ===========================================================================

@test "inject-file-flock[concurrency]: 並列 inject-file は混線せず直列化される" {
    _mock_state_input_waiting
    local log="$SANDBOX/order.log"
    : > "$log"

    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/tmux" << MOCK
#!/bin/bash
LOG="$log"
case "\$1" in
    -V) echo "tmux 3.4" ;;
    has-session) exit 0 ;;
    list-windows) echo "session:0 mock-window" ;;
    load-buffer) exit 0 ;;
    paste-buffer)
        echo "START \${INJ_ID:-x}" >> "\$LOG"
        sleep 0.4
        echo "PASTED \${INJ_ID:-x}" >> "\$LOG"
        ;;
    delete-buffer) exit 0 ;;
    send-keys) echo "ENTER \${INJ_ID:-x}" >> "\$LOG" ;;
    capture-pane) exit 0 ;;
    *) exit 0 ;;
esac
exit 0
MOCK
    chmod +x "$SANDBOX/bin/tmux"

    local pf="$SANDBOX/prompt.txt"; printf 'concurrent prompt\n' > "$pf"

    # 2 writer を並列起動（同一 window=session:0）。SUBMIT_ENTER_MAX=0 で追い Enter を無効化しマーカーを単純化。
    INJ_ID=A PATH="$SANDBOX/bin:$PATH" _TEST_MODE=1 \
        SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        SESSION_COMM_LOCK_DIR="/tmp" SESSION_COMM_SUBMIT_ENTER_MAX=0 \
        bash "$SCRIPT" inject-file "session:0" "$pf" --wait 5 >/dev/null 2>&1 &
    local pidA=$!
    INJ_ID=B PATH="$SANDBOX/bin:$PATH" _TEST_MODE=1 \
        SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        SESSION_COMM_LOCK_DIR="/tmp" SESSION_COMM_SUBMIT_ENTER_MAX=0 \
        bash "$SCRIPT" inject-file "session:0" "$pf" --wait 5 >/dev/null 2>&1 &
    local pidB=$!
    wait "$pidA"; wait "$pidB"

    # START/ENTER のみ抽出。直列なら 4 行 = START x / ENTER x / START y / ENTER y。
    local seq
    seq=$(grep -E '^(START|ENTER) ' "$log")
    local n1 n2 n3 n4
    n1=$(echo "$seq" | sed -n '1p'); n2=$(echo "$seq" | sed -n '2p')
    n3=$(echo "$seq" | sed -n '3p'); n4=$(echo "$seq" | sed -n '4p')

    # 位置 1,3 は START / 位置 2,4 は ENTER（混線なら START が連続する）
    [[ "$n1" == START\ * && "$n2" == ENTER\ * && "$n3" == START\ * && "$n4" == ENTER\ * ]] || {
        echo "FAIL: START/ENTER が直列パターンでない（混線の疑い）:" >&2
        echo "$seq" >&2
        return 1
    }
    # 各 writer の START と ENTER の id が一致（1周期がロック下で完結している）
    [[ "${n1#START }" == "${n2#ENTER }" && "${n3#START }" == "${n4#ENTER }" ]] || {
        echo "FAIL: START と ENTER の writer id が不一致（クリティカルセクション途中で他 writer が割込み）:" >&2
        echo "$seq" >&2
        return 1
    }
}

# ===========================================================================
# 共有ロックの acquire 上限調停（gate round-1 CONFIRMED #5）
# ===========================================================================

@test "inject-file-flock[structural]: acquire 上限を _lock_wait_for(SESSION_COMM_LOCK_WAIT)で調停する" {
    grep -qE '^_lock_wait_for\(\)' "$SCRIPT" || {
        echo "FAIL: _lock_wait_for ヘルパ定義が無い" >&2; return 1; }
    # cmd_inject の既定が 30 から引き上げられ、共有ロックの長時間ホールドを待てる
    grep -q '_lock_wait_for 90' "$SCRIPT" || {
        echo "FAIL: cmd_inject の acquire 既定 90 (_lock_wait_for 90) が無い" >&2; return 1; }
    grep -q 'SESSION_COMM_LOCK_WAIT' "$SCRIPT" || {
        echo "FAIL: SESSION_COMM_LOCK_WAIT 参照が無い" >&2; return 1; }
}

@test "inject-file-flock[acquire]: SESSION_COMM_LOCK_WAIT が非整数なら fail-closed（exit 1）" {
    _mock_state_input_waiting
    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/tmux" << 'MOCK'
#!/bin/bash
case "$1" in
    -V) echo "tmux 3.4" ;;
    has-session) exit 0 ;;
    list-windows) echo "session:0 mock-window" ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$SANDBOX/bin/tmux"
    local pf="$SANDBOX/p.txt"; printf 'x\n' > "$pf"
    local ec=0
    PATH="$SANDBOX/bin:$PATH" _TEST_MODE=1 SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        SESSION_COMM_LOCK_DIR=/tmp SESSION_COMM_LOCK_WAIT=abc \
        bash "$SCRIPT" inject-file "session:0" "$pf" 2>"$SANDBOX/err.txt" || ec=$?
    [[ "$ec" -ne 0 ]] || { echo "FAIL: 非整数 SESSION_COMM_LOCK_WAIT で失敗しなかった" >&2; return 1; }
    grep -q "SESSION_COMM_LOCK_WAIT requires a positive integer" "$SANDBOX/err.txt" || {
        echo "FAIL: fail-closed メッセージが無い: $(cat "$SANDBOX/err.txt")" >&2; return 1; }
}

@test "inject-file-flock[acquire]: SESSION_COMM_LOCK_WAIT が acquire 上限を制御する（外部ホルダで検証）" {
    _mock_state_input_waiting
    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/tmux" << 'MOCK'
#!/bin/bash
case "$1" in
    -V) echo "tmux 3.4" ;;
    has-session) exit 0 ;;
    list-windows) echo "session:0 mock-window" ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$SANDBOX/bin/tmux"

    # 外部プロセスが共有ロック（/tmp/session-comm-session-0.lock）を 4s 保持
    local lock="/tmp/session-comm-session-0.lock"
    ( flock -x 9; sleep 4 ) 9>"$lock" &
    local holder=$!
    sleep 0.4  # ホルダがロックを掴むのを待つ

    local start end ec=0
    start=$(date +%s)
    PATH="$SANDBOX/bin:$PATH" _TEST_MODE=1 SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        SESSION_COMM_LOCK_DIR=/tmp SESSION_COMM_LOCK_WAIT=1 SESSION_COMM_SUBMIT_ENTER_MAX=0 \
        bash "$SCRIPT" inject "session:0" "hello" 2>"$SANDBOX/err.txt" || ec=$?
    end=$(date +%s)
    kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true

    [[ "$ec" -ne 0 ]] || { echo "FAIL: ロック保持中に inject が成功（acquire 上限が効いていない）" >&2; return 1; }
    grep -q "failed to acquire send lock" "$SANDBOX/err.txt" || {
        echo "FAIL: acquire 失敗メッセージが無い: $(cat "$SANDBOX/err.txt")" >&2; return 1; }
    # SESSION_COMM_LOCK_WAIT=1 なので ~1s で諦める（ホルダ 4s より十分早い＝上限が効いている）
    [[ $((end - start)) -le 3 ]] || {
        echo "FAIL: acquire が SESSION_COMM_LOCK_WAIT=1 を超えて待った: $((end-start))s" >&2; return 1; }
}
