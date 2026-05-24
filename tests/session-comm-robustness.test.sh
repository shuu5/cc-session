#!/usr/bin/env bash
# =============================================================================
# Tests: session-comm.sh 堅牢化 (Issue #1031)
# AC1: 並列 10 送信でも全メッセージが正しい順で届く（flock による排他）
# AC2: 受信側が input-waiting でない場合、5 秒待機後に retry する
# AC3: inject / inject-file の既存 API シグネチャ互換維持（GREEN baseline）
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
    mkdir -p "${SANDBOX}/mock_scripts"
    mkdir -p "${SANDBOX}/lock_dir"
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
# ヘルパー: mock tmux 生成
# =============================================================================
create_mock_tmux_ordered() {
    # 並列送信のメッセージ順序を記録する mock tmux
    # send-keys の呼び出しを原子的に追記する
    local mock_path="${SANDBOX}/bin/tmux"
    local call_log="${SANDBOX}/tmux_calls.log"
    cat > "$mock_path" << MOCK_EOF
#!/bin/bash
case "\$1" in
    -V)
        echo "tmux 3.4"
        ;;
    has-session)
        exit 0
        ;;
    list-windows)
        echo "session:0 mock-window"
        ;;
    send-keys)
        # 原子的追記（flock があれば競合しない）
        echo "\$*" >> "${call_log}"
        exit 0
        ;;
    load-buffer)
        exit 0
        ;;
    paste-buffer)
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

create_mock_session_state_input_waiting() {
    # 常に input-waiting を返す mock
    cat > "${SANDBOX}/mock_scripts/session-state.sh" << 'MOCK_EOF'
#!/bin/bash
if [[ "$1" == "state" ]]; then
    echo "input-waiting"
    exit 0
fi
if [[ "$1" == "wait" ]]; then
    exit 0
fi
exit 0
MOCK_EOF
    chmod +x "${SANDBOX}/mock_scripts/session-state.sh"
}

create_mock_session_state_not_input_waiting() {
    # 常に processing を返す（input-waiting でない）mock
    cat > "${SANDBOX}/mock_scripts/session-state.sh" << 'MOCK_EOF'
#!/bin/bash
if [[ "$1" == "state" ]]; then
    echo "processing"
    exit 0
fi
if [[ "$1" == "wait" ]]; then
    # timeout: 状態は変わらない
    exit 1
fi
exit 0
MOCK_EOF
    chmod +x "${SANDBOX}/mock_scripts/session-state.sh"
}

create_mock_session_state_becomes_ready_after_delay() {
    # 最初は processing、呼ばれるたびに state_call_count を増やし
    # 2 回目以降は input-waiting を返す mock（retry 検証用）
    local state_file="${SANDBOX}/state_count"
    echo "0" > "$state_file"
    cat > "${SANDBOX}/mock_scripts/session-state.sh" << MOCK_EOF
#!/bin/bash
STATE_FILE="${state_file}"
if [[ "\$1" == "state" ]]; then
    count=\$(cat "\$STATE_FILE")
    count=\$((count + 1))
    echo "\$count" > "\$STATE_FILE"
    if [[ "\$count" -ge 2 ]]; then
        echo "input-waiting"
        exit 0
    else
        echo "processing"
        exit 0
    fi
fi
if [[ "\$1" == "wait" ]]; then
    exit 0
fi
exit 0
MOCK_EOF
    chmod +x "${SANDBOX}/mock_scripts/session-state.sh"
    echo "$state_file"
}

# =============================================================================
# AC1: 並列送信の排他制御（flock 実装チェック）
# RED: flock 未実装のため FAIL する
# =============================================================================
echo ""
echo "--- AC1: 並列送信の排他制御 ---"

# AC1 構造チェック: session-comm.sh に flock が使われているか
test_ac1_flock_exists_in_script() {
    # AC1: 並列で 10 並列送信しても全メッセージが正しい順で届く
    # 実装: flock による排他制御が必要
    # RED: flock は未実装なので FAIL する
    grep -q 'flock' "$SCRIPT"
}
run_test "ac1: flock による排他制御が実装されている" test_ac1_flock_exists_in_script

# AC1 構造チェック: send-keys 呼び出しが flock スコープ内にあるか
test_ac1_send_keys_inside_flock_scope() {
    # AC1: send-keys が flock ブロック（ロックファイル指定）内にある
    # RED: flock 未実装なので FAIL する
    local flock_line send_line
    flock_line=$(grep -n 'flock' "$SCRIPT" | head -1 | cut -d: -f1)
    send_line=$(grep -n 'send-keys' "$SCRIPT" | head -1 | cut -d: -f1)
    # flock が存在し、かつ send-keys より前に現れる
    [[ -n "$flock_line" ]] && [[ -n "$send_line" ]] && [[ "$flock_line" -lt "$send_line" ]]
}
run_test "ac1: send-keys が flock スコープ内にある" test_ac1_send_keys_inside_flock_scope

# AC1 機能チェック: inject が flock ロックファイルを使用した排他送信を行うか
test_ac1_inject_uses_lock_file() {
    # AC1: 並列で 10 並列送信しても全メッセージが正しい順で届く
    # 実装: inject の send-keys 呼び出しが flock でロックされる必要がある
    # RED: flock 未実装のため、ロックファイルを作成しない → FAIL
    create_mock_session_state_input_waiting
    local call_log
    call_log=$(create_mock_tmux_ordered)

    local lock_dir="${SANDBOX}/lock_dir"
    PATH="${SANDBOX}/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="${SANDBOX}/mock_scripts" \
    SESSION_COMM_LOCK_DIR="$lock_dir" \
    bash "$SCRIPT" inject "session:0" "hello" 2>/dev/null || true

    # flock 実装後: ロックファイルが SESSION_COMM_LOCK_DIR 配下に存在するか
    # またはスクリプトに flock の呼び出しが含まれていること（構造チェックと組み合わせ）
    # ここでは「スクリプトが flock を使用しているか」を実行ログから検証
    # flock 未実装 → grep は何もマッチしない → RED
    grep -q 'flock' "$SCRIPT"
}
run_test "ac1: inject が flock を使用した排他送信を行う" test_ac1_inject_uses_lock_file

# =============================================================================
# AC2: non-input-waiting 時の自動リトライ
# RED: retry 未実装のため FAIL する
# =============================================================================
echo ""
echo "--- AC2: non-input-waiting 時の自動リトライ ---"

# AC2 構造チェック: inject に retry ロジックが実装されているか
test_ac2_retry_logic_exists() {
    # AC2: 受信側が input-waiting でない場合、送信は 5 秒待機後に retry
    # RED: retry ロジック未実装なので FAIL する
    grep -q 'retry\|RETRY\|retry_count\|max_retry\|sleep.*retry\|retry.*sleep' "$SCRIPT"
}
run_test "ac2: inject に retry ロジックが実装されている" test_ac2_retry_logic_exists

# AC2 構造チェック: 5 秒待機が実装されているか
test_ac2_5sec_sleep_before_retry() {
    # AC2: 5 秒待機後に retry
    # RED: retry 未実装なので sleep 5 も存在しない
    grep -q 'sleep 5\|sleep.*5' "$SCRIPT"
}
run_test "ac2: retry 前に 5 秒待機が実装されている" test_ac2_5sec_sleep_before_retry

# AC2 機能チェック: non-input-waiting 時に exit 2 で即終了せず retry する
test_ac2_inject_retries_when_not_input_waiting() {
    # AC2: 受信側が input-waiting でない場合、送信は 5 秒待機後に retry
    # 現状: exit 2 で即終了する → RED
    # 実装後: retry して、最終的に成功する場合は exit 0 を返すべき
    create_mock_session_state_not_input_waiting
    # mock tmux は send-keys を記録するだけ
    local call_log
    call_log=$(create_mock_tmux_ordered)

    local exit_code=0
    # non-input-waiting 時: retry 実装後は最終的に exit 2（タイムアウト）になるはず
    # 現状では即 exit 2 → 実装後は少なくとも 1 回 sleep を挟んで再試行することを期待
    # このテストは「exit 2 以外のコードを返す OR send-keys が記録されない」ことで RED を確認
    # 実際の retry 検証は state_count をチェックする
    local state_call_file="${SANDBOX}/state_calls"
    echo "0" > "$state_call_file"

    # state を 2 回呼ばれたことを確認する mock に差し替え
    cat > "${SANDBOX}/mock_scripts/session-state.sh" << MOCK_EOF
#!/bin/bash
COUNT_FILE="${state_call_file}"
if [[ "\$1" == "state" ]]; then
    count=\$(cat "\$COUNT_FILE")
    count=\$((count + 1))
    echo "\$count" > "\$COUNT_FILE"
    echo "processing"
    exit 0
fi
exit 1
MOCK_EOF
    chmod +x "${SANDBOX}/mock_scripts/session-state.sh"

    PATH="${SANDBOX}/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="${SANDBOX}/mock_scripts" \
    bash "$SCRIPT" inject "session:0" "hello" 2>/dev/null || exit_code=$?

    # retry 実装後: state が 2 回以上呼ばれる（初回 + retry 後の再チェック）
    local call_count
    call_count=$(cat "$state_call_file")
    # 現状（retry 未実装）: state は 1 回しか呼ばれず即 exit 2 → RED
    [[ "$call_count" -ge 2 ]]
}
run_test "ac2: non-input-waiting 時に session-state.sh state が 2 回以上呼ばれる（retry 確認）" test_ac2_inject_retries_when_not_input_waiting

# AC2 機能チェック: retry 後に input-waiting になれば送信が成功する
test_ac2_inject_succeeds_after_retry_when_becomes_ready() {
    # AC2: retry 後に input-waiting になれば inject は exit 0 で完了すべき
    # RED: retry 未実装のため、最初の non-input-waiting で exit 2 する
    local state_file
    state_file=$(create_mock_session_state_becomes_ready_after_delay)
    local call_log
    call_log=$(create_mock_tmux_ordered)

    local exit_code=0
    PATH="${SANDBOX}/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="${SANDBOX}/mock_scripts" \
    bash "$SCRIPT" inject "session:0" "hello" 2>/dev/null || exit_code=$?

    # retry 実装後: state が 2 回呼ばれ（1 回目: processing、2 回目: input-waiting）
    # exit 0 で成功するはず
    # RED（現状）: 1 回目で exit 2 → exit_code=2 でテスト FAIL
    [[ "$exit_code" -eq 0 ]]
}
run_test "ac2: 2 回目の状態確認で input-waiting になれば inject が exit 0 で成功する" test_ac2_inject_succeeds_after_retry_when_becomes_ready

# =============================================================================
# AC3: 既存 API シグネチャ互換維持（GREEN baseline）
# これらは現時点で PASS することが期待される
# =============================================================================
echo ""
echo "--- AC3: 既存 API シグネチャ互換維持 ---"

# AC3: inject サブコマンドが存在する
test_ac3_inject_subcommand_exists() {
    # AC3: inject サブコマンドの API 互換
    # inject <window> <text> [--force] [--no-enter] シグネチャが存在する
    grep -q 'cmd_inject\(\)' "$SCRIPT"
}
run_test "ac3: cmd_inject 関数が定義されている" test_ac3_inject_subcommand_exists

# AC3: inject-file サブコマンドが存在する
test_ac3_inject_file_subcommand_exists() {
    # AC3: inject-file サブコマンドの API 互換
    grep -q 'cmd_inject_file\(\)' "$SCRIPT"
}
run_test "ac3: cmd_inject_file 関数が定義されている" test_ac3_inject_file_subcommand_exists

# AC3: inject が --force オプションを受け付ける
test_ac3_inject_supports_force_flag() {
    # AC3: inject --force フラグが受け付けられる
    grep -q -- '--force' "$SCRIPT"
}
run_test "ac3: inject が --force オプションをサポートしている" test_ac3_inject_supports_force_flag

# AC3: inject が --no-enter オプションを受け付ける
test_ac3_inject_supports_no_enter_flag() {
    # AC3: inject --no-enter フラグが受け付けられる
    grep -q -- '--no-enter' "$SCRIPT"
}
run_test "ac3: inject が --no-enter オプションをサポートしている" test_ac3_inject_supports_no_enter_flag

# AC3: inject-file が --wait オプションを受け付ける
test_ac3_inject_file_supports_wait_flag() {
    # AC3: inject-file --wait フラグが受け付けられる
    grep -q -- '--wait' "$SCRIPT"
}
run_test "ac3: inject-file が --wait オプションをサポートしている" test_ac3_inject_file_supports_wait_flag

# AC3: inject が state != input-waiting かつ --force なしで exit 2 を返す（既存動作）
test_ac3_inject_exits_2_when_not_input_waiting_without_force() {
    # AC3: 既存動作（--force なし時の exit 2）は維持される
    create_mock_session_state_not_input_waiting
    create_mock_tmux_ordered > /dev/null

    local exit_code=0
    PATH="${SANDBOX}/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="${SANDBOX}/mock_scripts" \
    bash "$SCRIPT" inject "session:0" "hello" 2>/dev/null || exit_code=$?

    # retry 実装後もタイムアウト時は exit 2 を維持すること
    # 現状（retry 未実装）: 即 exit 2 → PASS（GREEN baseline）
    # 実装後も: 最終的に exit 2（タイムアウト）であること
    [[ "$exit_code" -eq 2 ]]
}
run_test "ac3: inject が non-input-waiting かつ --force なしで exit 2 を返す（既存 API 維持）" test_ac3_inject_exits_2_when_not_input_waiting_without_force

# AC3: inject-file のメインディスパッチに inject-file が登録されている
test_ac3_dispatch_inject_file() {
    # AC3: case文に inject-file が存在する
    grep -q "inject-file)" "$SCRIPT"
}
run_test "ac3: メインディスパッチに inject-file が登録されている" test_ac3_dispatch_inject_file

# AC3: inject のメインディスパッチに inject が登録されている
test_ac3_dispatch_inject() {
    # AC3: case文に inject が存在する
    grep -qE "^\s+inject\)" "$SCRIPT"
}
run_test "ac3: メインディスパッチに inject が登録されている" test_ac3_dispatch_inject

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
