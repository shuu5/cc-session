#!/usr/bin/env bats
# test_1454_llm_indicators.bats — Issue #1454: LLM_INDICATORS に 11 件追加
# RED テスト: 実装前は fail する。実装後 GREEN になる。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
LLM_INDICATORS_LIB="$SCRIPT_DIR/lib/llm-indicators.sh"
export LLM_INDICATORS_LIB

setup() {
    TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
    [[ -n "${TMPDIR_TEST:-}" && -d "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# AC1: 9 件が llm-indicators.sh に存在すること（Cooked は既存、Sautéed/Worked は IDLE）
# ---------------------------------------------------------------------------

@test "ac1(#1454): Newspapering が LLM_INDICATORS に含まれること (RED)" {
    grep -q "Newspapering" "$LLM_INDICATORS_LIB"
}

@test "ac1(#1454): Fiddle-faddling が LLM_INDICATORS に含まれること (RED)" {
    grep -q "Fiddle.faddling\|Fiddle-faddling" "$LLM_INDICATORS_LIB"
}

@test "ac1(#1454): Levitating が LLM_INDICATORS に含まれること (RED)" {
    grep -q "Levitating" "$LLM_INDICATORS_LIB"
}

@test "ac1(#1454): Cogitating が LLM_INDICATORS に含まれること (RED)" {
    # "Cogitated" は既存。"Cogitating" は未登録
    grep -q "Cogitating" "$LLM_INDICATORS_LIB"
}

@test "ac1(#1454): Bloviating が LLM_INDICATORS に含まれること (RED)" {
    grep -q "Bloviating" "$LLM_INDICATORS_LIB"
}

@test "ac1(#1454): Vibing が LLM_INDICATORS に含まれること (RED)" {
    grep -q "Vibing" "$LLM_INDICATORS_LIB"
}

@test "ac1(#1454): Puttering が LLM_INDICATORS に含まれること (RED)" {
    grep -q "Puttering" "$LLM_INDICATORS_LIB"
}

@test "ac1(#1454): Zesting が LLM_INDICATORS に含まれること (RED)" {
    grep -q "Zesting" "$LLM_INDICATORS_LIB"
}

@test "ac1(#1454): Sautéing が LLM_INDICATORS に含まれること (RED)" {
    # RED: 現在 LLM_INDICATORS に "Sautéing" の明示登録なし（"Saut.*ed" は past tense で IDLE 対象）
    # 実装後: "Sautéing" を明示追加して non-ASCII の grep -qiE 問題を回避
    grep -q "Sautéing\|Saut.*ing" "$LLM_INDICATORS_LIB"
}

# ---------------------------------------------------------------------------
# AC2: detect_thinking() が各 indicator を "X Nm" format (サフィックスなし) で検知すること
# 一般 regex [A-Z][a-z]+(in'|ing)(…| for [0-9]| \([0-9]) はサフィックス必須のため
# 以下のフォーマットは現在 NO MATCH → RED
# ---------------------------------------------------------------------------

@test "ac2(#1454): detect_thinking が 'Newspapering 5m' を検知すること (RED)" {
    run bash <<'EOF'
source "$LLM_INDICATORS_LIB"
pane_text="Newspapering 5m"
detected=""
for ind in "${LLM_INDICATORS[@]}"; do
    if echo "$pane_text" | grep -qiE "$ind" 2>/dev/null; then
        detected="$ind"
        break
    fi
done
[[ -n "$detected" ]] && echo "PASS: $detected" || { echo "FAIL: Newspapering 5m not detected"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac2(#1454): detect_thinking が 'Fiddle-faddling 5m' を検知すること (RED)" {
    # Wave 50 cycle #1 実測フォーマット
    run bash <<'EOF'
source "$LLM_INDICATORS_LIB"
pane_text="Fiddle-faddling 5m"
detected=""
for ind in "${LLM_INDICATORS[@]}"; do
    if echo "$pane_text" | grep -qiE "$ind" 2>/dev/null; then
        detected="$ind"
        break
    fi
done
[[ -n "$detected" ]] && echo "PASS: $detected" || { echo "FAIL: Fiddle-faddling 5m not detected"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac2(#1454): detect_thinking が 'Levitating 5m' を検知すること (RED)" {
    run bash <<'EOF'
source "$LLM_INDICATORS_LIB"
pane_text="Levitating 5m"
detected=""
for ind in "${LLM_INDICATORS[@]}"; do
    if echo "$pane_text" | grep -qiE "$ind" 2>/dev/null; then
        detected="$ind"
        break
    fi
done
[[ -n "$detected" ]] && echo "PASS: $detected" || { echo "FAIL: Levitating 5m not detected"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac2(#1454): detect_thinking が 'Cogitating 4m' を検知すること (RED)" {
    run bash <<'EOF'
source "$LLM_INDICATORS_LIB"
pane_text="Cogitating 4m"
detected=""
for ind in "${LLM_INDICATORS[@]}"; do
    if echo "$pane_text" | grep -qiE "$ind" 2>/dev/null; then
        detected="$ind"
        break
    fi
done
[[ -n "$detected" ]] && echo "PASS: $detected" || { echo "FAIL: Cogitating 4m not detected"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac2(#1454): detect_thinking が 'Bloviating 2m' を検知すること (RED)" {
    run bash <<'EOF'
source "$LLM_INDICATORS_LIB"
pane_text="Bloviating 2m"
detected=""
for ind in "${LLM_INDICATORS[@]}"; do
    if echo "$pane_text" | grep -qiE "$ind" 2>/dev/null; then
        detected="$ind"
        break
    fi
done
[[ -n "$detected" ]] && echo "PASS: $detected" || { echo "FAIL: Bloviating 2m not detected"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac2(#1454): detect_thinking が 'Vibing 10m' を検知すること (RED)" {
    run bash <<'EOF'
source "$LLM_INDICATORS_LIB"
pane_text="Vibing 10m"
detected=""
for ind in "${LLM_INDICATORS[@]}"; do
    if echo "$pane_text" | grep -qiE "$ind" 2>/dev/null; then
        detected="$ind"
        break
    fi
done
[[ -n "$detected" ]] && echo "PASS: $detected" || { echo "FAIL: Vibing 10m not detected"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac2(#1454): detect_thinking が 'Puttering 4m' を検知すること (RED)" {
    run bash <<'EOF'
source "$LLM_INDICATORS_LIB"
pane_text="Puttering 4m"
detected=""
for ind in "${LLM_INDICATORS[@]}"; do
    if echo "$pane_text" | grep -qiE "$ind" 2>/dev/null; then
        detected="$ind"
        break
    fi
done
[[ -n "$detected" ]] && echo "PASS: $detected" || { echo "FAIL: Puttering 4m not detected"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac2(#1454): detect_thinking が 'Zesting 6m' を検知すること (RED)" {
    run bash <<'EOF'
source "$LLM_INDICATORS_LIB"
pane_text="Zesting 6m"
detected=""
for ind in "${LLM_INDICATORS[@]}"; do
    if echo "$pane_text" | grep -qiE "$ind" 2>/dev/null; then
        detected="$ind"
        break
    fi
done
[[ -n "$detected" ]] && echo "PASS: $detected" || { echo "FAIL: Zesting 6m not detected"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac2(#1454): detect_thinking が 'Sautéing 5m' を検知すること (RED)" {
    # RED: 非 ASCII é を含む → grep -qiE の [a-z]+ がマッチしない（一般 regex 不可）
    # 実装後: "Sautéing" を明示登録 → grep -qiE "Sautéing" でマッチ
    run bash <<'EOF'
source "$LLM_INDICATORS_LIB"
pane_text="Sautéing 5m"
detected=""
for ind in "${LLM_INDICATORS[@]}"; do
    if echo "$pane_text" | grep -qiE "$ind" 2>/dev/null; then
        detected="$ind"
        break
    fi
done
[[ -n "$detected" ]] && echo "PASS: $detected" || { echo "FAIL: Sautéing 5m not detected"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# AC3: Wave 50/51 capture 再現 sample で STAGNATE-300 誤発火が解消
# ---------------------------------------------------------------------------

@test "ac3(#1454): Wave 50 cycle #1 'Fiddle-faddling 5m' pane で STAGNATE を抑止すること (RED)" {
    # Wave 50 cycle #1 で実測: Fiddle-faddling 5m 表示中に STAGNATE-300 誤発火 30+ 件
    run bash <<'EOF'
source "$LLM_INDICATORS_LIB"
pane_text="$(printf "> Worker に指示中...\n  ✓ setup 完了\nFiddle-faddling 5m")"
detected=""
for ind in "${LLM_INDICATORS[@]}"; do
    if echo "$pane_text" | grep -qiE "$ind" 2>/dev/null; then
        detected="$ind"
        break
    fi
done
[[ -n "$detected" ]] && echo "PASS: LLM active ($detected) → STAGNATE suppressed" \
    || { echo "FAIL: not detected → STAGNATE-300 would misfire"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac3(#1454): Wave 50 cycle #4 'Cogitating 4m' pane で STAGNATE を抑止すること (RED)" {
    run bash <<'EOF'
source "$LLM_INDICATORS_LIB"
pane_text="$(printf "> Opus 4.7 起動\nCogitating 4m")"
detected=""
for ind in "${LLM_INDICATORS[@]}"; do
    if echo "$pane_text" | grep -qiE "$ind" 2>/dev/null; then
        detected="$ind"
        break
    fi
done
[[ -n "$detected" ]] && echo "PASS: $detected" || { echo "FAIL: Cogitating 4m not detected"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# AC4: past tense filter 整合性確認
# ---------------------------------------------------------------------------

@test "ac4(#1454): 'Sautéed for 1m' は detect_thinking が空（IDLE）を返すこと (RED)" {
    # RED: 現在 "Saut.*ed" パターンが LLM_INDICATORS にあるため THINKING と誤判定
    # 実装後: "Saut.*ed" を削除 → IDLE 判定に変わる
    run bash <<'EOF'
source "$LLM_INDICATORS_LIB"
pane_text="Sautéed for 1m"
detected=""
for ind in "${LLM_INDICATORS[@]}"; do
    if echo "$pane_text" | grep -qiE "$ind" 2>/dev/null; then
        detected="$ind"
        break
    fi
done
if [[ -z "$detected" ]]; then
    echo "PASS: Sautéed (past tense) → IDLE"
else
    echo "FAIL: matched '$detected' → wrongly THINKING (should be IDLE)"
    exit 1
fi
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac4(#1454): 'Sautéing for 1m' は detect_thinking が非空（THINKING）を返すこと (RED)" {
    # RED: 非 ASCII é を含む → 一般 regex [A-Z][a-z]+(in'|ing) がマッチしない
    # 実装後: "Sautéing" 明示登録 → THINKING 判定
    run bash <<'EOF'
source "$LLM_INDICATORS_LIB"
pane_text="Sautéing for 1m"
detected=""
for ind in "${LLM_INDICATORS[@]}"; do
    if echo "$pane_text" | grep -qiE "$ind" 2>/dev/null; then
        detected="$ind"
        break
    fi
done
[[ -n "$detected" ]] && echo "PASS: Sautéing → THINKING ($detected)" \
    || { echo "FAIL: Sautéing not detected → wrongly IDLE"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac4(#1454): 'Worked for 2m' は detect_thinking が空（IDLE）を返すこと (regression guard)" {
    # 現状: "Worked" は LLM_INDICATORS に未登録 → 正しく IDLE
    # regression ガード: "Worked" を誤って追加しないことを確認
    run bash <<'EOF'
source "$LLM_INDICATORS_LIB"
pane_text="Worked for 2m"
detected=""
for ind in "${LLM_INDICATORS[@]}"; do
    if echo "$pane_text" | grep -qiE "$ind" 2>/dev/null; then
        detected="$ind"
        break
    fi
done
if [[ -z "$detected" ]]; then
    echo "PASS: Worked (past tense) → IDLE"
else
    echo "FAIL: matched '$detected' → Worked should be IDLE not THINKING"
    exit 1
fi
EOF
    [[ "$status" -eq 0 ]]
}
