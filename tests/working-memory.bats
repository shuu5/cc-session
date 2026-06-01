#!/usr/bin/env bats
# working-memory.bats — Working Memory 2節スキーマ SSOT + carry-forward の unit tests
# scripts/lib/working-memory.sh の emit_working_memory / extract_effort_directives を検証

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
WM_LIB="$SCRIPT_DIR/lib/working-memory.sh"

setup() {
    SANDBOX="$(mktemp -d)"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

@test "working-memory: emit は frontmatter + 2節見出しを生成する" {
    run bash -c "source '$WM_LIB' && emit_working_memory '2026-06-01T00:00:00Z' manual"
    [ "$status" -eq 0 ]
    [[ "$output" == *'trigger: manual'* ]]
    [[ "$output" == *'## 計画弧・次のステップ'* ]]
    [[ "$output" == *'## この effort を貫く命令・制約'* ]]
}

@test "working-memory: emit の trigger 引数が frontmatter に反映される" {
    run bash -c "source '$WM_LIB' && emit_working_memory '2026-06-01T00:00:00Z' auto_precompact"
    [ "$status" -eq 0 ]
    [[ "$output" == *'trigger: auto_precompact'* ]]
}

@test "working-memory: extract は命令節の項目のみ返す（コメント・空行・他節を除外）" {
    cat > "$SANDBOX/c.md" <<'EOF'
---
trigger: manual
---

## 計画弧・次のステップ
<!-- ephemeral -->
- 捨てられる計画

## この effort を貫く命令・制約
<!-- persistent-within-effort: [auto]/[confirm]/[hard候補] -->

- [auto] AAA
- [hard候補] BBB
EOF
    run bash -c "source '$WM_LIB' && extract_effort_directives '$SANDBOX/c.md'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'- [auto] AAA'* ]]
    [[ "$output" == *'- [hard候補] BBB'* ]]
    [[ "$output" != *'捨てられる計画'* ]]
    [[ "$output" != *'ephemeral'* ]]
    [[ "$output" != *'persistent-within-effort'* ]]
}

@test "working-memory: emit は consumed の命令節を carry-forward する" {
    cat > "$SANDBOX/consumed.md" <<'EOF'
## この effort を貫く命令・制約
<!-- c -->
- [confirm] CARRIED_DIRECTIVE
EOF
    run bash -c "source '$WM_LIB' && emit_working_memory '2026-06-01T00:00:00Z' manual '$SANDBOX/consumed.md'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'- [confirm] CARRIED_DIRECTIVE'* ]]
    [[ "$output" == *'機械引き継ぎ'* ]]
}

@test "working-memory: 旧3節スキーマ（重要なコンテキスト）をフォールバックで拾う" {
    cat > "$SANDBOX/old.md" <<'EOF'
## 現在のタスク
- x

## 重要なコンテキスト
- [auto] LEGACY_DIRECTIVE
EOF
    run bash -c "source '$WM_LIB' && extract_effort_directives '$SANDBOX/old.md'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'- [auto] LEGACY_DIRECTIVE'* ]]
}

@test "working-memory: 存在しないファイルは空出力・exit 0" {
    run bash -c "source '$WM_LIB' && extract_effort_directives '$SANDBOX/none.md'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "working-memory: 命令行に含まれる HTML コメントで命令を落とさない（awk 誤爆回帰）" {
    cat > "$SANDBOX/inline.md" <<'EOF'
## この effort を貫く命令・制約
- [auto] keep_A
- [auto] inline <!-- c --> keep_B
- [auto] stray <!-- no closer keep_C
- [auto] keep_D
EOF
    run bash -c "source '$WM_LIB' && extract_effort_directives '$SANDBOX/inline.md'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'keep_A'* ]]
    [[ "$output" == *'keep_B'* ]]
    [[ "$output" == *'keep_C'* ]]   # クローザ無し <!-- が後続項目を飲み込まない
    [[ "$output" == *'keep_D'* ]]
}

@test "working-memory: 複数行コメントのクローザと同一行にある命令を落とさない" {
    cat > "$SANDBOX/closer.md" <<'EOF'
## この effort を貫く命令・制約
<!-- 注釈
継続 --> [auto] CLOSER_LINE_DIRECTIVE
- [confirm] AFTER
EOF
    run bash -c "source '$WM_LIB' && extract_effort_directives '$SANDBOX/closer.md'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'CLOSER_LINE_DIRECTIVE'* ]]
    [[ "$output" == *'AFTER'* ]]
}

@test "working-memory: 1行に完結コメントが複数あっても間のテキストを食わない" {
    cat > "$SANDBOX/multi.md" <<'EOF'
## この effort を貫く命令・制約
- [auto] first <!--a--> MID_KEEP <!--b--> last
EOF
    run bash -c "source '$WM_LIB' && extract_effort_directives '$SANDBOX/multi.md'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'first'* ]]
    [[ "$output" == *'MID_KEEP'* ]]
    [[ "$output" == *'last'* ]]
}

@test "working-memory: 新節が在って空なら旧節へフォールバックしない（空尊重）" {
    cat > "$SANDBOX/empty-new.md" <<'EOF'
## この effort を貫く命令・制約

## 重要なコンテキスト
- [confirm] LEGACY_SHOULD_NOT_LEAK
EOF
    run bash -c "source '$WM_LIB' && extract_effort_directives '$SANDBOX/empty-new.md'"
    [ "$status" -eq 0 ]
    [[ "$output" != *'LEGACY_SHOULD_NOT_LEAK'* ]]
}

@test "working-memory: 多重 source ガードが効く（2回目は本体を実行しない）" {
    # 1回目 source 後に定数を上書き → 2回目 source。ガードが効けば本体（再代入）はスキップされ上書き値が残る
    run bash -c "source '$WM_LIB' && WM_HEADING_DIRECTIVES='SENTINEL' && source '$WM_LIB' && echo \"\$WM_HEADING_DIRECTIVES\""
    [ "$status" -eq 0 ]
    [[ "$output" == 'SENTINEL' ]]
}
