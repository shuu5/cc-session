#!/usr/bin/env bats
# window-manifest.bats - window-manifest.sh の unit tests
# Issue #290: Phase 2 tmux window-manifest 書き出し（producer 責務）

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
MANIFEST_LIB="$SCRIPT_DIR/window-manifest.sh"

setup() {
    SANDBOX="$(mktemp -d)"
    # Use $HOME-based path to satisfy WINDOW_MANIFEST_FILE security policy
    local _manifest_dir="$HOME/.local/share/claude-session"
    mkdir -p "$_manifest_dir"
    export WINDOW_MANIFEST_FILE="$_manifest_dir/window-manifest-test-${BATS_TEST_NUMBER:-0}.json"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    rm -f "$WINDOW_MANIFEST_FILE" "${WINDOW_MANIFEST_FILE}.lock" 2>/dev/null || true
    rm -f "${WINDOW_MANIFEST_FILE}".* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Scenario: 新規 manifest への append write
# ---------------------------------------------------------------------------
@test "manifest_append_entry: creates manifest when file does not exist" {
    source "$MANIFEST_LIB"
    manifest_append_entry "wt-twill-feat-290-a1b2c3d4" "main" 1 \
        "/home/user/projects/twill" "/home/user/projects/twill" "wt"

    [[ -f "$WINDOW_MANIFEST_FILE" ]]
    run jq -r '.schema_version' "$WINDOW_MANIFEST_FILE"
    [[ "$output" == "1" ]]
    run jq -r '.entries[0].window_name' "$WINDOW_MANIFEST_FILE"
    [[ "$output" == "wt-twill-feat-290-a1b2c3d4" ]]
    run jq -r '.entries[0].tombstone' "$WINDOW_MANIFEST_FILE"
    [[ "$output" == "false" ]]
}

@test "manifest_append_entry: appends to existing manifest" {
    source "$MANIFEST_LIB"
    manifest_append_entry "wt-twill-first-a1b2c3d4" "main" 1 \
        "/home/user/projects/twill" "/home/user/projects/twill" "wt"
    manifest_append_entry "fk-twill-first-b2c3d4e5" "main" 2 \
        "/home/user/projects/twill" "/home/user/projects/twill" "fk"

    run jq '.entries | length' "$WINDOW_MANIFEST_FILE"
    [[ "$output" == "2" ]]
    run jq -r '.entries[1].prefix' "$WINDOW_MANIFEST_FILE"
    [[ "$output" == "fk" ]]
}

# ---------------------------------------------------------------------------
# Scenario: atomic write (temp + rename)
# ---------------------------------------------------------------------------
@test "manifest_append_entry: uses atomic write (no partial temp file)" {
    source "$MANIFEST_LIB"
    manifest_append_entry "wt-twill-feat-290-a1b2c3d4" "main" 1 \
        "/home/user/projects/twill" "/home/user/projects/twill" "wt"

    # 中間 .XXXXXX 一時ファイルが残っていないことを確認（.lock ファイルは除外）
    local manifest_dir manifest_base leftover
    manifest_dir="$(dirname "$WINDOW_MANIFEST_FILE")"
    manifest_base="$(basename "$WINDOW_MANIFEST_FILE")"
    leftover=$(find "$manifest_dir" -name "$manifest_base.*" \
        ! -name "$manifest_base.lock" 2>/dev/null || true)
    [[ -z "$leftover" ]]
}

# ---------------------------------------------------------------------------
# Scenario: tombstone write
# ---------------------------------------------------------------------------
@test "manifest_tombstone_entry: marks entry as tombstone=true" {
    source "$MANIFEST_LIB"
    manifest_append_entry "wt-twill-feat-290-a1b2c3d4" "main" 1 \
        "/home/user/projects/twill" "/home/user/projects/twill" "wt"
    manifest_tombstone_entry "wt-twill-feat-290-a1b2c3d4"

    run jq -r '.entries[0].tombstone' "$WINDOW_MANIFEST_FILE"
    [[ "$output" == "true" ]]
}

@test "manifest_tombstone_entry: does not affect other entries" {
    source "$MANIFEST_LIB"
    manifest_append_entry "wt-twill-first-a1b2c3d4" "main" 1 \
        "/home/user/projects/twill" "/home/user/projects/twill" "wt"
    manifest_append_entry "fk-twill-second-b2c3d4e5" "main" 2 \
        "/home/user/projects/twill" "/home/user/projects/twill" "fk"
    manifest_tombstone_entry "wt-twill-first-a1b2c3d4"

    run jq -r '.entries[0].tombstone' "$WINDOW_MANIFEST_FILE"
    [[ "$output" == "true" ]]
    run jq -r '.entries[1].tombstone' "$WINDOW_MANIFEST_FILE"
    [[ "$output" == "false" ]]
}

# ---------------------------------------------------------------------------
# Scenario: schema_version 不一致時の write 拒否
# ---------------------------------------------------------------------------
@test "manifest_append_entry: refuses write when schema_version mismatches" {
    echo '{"schema_version":99,"entries":[]}' > "$WINDOW_MANIFEST_FILE"
    source "$MANIFEST_LIB"

    # 警告を stderr に出すが exit 0（呼び出し元を停止しない）
    run bash -c "
        source '$MANIFEST_LIB'
        manifest_append_entry 'wt-twill-feat-290-a1b2c3d4' 'main' 1 \
            '/home/user/projects/twill' '/home/user/projects/twill' 'wt' 2>&1
        cat '$WINDOW_MANIFEST_FILE'
    "
    [[ "$status" -eq 0 ]]
    # 警告メッセージが出力される
    [[ "$output" == *"schema_version 不一致"* ]]
    # manifest 内容が変更されていない
    run jq '.schema_version' "$WINDOW_MANIFEST_FILE"
    [[ "$output" == "99" ]]
}

@test "manifest_tombstone_entry: refuses write when schema_version mismatches" {
    echo '{"schema_version":99,"entries":[{"window_name":"old","tombstone":false}]}' > "$WINDOW_MANIFEST_FILE"
    source "$MANIFEST_LIB"

    run bash -c "
        source '$MANIFEST_LIB'
        manifest_tombstone_entry 'old' 2>&1
        cat '$WINDOW_MANIFEST_FILE'
    "
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"schema_version 不一致"* ]]
    # tombstone が変更されていない
    run jq -r '.entries[0].tombstone' "$WINDOW_MANIFEST_FILE"
    [[ "$output" == "false" ]]
}

# ---------------------------------------------------------------------------
# Scenario: unknown field tolerance
# ---------------------------------------------------------------------------
@test "manifest_tombstone_entry: preserves unknown fields on tombstone" {
    printf '%s\n' '{"schema_version":1,"entries":[{"window_name":"wt-twill-a1b2c3d4","session":"main","index":1,"worktree_path":"/p","cwd":"/p","prefix":"wt","created_at":"2026-01-01T00:00:00Z","tombstone":false,"future_field":"preserved"}]}' \
        > "$WINDOW_MANIFEST_FILE"
    source "$MANIFEST_LIB"
    manifest_tombstone_entry "wt-twill-a1b2c3d4"

    run jq -r '.entries[0].future_field' "$WINDOW_MANIFEST_FILE"
    [[ "$output" == "preserved" ]]
    run jq -r '.entries[0].tombstone' "$WINDOW_MANIFEST_FILE"
    [[ "$output" == "true" ]]
}

@test "manifest_append_entry: reads manifest with unknown top-level fields without error" {
    printf '%s\n' '{"schema_version":1,"entries":[],"consumer_meta":{"gc_policy":"7d"}}' \
        > "$WINDOW_MANIFEST_FILE"
    source "$MANIFEST_LIB"

    run manifest_append_entry "wt-twill-feat-290-a1b2c3d4" "main" 1 \
        "/home/user/projects/twill" "/home/user/projects/twill" "wt"
    [[ "$status" -eq 0 ]]
    run jq '.entries | length' "$WINDOW_MANIFEST_FILE"
    [[ "$output" == "1" ]]
}

# ---------------------------------------------------------------------------
# Scenario: CLI direct invocation
# ---------------------------------------------------------------------------
@test "CLI tombstone: window-manifest.sh tombstone <window_name> works" {
    source "$MANIFEST_LIB"
    manifest_append_entry "wt-twill-feat-290-a1b2c3d4" "main" 1 \
        "/home/user/projects/twill" "/home/user/projects/twill" "wt"

    run bash "$MANIFEST_LIB" tombstone "wt-twill-feat-290-a1b2c3d4"
    [[ "$status" -eq 0 ]]
    run jq -r '.entries[0].tombstone' "$WINDOW_MANIFEST_FILE"
    [[ "$output" == "true" ]]
}

@test "CLI tombstone: missing argument exits with error" {
    run bash "$MANIFEST_LIB" tombstone
    [[ "$status" -ne 0 ]]
}

# ---------------------------------------------------------------------------
# Issue #323: HOME ディレクトリ外パスの拒否
# ---------------------------------------------------------------------------

@test "security: WINDOW_MANIFEST_FILE outside \$HOME rejects with error on source" {
    # Scenario: $HOME 外パス設定時のエラー
    # WHEN: WINDOW_MANIFEST_FILE=/tmp/evil.json を設定した状態でスクリプトを source する
    # THEN: stderr に「WINDOW_MANIFEST_FILE must be under $HOME」を含むエラーを出力し、exit ステータス 1 を返す
    run bash -c "
        set -e
        export HOME='$HOME'
        export WINDOW_MANIFEST_FILE='/tmp/evil.json'
        source '$MANIFEST_LIB'
        echo 'should not reach here'
    "
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"WINDOW_MANIFEST_FILE must be under \$HOME"* ]]
}

@test "security: WINDOW_MANIFEST_FILE under \$HOME sources without error" {
    # Scenario: $HOME 配下パス設定時の正常動作
    # WHEN: WINDOW_MANIFEST_FILE=$HOME/.local/share/claude-session/custom.json を設定した状態でスクリプトを source する
    # THEN: エラーなく正常に source される
    local custom_path="$HOME/.local/share/claude-session/custom-test.json"
    run bash -c "
        export HOME='$HOME'
        export WINDOW_MANIFEST_FILE='$custom_path'
        source '$MANIFEST_LIB'
        echo 'sourced_ok'
    "
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"sourced_ok"* ]]
}

# ---------------------------------------------------------------------------
# Issue #323: シンボリックリンクファイルの拒否
# ---------------------------------------------------------------------------

@test "security: manifest_append_entry rejects symlink lockfile" {
    # Scenario: symlink lockfile でのエントリ追加拒否
    # WHEN: lockfile パスがシンボリックリンクの状態で manifest_append_entry() を呼び出す
    # THEN: stderr に「lockfile is a symlink」を含むエラーを出力し、return 1 する
    source "$MANIFEST_LIB"

    # lockfile パスにシンボリックリンクを作成
    local lockfile_path="${WINDOW_MANIFEST_FILE}.lock"
    local symlink_target="$SANDBOX/symlink_target.lock"
    touch "$symlink_target"
    ln -s "$symlink_target" "$lockfile_path"

    run bash -c "
        export WINDOW_MANIFEST_FILE='$WINDOW_MANIFEST_FILE'
        source '$MANIFEST_LIB'
        manifest_append_entry 'wt-twill-feat-323-a1b2c3d4' 'main' 1 \
            '/home/user/projects/twill' '/home/user/projects/twill' 'wt' 2>&1
        echo \"exit:\$?\"
    "
    [[ "$output" == *"lockfile is a symlink"* ]]
    [[ "$output" == *"exit:1"* ]]
}

@test "security: manifest_tombstone_entry rejects symlink lockfile" {
    # Scenario: symlink lockfile でのトゥームストーン拒否
    # WHEN: lockfile パスがシンボリックリンクの状態で manifest_tombstone_entry() を呼び出す
    # THEN: stderr に「lockfile is a symlink」を含むエラーを出力し、return 1 する
    source "$MANIFEST_LIB"

    # まず正常にエントリを作成
    manifest_append_entry "wt-twill-feat-323-a1b2c3d4" "main" 1 \
        "/home/user/projects/twill" "/home/user/projects/twill" "wt"

    # lockfile パスにシンボリックリンクを作成（既存lockfileを削除してシンボリックリンクに置換）
    local lockfile_path="${WINDOW_MANIFEST_FILE}.lock"
    rm -f "$lockfile_path"
    local symlink_target="$SANDBOX/symlink_target2.lock"
    touch "$symlink_target"
    ln -s "$symlink_target" "$lockfile_path"

    run bash -c "
        export WINDOW_MANIFEST_FILE='$WINDOW_MANIFEST_FILE'
        source '$MANIFEST_LIB'
        manifest_tombstone_entry 'wt-twill-feat-323-a1b2c3d4' 2>&1
        echo \"exit:\$?\"
    "
    [[ "$output" == *"lockfile is a symlink"* ]]
    [[ "$output" == *"exit:1"* ]]
}
