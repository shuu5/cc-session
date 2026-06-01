#!/usr/bin/env bats
# session-start-compact.bats — SessionStart(compact) フック（ready-compaction）の unit tests

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
SESSION_START="$SCRIPT_DIR/hooks/session-start-compact.sh"

setup() {
    SANDBOX="$(mktemp -d)"
    export WORKING_MEMORY_DIR="$SANDBOX/.claude-session"
    # 派生変数は session-env.sh に解決させる（外部環境の汚染を排除）
    unset WORKING_MEMORY_FILE WORKING_MEMORY_CONSUMED_FILE COMPACTION_ENABLED_MARKER COMPACTION_LOG_FILE
    WM_FILE="$WORKING_MEMORY_DIR/working-memory.md"
    MARKER="$WORKING_MEMORY_DIR/.compaction-enabled"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    unset WORKING_MEMORY_DIR
}

@test "session-start-compact: opt-in マーカー不在なら no-op（exit 0・無出力）" {
    run bash "$SESSION_START"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "session-start-compact: マーカーあり → Long-term Memory ヒントを出す" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    run bash "$SESSION_START"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Long-term Memory"* ]]
    [[ "$output" == *"memory_search"* ]]
}

@test "session-start-compact: 未消費 WM があれば復元警告を出す" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    printf '%s\n' "UNCONSUMED" > "$WM_FILE"
    run bash "$SESSION_START"
    [ "$status" -eq 0 ]
    [[ "$output" == *"未復元の作業状態が残っています"* ]]
}

@test "session-start-compact: consumed があれば carry-forward リマインダを出す" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    printf '%s\n' "## この effort を貫く命令・制約" > "$WORKING_MEMORY_DIR/working-memory.consumed.md"
    run bash "$SESSION_START"
    [ "$status" -eq 0 ]
    [[ "$output" == *"carry-forward"* ]]
}
