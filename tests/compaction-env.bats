#!/usr/bin/env bats
# compaction-env.bats — session-env.sh の Working Memory 変数群の unit tests
# ready-compaction 移植: WORKING_MEMORY_* / COMPACTION_* パス解決の SSOT 検証

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
SESSION_ENV_SH="$SCRIPT_DIR/lib/session-env.sh"

setup() {
    SANDBOX="$(mktemp -d)"
    # ambient な実セッション id を排除し legacy 非 scoped パスで決定論化（session-scoped は
    # working-memory-session-scoped.bats が固定。これらは legacy 経路の回帰ガード）。
    unset CLAUDE_CODE_SESSION_ID WM_SESSION_ID WORKING_MEMORY_SESSION_ID
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

@test "session-env: WORKING_MEMORY_DIR は既定で PWD/.claude-session" {
    run bash -c "cd '$SANDBOX' && source '$SESSION_ENV_SH' && echo \"\$WORKING_MEMORY_DIR\""
    [ "$status" -eq 0 ]
    [[ "$output" == "$SANDBOX/.claude-session" ]]
}

@test "session-env: WORKING_MEMORY_FILE は既定で WORKING_MEMORY_DIR 配下" {
    run bash -c "cd '$SANDBOX' && source '$SESSION_ENV_SH' && echo \"\$WORKING_MEMORY_FILE\""
    [ "$status" -eq 0 ]
    [[ "$output" == "$SANDBOX/.claude-session/working-memory.md" ]]
}

@test "session-env: WORKING_MEMORY_DIR の上書きが派生パスに伝播する" {
    run bash -c "export WORKING_MEMORY_DIR='$SANDBOX/custom'; source '$SESSION_ENV_SH'; echo \"\$WORKING_MEMORY_FILE|\$COMPACTION_ENABLED_MARKER\""
    [ "$status" -eq 0 ]
    [[ "$output" == "$SANDBOX/custom/working-memory.md|$SANDBOX/custom/.compaction-enabled" ]]
}

@test "session-env: WORKING_MEMORY_FILE は単独で上書きできる" {
    run bash -c "export WORKING_MEMORY_FILE='$SANDBOX/x/wm.md'; source '$SESSION_ENV_SH'; echo \"\$WORKING_MEMORY_FILE\""
    [ "$status" -eq 0 ]
    [[ "$output" == "$SANDBOX/x/wm.md" ]]
}

@test "session-env: Working Memory 変数群が export されている" {
    run bash -c "source '$SESSION_ENV_SH' && export -p | grep -cE 'WORKING_MEMORY_DIR=|WORKING_MEMORY_FILE=|WORKING_MEMORY_CONSUMED_FILE=|COMPACTION_ENABLED_MARKER=|COMPACTION_LOG_FILE='"
    [ "$status" -eq 0 ]
    [[ "$output" == "5" ]]
}
