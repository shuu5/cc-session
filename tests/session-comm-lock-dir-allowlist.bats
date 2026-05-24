#!/usr/bin/env bats
# session-comm-lock-dir-allowlist.bats
# Issue #1239: tech-debt: SESSION_COMM_LOCK_DIR の mkdir -p による任意ディレクトリ作成リスク
# Spec: OWASP A01 — SESSION_COMM_LOCK_DIR を許可リスト（/tmp, XDG_RUNTIME_DIR）と照合し、
#       許可外パスはエラー終了する
# Coverage: --type=unit --coverage=security

# ===========================================================================
# setup / teardown
# ===========================================================================

setup() {
    PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$PLUGIN_ROOT/scripts/session-comm.sh"
    SANDBOX="$(mktemp -d)"
    export SANDBOX SCRIPT PLUGIN_ROOT
}

teardown() {
    [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

# mock tmux: has-session OK, list-windows OK, send-keys OK
_create_mock_tmux() {
    local mock="$SANDBOX/bin/tmux"
    mkdir -p "$SANDBOX/bin"
    cat > "$mock" << 'MOCK'
#!/bin/bash
case "$1" in
    -V) echo "tmux 3.4" ;;
    has-session) exit 0 ;;
    list-windows) echo "session:0 mock-window" ;;
    send-keys) exit 0 ;;
    load-buffer) exit 0 ;;
    paste-buffer) exit 0 ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$mock"
}

_create_mock_session_state_input_waiting() {
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
# AC1 (structural): allowlist 検証ブロックが session-comm.sh に含まれる
# RED: 実装前は allowlist チェックが存在しないため FAIL する
# ===========================================================================

@test "lock-dir-allowlist[structural][RED]: SESSION_COMM_LOCK_DIR allowlist 検証ブロックが存在する" {
    # 採用案: /tmp または XDG_RUNTIME_DIR プレフィックスのみ許可
    # 実装後は "allowlist" または "not allowed" または "XDG_RUNTIME_DIR" のいずれかの語が含まれる
    grep -E 'allowlist|not allowed|XDG_RUNTIME_DIR|allowed_prefix|permitted' "$SCRIPT" || {
        echo "FAIL: session-comm.sh に SESSION_COMM_LOCK_DIR allowlist 検証ロジックが含まれていない" >&2
        return 1
    }
}

@test "lock-dir-allowlist[structural][RED]: /tmp 以外のパスへのエラーメッセージが含まれる" {
    # 実装後は "not allowed" または "allowlist" などのメッセージが存在する
    grep -E 'not allowed|allowlist|outside.*allowed|permitted.*only' "$SCRIPT" || {
        echo "FAIL: session-comm.sh に許可リスト外パスのエラーメッセージが含まれていない" >&2
        return 1
    }
}

# ===========================================================================
# AC2-1 (functional): 許可リスト外パス → エラー終了（mkdir-p を実行しない）
# RED: 実装前は allowlist チェックがなく mkdir -p が実行されてしまう
# ===========================================================================

@test "lock-dir-allowlist[functional][RED]: /home/user 配下のパスはエラー終了する" {
    # 許可リスト外の典型的なパス: /home 配下（/tmp でも $XDG_RUNTIME_DIR でもない）
    # NOTE: SANDBOX は /tmp 内のため使用不可 → /home 配下の非実在パスを使用
    local target_dir="/home/test_user_$$/session_lock_test_$$"

    _create_mock_tmux
    _create_mock_session_state_input_waiting

    local exit_code=0
    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
    SESSION_COMM_LOCK_DIR="$target_dir" \
        bash "$SCRIPT" inject "session:0" "hello" 2>/dev/null || exit_code=$?

    # 実装後: allowlist 外パスで exit 1（エラー）
    # 実装前（RED）: exit 0 または mkdir -p が実行されてしまう → exit_code が 1 でない
    [[ "$exit_code" -eq 1 ]] || {
        echo "FAIL: allowlist 外パス '$target_dir' で exit 1 が返らなかった (exit_code=$exit_code)" >&2
        return 1
    }

    # かつ target_dir が作成されていないこと（mkdir -p を実行してはならない）
    [[ ! -d "$target_dir" ]] || {
        echo "FAIL: allowlist 外パス '$target_dir' が mkdir -p で作成されてしまった" >&2
        rm -rf "$target_dir" 2>/dev/null || true
        return 1
    }
}

@test "lock-dir-allowlist[functional][RED]: /var/tmp 等 /tmp 以外のシステムディレクトリもエラー終了する" {
    # /var/tmp は絶対パス・.. なしで既存バリデーションを通過するが、許可リスト外
    local exit_code=0
    local stderr_output
    stderr_output=$(
        _create_mock_tmux
        _create_mock_session_state_input_waiting
        PATH="$SANDBOX/bin:$PATH" \
        _TEST_MODE=1 \
        SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        SESSION_COMM_LOCK_DIR="/var/tmp/attacker_lock_$$" \
            bash "$SCRIPT" inject "session:0" "hello" 2>&1 >/dev/null
    ) || exit_code=$?

    # 実装後: /var/tmp は allowlist 外なので exit 1 + エラーメッセージ
    [[ "$exit_code" -eq 1 ]] || {
        echo "FAIL: /var/tmp 配下パスで exit 1 が返らなかった (exit_code=$exit_code)" >&2
        return 1
    }
}

@test "lock-dir-allowlist[functional][RED]: allowlist 外パスで stderr にエラーメッセージが出力される" {
    # NOTE: SANDBOX は /tmp 内のため使用不可 → /var/lock 配下の非実在パスを使用
    local target_dir="/var/lock/session_test_$$"

    _create_mock_tmux
    _create_mock_session_state_input_waiting

    local stderr_output
    local exit_code=0
    stderr_output=$(
        PATH="$SANDBOX/bin:$PATH" \
        _TEST_MODE=1 \
        SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        SESSION_COMM_LOCK_DIR="$target_dir" \
            bash "$SCRIPT" inject "session:0" "hello" 2>&1 >/dev/null
    ) || exit_code=$?

    # 実装後: stderr に "not allowed" または "allowlist" が含まれる
    echo "$stderr_output" | grep -qE 'not allowed|allowlist|outside|permitted' || {
        echo "FAIL: allowlist 外パスで適切なエラーメッセージが stderr に出力されなかった" >&2
        echo "  stderr: $stderr_output" >&2
        return 1
    }
}

# ===========================================================================
# AC2-2 (regression): /tmp は引き続き許可される（allowlist 内）
# GREEN 期待: /tmp は常に許可リストに含まれるため実装前後どちらも PASS
# ===========================================================================

@test "lock-dir-allowlist[regression]: /tmp は allowlist 内で正常動作する" {
    _create_mock_tmux
    _create_mock_session_state_input_waiting

    local exit_code=0
    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
    SESSION_COMM_LOCK_DIR="/tmp" \
        bash "$SCRIPT" inject "session:0" "hello" 2>/dev/null || exit_code=$?

    [[ "$exit_code" -eq 0 ]] || {
        echo "FAIL: /tmp（allowlist 内）で inject が失敗した (exit_code=$exit_code)" >&2
        return 1
    }
}

# ===========================================================================
# AC2-3 (regression): SESSION_COMM_LOCK_DIR 未設定時はデフォルト /tmp → 正常動作
# GREEN 期待: 未設定 → /tmp フォールバック → 正常
# ===========================================================================

@test "lock-dir-allowlist[regression]: SESSION_COMM_LOCK_DIR 未設定時は /tmp フォールバックで正常動作する" {
    _create_mock_tmux
    _create_mock_session_state_input_waiting

    local exit_code=0
    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        bash "$SCRIPT" inject "session:0" "hello" 2>/dev/null || exit_code=$?

    [[ "$exit_code" -eq 0 ]] || {
        echo "FAIL: SESSION_COMM_LOCK_DIR 未設定時に inject が失敗した (exit_code=$exit_code)" >&2
        return 1
    }
}

# ===========================================================================
# （XDG_RUNTIME_DIR allowlist ケースは環境依存のため cc-session では除外）
