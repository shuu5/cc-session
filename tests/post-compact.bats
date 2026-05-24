#!/usr/bin/env bats
# post-compact.bats — PostCompact フック（ready-compaction）の unit tests

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
POST_COMPACT="$SCRIPT_DIR/hooks/post-compact.sh"

setup() {
    SANDBOX="$(mktemp -d)"
    export WORKING_MEMORY_DIR="$SANDBOX/.claude-session"
    # 派生変数は session-env.sh に解決させる（外部環境の汚染を排除）
    unset WORKING_MEMORY_FILE WORKING_MEMORY_CONSUMED_FILE COMPACTION_ENABLED_MARKER COMPACTION_LOG_FILE
    WM_FILE="$WORKING_MEMORY_DIR/working-memory.md"
    CONSUMED="$WORKING_MEMORY_DIR/working-memory.consumed.md"
    MARKER="$WORKING_MEMORY_DIR/.compaction-enabled"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    unset WORKING_MEMORY_DIR
}

@test "post-compact: opt-in マーカー不在なら no-op（exit 0・無出力）" {
    run bash "$POST_COMPACT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "post-compact: WM あり → 内容を stdout に注入し consumed へ mv する" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    printf '%s\n' "RESTORE_PAYLOAD_XYZ" > "$WM_FILE"
    run bash "$POST_COMPACT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESTORE_PAYLOAD_XYZ"* ]]
    [[ "$output" == *"復元"* ]]
    # WM 本体は consumed に移動している
    [ ! -f "$WM_FILE" ]
    [ -f "$CONSUMED" ]
    grep -q "RESTORE_PAYLOAD_XYZ" "$CONSUMED"
}

@test "post-compact: WM なし → フォールバックメッセージを出す" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    run bash "$POST_COMPACT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"退避された Working Memory なし"* ]]
    [ ! -f "$CONSUMED" ]
}
