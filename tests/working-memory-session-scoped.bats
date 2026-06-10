#!/usr/bin/env bats
# working-memory-session-scoped.bats — Working Memory の session-scoped 化（un-gcu）
#
# 背景: session-env.sh が WORKING_MEMORY_FILE を $PWD/.claude-session/working-memory.md に
# 固定解決するため、cwd=anchor の複数 claude セッションが ready-compaction で同一ファイルを
# 奪い合い上書きする（2026-06-09 実害）。退避ファイルパスへ session id を含める session-scoped
# 化で構造的に根絶する。
#
# 設計（このテストが固定する契約）:
#   - session id 解決順: WM_SESSION_ID（明示/test override・hook が stdin から設定）
#                        > CLAUDE_CODE_SESSION_ID（bash tool / hook 継承 env）> 空
#   - 非空 → working-memory.<sid>.md / working-memory.<sid>.consumed.md（scoped）
#   - 空（解決不能 or slug 後空）→ working-memory.md / working-memory.consumed.md（legacy 後方互換）
#   - session id は [A-Za-z0-9-] のみへ slug 化・長さ上限（path traversal を構造排除）
#   - COMPACTION_ENABLED_MARKER / COMPACTION_LOG_FILE は session-scoped でない（プロジェクト共有）
#   - hook は stdin JSON の .session_id を一次ソースに解決（env 未継承の hook 文脈でも安定）

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
SESSION_ENV_SH="$SCRIPT_DIR/lib/session-env.sh"
LIB="$SCRIPT_DIR/lib"
HOOKS="$SCRIPT_DIR/hooks"

setup() {
    SANDBOX="$(mktemp -d)"
    export WORKING_MEMORY_DIR="$SANDBOX/.claude-session"
    # 派生変数は session-env.sh に解決させる（外部環境の汚染を排除）
    unset WORKING_MEMORY_FILE WORKING_MEMORY_CONSUMED_FILE COMPACTION_ENABLED_MARKER COMPACTION_LOG_FILE
    # ambient な実セッション id を排除して決定論化（このテストは session id を明示制御する）
    unset CLAUDE_CODE_SESSION_ID WM_SESSION_ID WORKING_MEMORY_SESSION_ID
    mkdir -p "$WORKING_MEMORY_DIR"
    MARKER="$WORKING_MEMORY_DIR/.compaction-enabled"
    touch "$MARKER"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    unset WORKING_MEMORY_DIR
}

# =============================================================================
# session-env.sh: session-scoped パス解決
# =============================================================================

@test "session-env: WM_SESSION_ID 設定で WORKING_MEMORY_FILE が session id を含む" {
    run bash -c "export WM_SESSION_ID=sessA; source '$SESSION_ENV_SH'; echo \"\$WORKING_MEMORY_FILE\""
    [ "$status" -eq 0 ]
    [[ "$output" == "$WORKING_MEMORY_DIR/working-memory.sessA.md" ]]
}

@test "session-env: WM_SESSION_ID 設定で consumed も session id を含む" {
    run bash -c "export WM_SESSION_ID=sessA; source '$SESSION_ENV_SH'; echo \"\$WORKING_MEMORY_CONSUMED_FILE\""
    [ "$status" -eq 0 ]
    [[ "$output" == "$WORKING_MEMORY_DIR/working-memory.sessA.consumed.md" ]]
}

@test "session-env: session id 無しは legacy 非 scoped（後方互換）" {
    run bash -c "unset CLAUDE_CODE_SESSION_ID WM_SESSION_ID; source '$SESSION_ENV_SH'; echo \"\$WORKING_MEMORY_FILE|\$WORKING_MEMORY_CONSUMED_FILE\""
    [ "$status" -eq 0 ]
    [[ "$output" == "$WORKING_MEMORY_DIR/working-memory.md|$WORKING_MEMORY_DIR/working-memory.consumed.md" ]]
}

@test "session-env: CLAUDE_CODE_SESSION_ID env から scoped 解決される" {
    run bash -c "unset WM_SESSION_ID; export CLAUDE_CODE_SESSION_ID=envSid; source '$SESSION_ENV_SH'; echo \"\$WORKING_MEMORY_FILE\""
    [ "$status" -eq 0 ]
    [[ "$output" == "$WORKING_MEMORY_DIR/working-memory.envSid.md" ]]
}

@test "session-env: WM_SESSION_ID が CLAUDE_CODE_SESSION_ID に優先する" {
    run bash -c "export WM_SESSION_ID=win CLAUDE_CODE_SESSION_ID=lose; source '$SESSION_ENV_SH'; echo \"\$WORKING_MEMORY_FILE\""
    [ "$status" -eq 0 ]
    [[ "$output" == "$WORKING_MEMORY_DIR/working-memory.win.md" ]]
}

@test "session-env: session id は slug 化されパストラバーサルを構造排除する" {
    run bash -c "export WM_SESSION_ID='../../evil'; source '$SESSION_ENV_SH'; echo \"\$WORKING_MEMORY_FILE\""
    [ "$status" -eq 0 ]
    # '..' や追加の '/' が混入しない（ファイル名は [A-Za-z0-9-] のみへ縮約）
    [[ "$output" != *..* ]]
    [[ "$output" == "$WORKING_MEMORY_DIR/working-memory.evil.md" ]]
}

@test "session-env: slug が空へ縮退したら legacy 非 scoped へフォールバック" {
    run bash -c "export WM_SESSION_ID='///...'; source '$SESSION_ENV_SH'; echo \"\$WORKING_MEMORY_FILE\""
    [ "$status" -eq 0 ]
    [[ "$output" == "$WORKING_MEMORY_DIR/working-memory.md" ]]
}

@test "session-env: 実 UUID 形式の session id はそのまま slug を通る" {
    run bash -c "export WM_SESSION_ID='ae6ee004-bb8f-4e31-addc-bd7cb06f362f'; source '$SESSION_ENV_SH'; echo \"\$WORKING_MEMORY_FILE\""
    [ "$status" -eq 0 ]
    [[ "$output" == "$WORKING_MEMORY_DIR/working-memory.ae6ee004-bb8f-4e31-addc-bd7cb06f362f.md" ]]
}

@test "session-env: marker は session-scoped でない（プロジェクト共有・session id 不問）" {
    run bash -c "export WM_SESSION_ID=sessA; source '$SESSION_ENV_SH'; echo \"\$COMPACTION_ENABLED_MARKER|\$COMPACTION_LOG_FILE\""
    [ "$status" -eq 0 ]
    [[ "$output" == "$WORKING_MEMORY_DIR/.compaction-enabled|$WORKING_MEMORY_DIR/compaction-log.txt" ]]
}

@test "session-env: 解決済み session id を WORKING_MEMORY_SESSION_ID として export する" {
    run bash -c "export WM_SESSION_ID=sessA; source '$SESSION_ENV_SH'; echo \"\$WORKING_MEMORY_SESSION_ID\""
    [ "$status" -eq 0 ]
    [[ "$output" == "sessA" ]]
}

# =============================================================================
# 衝突の根絶: 2 つの session id が互いの退避を上書きしない
# =============================================================================

@test "collision: 2 セッションが各自の退避ファイルへ書き互いに上書きしない" {
    bash -c "export WM_SESSION_ID=sessA; source '$SESSION_ENV_SH'; printf 'PAYLOAD_A\n' > \"\$WORKING_MEMORY_FILE\""
    bash -c "export WM_SESSION_ID=sessB; source '$SESSION_ENV_SH'; printf 'PAYLOAD_B\n' > \"\$WORKING_MEMORY_FILE\""
    local fa="$WORKING_MEMORY_DIR/working-memory.sessA.md"
    local fb="$WORKING_MEMORY_DIR/working-memory.sessB.md"
    [ -f "$fa" ]
    [ -f "$fb" ]
    grep -q "PAYLOAD_A" "$fa"
    grep -q "PAYLOAD_B" "$fb"
    # 互いに混入しない
    ! grep -q "PAYLOAD_B" "$fa"
    ! grep -q "PAYLOAD_A" "$fb"
}

# =============================================================================
# hook 統合: stdin JSON の session_id で自セッションを解決
# =============================================================================

@test "pre-compact: stdin session_id で自セッションの既存 working を尊重し他を生成しない" {
    local fa="$WORKING_MEMORY_DIR/working-memory.sessA.md"
    printf 'SKILL_A\n' > "$fa"
    # session A: 既存 working を上書きしない
    run bash -c "printf '%s' '{\"session_id\":\"sessA\"}' | bash '$HOOKS/pre-compact.sh'"
    [ "$status" -eq 0 ]
    grep -q "SKILL_A" "$fa"
    ! grep -q "auto_precompact" "$fa"
    # session B: working 不在 → 自分(sessB)のスケルトンを書く。A は無傷
    run bash -c "printf '%s' '{\"session_id\":\"sessB\"}' | bash '$HOOKS/pre-compact.sh'"
    [ "$status" -eq 0 ]
    [ -f "$WORKING_MEMORY_DIR/working-memory.sessB.md" ]
    grep -q "auto_precompact" "$WORKING_MEMORY_DIR/working-memory.sessB.md"
    grep -q "SKILL_A" "$fa"
}

@test "post-compact: stdin session_id で自セッションのみ復元・consumed 化し他を触らない" {
    local fa="$WORKING_MEMORY_DIR/working-memory.sessA.md"
    local fb="$WORKING_MEMORY_DIR/working-memory.sessB.md"
    printf 'PAYLOAD_A\n' > "$fa"
    printf 'PAYLOAD_B\n' > "$fb"
    run bash -c "printf '%s' '{\"session_id\":\"sessA\"}' | bash '$HOOKS/post-compact.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PAYLOAD_A"* ]]
    # 他セッション(B)の内容は復元しない
    [[ "$output" != *"PAYLOAD_B"* ]]
    # A は consumed へ mv、B は無傷
    [ ! -f "$fa" ]
    [ -f "$WORKING_MEMORY_DIR/working-memory.sessA.consumed.md" ]
    grep -q "PAYLOAD_A" "$WORKING_MEMORY_DIR/working-memory.sessA.consumed.md"
    [ -f "$fb" ]
    [ ! -f "$WORKING_MEMORY_DIR/working-memory.sessB.consumed.md" ]
}

@test "carry-forward: consumed→PreCompact の機械引き継ぎが同一セッション内に閉じる" {
    # sessA の consumed に命令を置く
    printf '%s\n' "## この effort を貫く命令・制約" "- [confirm] DIR_A" \
        > "$WORKING_MEMORY_DIR/working-memory.sessA.consumed.md"
    # sessA の PreCompact（working 不在）→ スケルトンが DIR_A を carry-forward
    run bash -c "printf '%s' '{\"session_id\":\"sessA\"}' | bash '$HOOKS/pre-compact.sh'"
    [ "$status" -eq 0 ]
    grep -q "DIR_A" "$WORKING_MEMORY_DIR/working-memory.sessA.md"
    # 別セッション sessB は A の consumed を拾わない（連鎖が混線しない）
    run bash -c "printf '%s' '{\"session_id\":\"sessB\"}' | bash '$HOOKS/pre-compact.sh'"
    [ "$status" -eq 0 ]
    [ -f "$WORKING_MEMORY_DIR/working-memory.sessB.md" ]
    ! grep -q "DIR_A" "$WORKING_MEMORY_DIR/working-memory.sessB.md"
}

@test "post-compact: stdin に session_id 無し → env CLAUDE_CODE_SESSION_ID にフォールバック" {
    printf 'FB_PAYLOAD\n' > "$WORKING_MEMORY_DIR/working-memory.envFallback.md"
    run bash -c "export CLAUDE_CODE_SESSION_ID=envFallback; printf '%s' '{}' | bash '$HOOKS/post-compact.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"FB_PAYLOAD"* ]]
    [ -f "$WORKING_MEMORY_DIR/working-memory.envFallback.consumed.md" ]
}

@test "session-start-compact: stdin session_id で自セッションの consumed を見て carry-forward 案内" {
    printf '%s\n' "## この effort を貫く命令・制約" \
        > "$WORKING_MEMORY_DIR/working-memory.sessA.consumed.md"
    run bash -c "printf '%s' '{\"session_id\":\"sessA\"}' | bash '$HOOKS/session-start-compact.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"carry-forward"* ]]
}

@test "session-start-compact: 外部化ファイル一覧に他セッションの working-memory.<sid>.md を出さない" {
    # 他セッション(sessB/sessC)の退避ファイルが同居している
    printf 'PAYLOAD_B\n' > "$WORKING_MEMORY_DIR/working-memory.sessB.md"
    printf 'PAYLOAD_C\n' > "$WORKING_MEMORY_DIR/working-memory.sessC.md"
    # session A 自身の退避ファイルも存在
    printf 'PAYLOAD_A\n' > "$WORKING_MEMORY_DIR/working-memory.sessA.md"
    run bash -c "printf '%s' '{\"session_id\":\"sessA\"}' | bash '$HOOKS/session-start-compact.sh'"
    [ "$status" -eq 0 ]
    # 自セッション(sessA)の md は一覧に出る
    [[ "$output" == *"working-memory.sessA.md"* ]]
    # 他セッション(sessB/sessC)の md は一覧に出さない（cross-session mis-restore の根絶）
    [[ "$output" != *"working-memory.sessB.md"* ]]
    [[ "$output" != *"working-memory.sessC.md"* ]]
}

@test "session-start-compact: consumed 分岐でも他セッションの working-memory.<sid>.md を leak しない" {
    # 自セッション(sessA)は consumed あり → carry-forward 分岐を取る
    printf '%s\n' "## この effort を貫く命令・制約" \
        > "$WORKING_MEMORY_DIR/working-memory.sessA.consumed.md"
    # 他セッション(sessB)の working が同居（consumed 無し＝従来 L71 ガードでは除外されない）
    printf 'PAYLOAD_B\n' > "$WORKING_MEMORY_DIR/working-memory.sessB.md"
    run bash -c "printf '%s' '{\"session_id\":\"sessA\"}' | bash '$HOOKS/session-start-compact.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"carry-forward"* ]]
    # 他セッション(sessB)の md は一覧に leak しない
    [[ "$output" != *"working-memory.sessB.md"* ]]
}

# =============================================================================
# hook-session-id.sh: stdin JSON からの session_id 抽出ヘルパー
# =============================================================================

@test "hook-session-id: stdin JSON の .session_id を返す" {
    run bash -c "printf '%s' '{\"session_id\":\"hx\",\"cwd\":\"/x\"}' | { source '$LIB/hook-session-id.sh'; hook_extract_session_id; }"
    [ "$status" -eq 0 ]
    [[ "$output" == "hx" ]]
}

@test "hook-session-id: session_id を含まない JSON は空を返す" {
    run bash -c "printf '%s' '{\"cwd\":\"/x\"}' | { source '$LIB/hook-session-id.sh'; hook_extract_session_id; }"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "hook-session-id: stdin が tty でないとき空入力でもブロックせず空を返す" {
    run bash -c "source '$LIB/hook-session-id.sh'; hook_extract_session_id < /dev/null"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
