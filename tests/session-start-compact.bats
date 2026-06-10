#!/usr/bin/env bats
# session-start-compact.bats — SessionStart(compact) フック（ready-compaction）の unit tests

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
SESSION_START="$SCRIPT_DIR/hooks/session-start-compact.sh"

setup() {
    SANDBOX="$(mktemp -d)"
    export WORKING_MEMORY_DIR="$SANDBOX/.claude-session"
    # 派生変数は session-env.sh に解決させる（外部環境の汚染を排除）
    unset WORKING_MEMORY_FILE WORKING_MEMORY_CONSUMED_FILE COMPACTION_ENABLED_MARKER COMPACTION_LOG_FILE
    # ambient な実セッション id を排除し legacy 非 scoped パスで決定論化（session-scoped は
    # working-memory-session-scoped.bats が固定。これらは legacy 経路の回帰ガード）。
    unset CLAUDE_CODE_SESSION_ID WM_SESSION_ID WORKING_MEMORY_SESSION_ID
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

@test "session-start-compact: working のみ（consumed なし）→ 条件付きの復元案内（断定 Read 誘導でない）" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    printf '%s\n' "UNCONSUMED" > "$WM_FILE"
    run bash "$SESSION_START"
    [ "$status" -eq 0 ]
    [[ "$output" == *"退避された作業状態があります"* ]]
    [[ "$output" == *"まだ注入していなければ"* ]]
    # 旧来の断定的「未復元 → Read して復元せよ」誤誘導は出さない
    [[ "$output" != *"未復元の作業状態が残っています"* ]]
}

@test "session-start-compact: consumed があれば carry-forward リマインダを出す" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    printf '%s\n' "## この effort を貫く命令・制約" > "$WORKING_MEMORY_DIR/working-memory.consumed.md"
    run bash "$SESSION_START"
    [ "$status" -eq 0 ]
    [[ "$output" == *"carry-forward"* ]]
}

@test "session-start-compact: working+consumed 共存 → consumed 優先・working の Read 誘導/一覧掲載を出さない（順序非依存）" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    printf '%s\n' "STAGED" > "$WM_FILE"
    printf '%s\n' "## この effort を貫く命令・制約" > "$WORKING_MEMORY_DIR/working-memory.consumed.md"
    run bash "$SESSION_START"
    [ "$status" -eq 0 ]
    [[ "$output" == *"carry-forward"* ]]
    # working の復元誘導（誤誘導）は出さない
    [[ "$output" != *"退避された作業状態があります"* ]]
    # 外部化ファイル一覧にも working-memory.md を出さない（consumed 済み＝重複とみなす）
    [[ "$output" != *"- working-memory.md"* ]]
}
