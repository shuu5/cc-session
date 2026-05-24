#!/usr/bin/env bash
# =============================================================================
# Tests: session-comm.sh inject-file submit fix
# Issue #202: inject-file でペーストしたプロンプトが自動 submit されない
# =============================================================================
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${PLUGIN_ROOT}/scripts/session-comm.sh"

PASS=0
FAIL=0
SKIP=0
ERRORS=()

SANDBOX=""

setup_sandbox() {
    SANDBOX=$(mktemp -d)
    mkdir -p "${SANDBOX}/bin"
}

teardown_sandbox() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    SANDBOX=""
}

run_test() {
    local name="$1"
    local func="$2"
    local result=0
    setup_sandbox
    $func || result=$?
    teardown_sandbox
    if [[ $result -eq 0 ]]; then
        echo "  PASS: ${name}"
        ((PASS++)) || true
    else
        echo "  FAIL: ${name}"
        ((FAIL++)) || true
        ERRORS+=("${name}")
    fi
}

run_test_skip() {
    local name="$1"
    local reason="$2"
    echo "  SKIP: ${name} (${reason})"
    ((SKIP++)) || true
}

# =============================================================================
# Structural verification: fix が実装されていること
# =============================================================================
echo ""
echo "--- Structural: inject-file submit fix ---"

# tmux >= 3.2 向けの -p フラグ実装が存在する（named buffer 化後は paste-buffer -b <name> -p の順）
test_bracketed_paste_flag_exists() {
    grep -qE 'paste-buffer.*-p' "$SCRIPT"
}
run_test "bracketed paste mode (-p フラグ) が実装されている" test_bracketed_paste_flag_exists

# tmux バージョンチェックが実装されている
test_tmux_version_check_exists() {
    grep -q 'tmux_major' "$SCRIPT" && grep -q 'tmux_minor' "$SCRIPT"
}
run_test "tmux バージョンチェックが実装されている" test_tmux_version_check_exists

# sleep による待機が Enter 前に実装されている
test_sleep_before_enter_exists() {
    # sleep 0.1 が send-keys Enter より前に存在することを確認
    local sleep_line enter_line
    sleep_line=$(grep -n 'sleep 0\.' "$SCRIPT" | tail -1 | cut -d: -f1)
    enter_line=$(grep -n 'send-keys.*Enter' "$SCRIPT" | tail -1 | cut -d: -f1)
    [[ -n "$sleep_line" && -n "$enter_line" && "$sleep_line" -lt "$enter_line" ]]
}
run_test "sleep による待機が Enter 送信前に実装されている" test_sleep_before_enter_exists

# --no-enter 時は sleep も Enter も実行されない（ガード条件内にあること）
test_no_enter_guards_sleep_and_enter() {
    # no_enter ガードブロック内に sleep と send-keys Enter が含まれる
    # ガードは "if ! \$no_enter" の形
    grep -A5 'if ! \$no_enter' "$SCRIPT" | grep -q 'sleep'
}
run_test "--no-enter ガードが sleep と Enter を包含している" test_no_enter_guards_sleep_and_enter

# =============================================================================
# Functional: mock tmux を使った動作検証
# =============================================================================
echo ""
echo "--- Functional: mock tmux ---"

# mock tmux スクリプトを生成するヘルパー
create_mock_tmux() {
    local mock_path="${SANDBOX}/bin/tmux"
    local call_log="${SANDBOX}/tmux_calls.log"
    cat > "$mock_path" << MOCK_EOF
#!/bin/bash
echo "\$*" >> "${call_log}"
case "\$1" in
    -V)
        echo "tmux 3.4"
        ;;
    load-buffer)
        exit 0
        ;;
    paste-buffer)
        exit 0
        ;;
    send-keys)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
MOCK_EOF
    chmod +x "$mock_path"
    echo "$call_log"
}

# mock session-state.sh を生成するヘルパー
create_mock_session_state() {
    local mock_scripts_dir="${SANDBOX}/mock_scripts"
    mkdir -p "$mock_scripts_dir"
    cat > "${mock_scripts_dir}/session-state.sh" << 'EOF'
#!/bin/bash
# Returns input-waiting for state subcommand
if [[ "${2:-}" == "state" ]] || [[ "$1" == "state" ]]; then
    echo "input-waiting"
fi
exit 0
EOF
    chmod +x "${mock_scripts_dir}/session-state.sh"
    echo "$mock_scripts_dir"
}

# inject-file 時に bracketed paste モードで paste-buffer が呼ばれる
test_inject_file_uses_bracketed_paste() {
    local call_log
    call_log=$(create_mock_tmux)
    local mock_scripts_dir
    mock_scripts_dir=$(create_mock_session_state)

    local tmpfile
    tmpfile=$(mktemp)
    echo "test prompt" > "$tmpfile"

    # tmux display-message で target を解決するモックも必要
    # resolve_target の呼び出しをモック（window_name に : がない場合の動作）
    # セッション名:ウィンドウ名 形式で渡す（: を含む場合の分岐をテスト）
    PATH="${SANDBOX}/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$mock_scripts_dir" \
    bash "$SCRIPT" inject-file "session:0" "$tmpfile" 2>/dev/null || true

    rm -f "$tmpfile"

    # paste-buffer で -p (bracketed paste) が呼ばれたことを確認（named buffer 化後は -b <name> -p の順）
    grep -qE 'paste-buffer.*-p' "$call_log"
}
run_test "inject-file が bracketed paste mode (-p) で paste-buffer を呼ぶ" test_inject_file_uses_bracketed_paste

# inject-file 時に Enter が送信される（--no-enter なし）
test_inject_file_sends_enter() {
    local call_log
    call_log=$(create_mock_tmux)
    local mock_scripts_dir
    mock_scripts_dir=$(create_mock_session_state)

    local tmpfile
    tmpfile=$(mktemp)
    echo "test prompt" > "$tmpfile"

    PATH="${SANDBOX}/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$mock_scripts_dir" \
    bash "$SCRIPT" inject-file "session:0" "$tmpfile" 2>/dev/null || true

    rm -f "$tmpfile"

    # send-keys Enter が呼ばれたことを確認
    grep -q 'send-keys.*Enter' "$call_log"
}
run_test "inject-file が Enter を送信する（--no-enter なし）" test_inject_file_sends_enter

# --no-enter 時は Enter が送信されない
test_inject_file_no_enter_flag() {
    local call_log
    call_log=$(create_mock_tmux)
    local mock_scripts_dir
    mock_scripts_dir=$(create_mock_session_state)

    local tmpfile
    tmpfile=$(mktemp)
    echo "test prompt" > "$tmpfile"

    PATH="${SANDBOX}/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$mock_scripts_dir" \
    bash "$SCRIPT" inject-file "session:0" "$tmpfile" --no-enter 2>/dev/null || true

    rm -f "$tmpfile"

    # send-keys Enter が呼ばれていないことを確認
    if grep -q 'send-keys.*Enter' "$call_log" 2>/dev/null; then
        return 1
    fi
    return 0
}
run_test "--no-enter 時に Enter が送信されない" test_inject_file_no_enter_flag

# --wait 時に session-state.sh wait が呼ばれる
test_inject_file_wait_calls_state_wait() {
    local call_log
    call_log=$(create_mock_tmux)
    local mock_scripts_dir="${SANDBOX}/mock_scripts"
    mkdir -p "$mock_scripts_dir"

    # session-state.sh の wait サブコマンドをモック（成功を返す）
    cat > "${mock_scripts_dir}/session-state.sh" << 'EOF'
#!/bin/bash
echo "$*" >> "${SESSION_STATE_LOG}"
if [[ "$1" == "wait" ]]; then
    exit 0
fi
if [[ "$1" == "state" ]]; then
    echo "input-waiting"
fi
exit 0
EOF
    chmod +x "${mock_scripts_dir}/session-state.sh"

    local state_log="${SANDBOX}/state_calls.log"
    local tmpfile
    tmpfile=$(mktemp)
    echo "test prompt" > "$tmpfile"

    PATH="${SANDBOX}/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$mock_scripts_dir" \
    SESSION_STATE_LOG="$state_log" \
    bash "$SCRIPT" inject-file "session:0" "$tmpfile" --wait 10 2>/dev/null || true

    rm -f "$tmpfile"

    # session-state.sh wait が呼ばれたことを確認
    grep -q 'wait.*input-waiting' "$state_log"
}
run_test "--wait 指定時に session-state.sh wait が呼ばれる" test_inject_file_wait_calls_state_wait

# --wait でタイムアウト時に exit 2 を返す
test_inject_file_wait_timeout_exits_2() {
    local call_log
    call_log=$(create_mock_tmux)
    local mock_scripts_dir="${SANDBOX}/mock_scripts"
    mkdir -p "$mock_scripts_dir"

    # session-state.sh wait が失敗を返すモック
    cat > "${mock_scripts_dir}/session-state.sh" << 'EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then
    exit 1
fi
echo "input-waiting"
exit 0
EOF
    chmod +x "${mock_scripts_dir}/session-state.sh"

    local tmpfile
    tmpfile=$(mktemp)
    echo "test prompt" > "$tmpfile"

    local exit_code=0
    PATH="${SANDBOX}/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$mock_scripts_dir" \
    bash "$SCRIPT" inject-file "session:0" "$tmpfile" --wait 5 2>/dev/null || exit_code=$?

    rm -f "$tmpfile"

    [[ "$exit_code" -eq 2 ]]
}
run_test "--wait タイムアウト時に exit 2 を返す" test_inject_file_wait_timeout_exits_2

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "==========================================="
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "==========================================="

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failed tests:"
    for err in "${ERRORS[@]}"; do
        echo "  - ${err}"
    done
fi

exit $FAIL
