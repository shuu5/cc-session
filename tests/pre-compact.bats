#!/usr/bin/env bats
# pre-compact.bats — PreCompact フック（ready-compaction）の unit tests

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
PRE_COMPACT="$SCRIPT_DIR/hooks/pre-compact.sh"

setup() {
    SANDBOX="$(mktemp -d)"
    export WORKING_MEMORY_DIR="$SANDBOX/.claude-session"
    # 派生変数は session-env.sh に解決させる（外部環境の汚染を排除）
    unset WORKING_MEMORY_FILE WORKING_MEMORY_CONSUMED_FILE COMPACTION_ENABLED_MARKER COMPACTION_LOG_FILE
    WM_FILE="$WORKING_MEMORY_DIR/working-memory.md"
    MARKER="$WORKING_MEMORY_DIR/.compaction-enabled"
    LOG="$WORKING_MEMORY_DIR/compaction-log.txt"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    unset WORKING_MEMORY_DIR
}

@test "pre-compact: opt-in マーカー不在なら no-op（exit 0・無出力・ディレクトリ未作成）" {
    run bash "$PRE_COMPACT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -d "$WORKING_MEMORY_DIR" ]
}

@test "pre-compact: マーカーあり・WM 不在 → 安全網スケルトンを書き出す" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    run bash "$PRE_COMPACT"
    [ "$status" -eq 0 ]
    [ -f "$WM_FILE" ]
    grep -q "auto_precompact" "$WM_FILE"
    [[ "$output" == *"退避しました"* ]]
}

@test "pre-compact: マーカーあり・スキルが書いた WM は上書きしない" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    printf '%s\n' "SKILL_CONTENT_MARKER" > "$WM_FILE"
    run bash "$PRE_COMPACT"
    [ "$status" -eq 0 ]
    grep -q "SKILL_CONTENT_MARKER" "$WM_FILE"
    ! grep -q "auto_precompact" "$WM_FILE"
}

@test "pre-compact: compaction ログに追記する" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    run bash "$PRE_COMPACT"
    [ "$status" -eq 0 ]
    [ -f "$LOG" ]
    grep -q "pre-compact" "$LOG"
}

@test "pre-compact: 中間一時ファイルを残さない（atomic write）" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    run bash "$PRE_COMPACT"
    [ "$status" -eq 0 ]
    local leftover
    leftover=$(find "$WORKING_MEMORY_DIR" -name 'working-memory.md.*' 2>/dev/null || true)
    [ -z "$leftover" ]
}
