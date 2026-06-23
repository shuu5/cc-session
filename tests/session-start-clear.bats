#!/usr/bin/env bats
# session-start-clear.bats — SessionStart(clear) フック（ready-compaction 安全網・bd ccs-et2）の unit tests
#
# 検証観点（grill 2026-06-23 / 論点2 案 B）:
#   - opt-in 規約踏襲（マーカー不在 → no-op）
#   - 退避ファイルへの read-only ポインタ提示（cat 注入・consumed mv を「しない」ことの保証）
#   - 厳密 sid 一致の優先と、不一致時の最新 mtime フォールバック
#   - consumed.md は提示対象から除外
#   - 他 sid 由来を拾った場合の「別セッション由来の可能性」正直表示

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
HOOK="$SCRIPT_DIR/hooks/session-start-clear.sh"

setup() {
    SANDBOX="$(mktemp -d)"
    export WORKING_MEMORY_DIR="$SANDBOX/.claude-session"
    # 派生変数は session-env.sh に解決させる（外部環境の汚染を排除）
    unset WORKING_MEMORY_FILE WORKING_MEMORY_CONSUMED_FILE COMPACTION_ENABLED_MARKER COMPACTION_LOG_FILE
    # ambient な実セッション id を排除（各テストが必要なら WM_SESSION_ID を明示）
    unset CLAUDE_CODE_SESSION_ID WM_SESSION_ID WORKING_MEMORY_SESSION_ID
    WM_FILE="$WORKING_MEMORY_DIR/working-memory.md"           # legacy 非 scoped（exact 経路）
    MARKER="$WORKING_MEMORY_DIR/.compaction-enabled"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    unset WORKING_MEMORY_DIR WM_SESSION_ID
}

@test "session-start-clear: opt-in マーカー不在なら no-op（exit 0・無出力）" {
    run bash "$HOOK" </dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "session-start-clear: マーカーあり・退避ファイル無し → Long-term ヒントのみ（working pointer は出さない）" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    run bash "$HOOK" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"Long-term Memory"* ]]
    [[ "$output" != *"退避された作業状態があります"* ]]
}

@test "session-start-clear: 厳密 sid 一致あり → read-only ポインタを出す（別セッション caveat は出さない）" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    printf '%s\n' "STAGED" > "$WM_FILE"   # 非 scoped（session id 空）= 厳密一致
    run bash "$HOOK" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"退避された作業状態があります（read-only ポインタ）"* ]]
    [[ "$output" == *"working-memory.md"* ]]
    [[ "$output" == *"復元を自動注入しません"* ]]
    # 厳密一致なので「別セッション由来の可能性」は出さない
    [[ "$output" != *"別セッション由来の可能性"* ]]
}

@test "session-start-clear: read-only 保証 — working を mv/削除せず consumed も作らない" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    printf '%s\n' "DO-NOT-TOUCH" > "$WM_FILE"
    run bash "$HOOK" </dev/null
    [ "$status" -eq 0 ]
    # working はそのまま残り、内容も不変
    [ -f "$WM_FILE" ]
    [ "$(cat "$WM_FILE")" = "DO-NOT-TOUCH" ]
    # consumed を作らない（cat 注入後 mv の post-compact 挙動を持ち込まない）
    [ ! -f "$WORKING_MEMORY_DIR/working-memory.consumed.md" ]
}

@test "session-start-clear: 厳密一致なし → 最新 mtime の working-memory*.md へフォールバック＋別セッション caveat" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    # 現セッションは別 sid（exact 一致ファイルは存在しない）
    export WM_SESSION_ID="newsid"
    printf '%s\n' "OLD" > "$WORKING_MEMORY_DIR/working-memory.oldsid.md"
    run bash "$HOOK" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"退避された作業状態があります（read-only ポインタ）"* ]]
    [[ "$output" == *"working-memory.oldsid.md"* ]]
    [[ "$output" == *"別セッション由来の可能性"* ]]
    # フォールバックでもファイルを壊さない
    [ -f "$WORKING_MEMORY_DIR/working-memory.oldsid.md" ]
}

@test "session-start-clear: フォールバックは最新 mtime を選ぶ" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    export WM_SESSION_ID="newsid"
    printf '%s\n' "A" > "$WORKING_MEMORY_DIR/working-memory.aaa.md"
    printf '%s\n' "B" > "$WORKING_MEMORY_DIR/working-memory.bbb.md"
    touch -d '2020-01-01T00:00:00' "$WORKING_MEMORY_DIR/working-memory.aaa.md"
    touch -d '2021-01-01T00:00:00' "$WORKING_MEMORY_DIR/working-memory.bbb.md"
    run bash "$HOOK" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"working-memory.bbb.md"* ]]
    [[ "$output" != *"working-memory.aaa.md"* ]]
}

@test "session-start-clear: consumed.md はフォールバック提示対象から除外" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    export WM_SESSION_ID="newsid"
    # 非 consumed の working は一切無く、consumed だけある状態
    printf '%s\n' "CONSUMED" > "$WORKING_MEMORY_DIR/working-memory.oldsid.consumed.md"
    run bash "$HOOK" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" != *"退避された作業状態があります"* ]]
    [[ "$output" != *"consumed.md"* ]]
}

@test "session-start-clear: 厳密一致は別 sid のより新しいファイルより優先される" {
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
    export WM_SESSION_ID="mysid"
    printf '%s\n' "MINE" > "$WORKING_MEMORY_DIR/working-memory.mysid.md"
    printf '%s\n' "OTHER" > "$WORKING_MEMORY_DIR/working-memory.other.md"
    # 別 sid の方を新しくしても、厳密一致（自分の sid）を優先する
    touch -d '2020-01-01T00:00:00' "$WORKING_MEMORY_DIR/working-memory.mysid.md"
    touch -d '2021-01-01T00:00:00' "$WORKING_MEMORY_DIR/working-memory.other.md"
    run bash "$HOOK" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"working-memory.mysid.md"* ]]
    [[ "$output" != *"別セッション由来の可能性"* ]]
}
