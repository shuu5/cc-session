#!/usr/bin/env bats
# pretooluse-enforce.bats — PreToolUse(Bash) hook（scripts/hooks/pretooluse-enforce.sh）の統合 tests
# 5 ステップ判定フロー（opt-in no-op / gate / marker / fail-closed scoped / 緊急 bypass）を
# 実際の hook 入力（stdin JSON）で検証。hook ↔ lib の marker 名一致もここで担保。

ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOK="$ROOT_DIR/scripts/hooks/pretooluse-enforce.sh"
LIB="$ROOT_DIR/scripts/lib/enforce-policy.sh"
EXAMPLE="$ROOT_DIR/architecture/enforce-policy.example.json"

setup() {
    SANDBOX="$(mktemp -d)"
    export ENFORCE_POLICY_FILE="$SANDBOX/enforce-policy.json"
    export ENFORCE_MARKER_DIR="$SANDBOX/markers"
    export ENFORCE_SHA_TIMEOUT=5
    mkdir -p "$SANDBOX/bin"
    export PATH="$SANDBOX/bin:$PATH"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

_use_example() { cp "$EXAMPLE" "$ENFORCE_POLICY_FILE"; }
_stub_gh() {
    printf '#!/usr/bin/env bash\necho "%s"\n' "$1" > "$SANDBOX/bin/gh"
    chmod +x "$SANDBOX/bin/gh"
}
# JSON 入力を作る（実 hook 入力形）
_json() { printf '{"tool_input":{"command":"%s"}}' "$1"; }

# ---------------------------------------------------------------------------
# step1: opt-in no-op
# ---------------------------------------------------------------------------

@test "hook: policy 不在なら危険コマンドでも allow（exit 0・no-op opt-in）" {
    run bash -c "printf '%s' '$(_json "gh pr merge 3")' | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "hook: enforce:false なら allow（exit 0）" {
    jq '.enforce=false' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "printf '%s' '$(_json "gh pr merge 3")' | '$HOOK'"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# step2: gate 不一致 → allow
# ---------------------------------------------------------------------------

@test "hook: active policy でも非 gate コマンドは allow" {
    _use_example
    run bash -c "printf '%s' '$(_json "git status")' | '$HOOK'"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# step4 → step3: block → unlock → allow（sha_keyed gate / pr-merge）
# ---------------------------------------------------------------------------

@test "hook: marker 不在の 'gh pr merge 3' は block（exit 2・unlock 案内）" {
    _use_example
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    run bash -c "printf '%s' '$(_json "gh pr merge 3")' | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DENIED(enforce/pr-merge)"* ]]
    [[ "$output" == *"touch"* ]]
}

@test "hook: 正しい marker を生シェル相当で作成後は allow（hook↔lib 名一致）" {
    _use_example
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    # lib で算出した同名 marker を人間の生シェル相当で touch
    local marker
    marker=$(bash -c "source '$LIB' && ep_marker_name pr-merge 'gh pr merge 3'")
    mkdir -p "$ENFORCE_MARKER_DIR"
    touch "$ENFORCE_MARKER_DIR/$marker"
    run bash -c "printf '%s' '$(_json "gh pr merge 3")' | '$HOOK'"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# step4 → step3: block → unlock → allow（sha_keyed=false gate / git-push）
# ---------------------------------------------------------------------------

@test "hook: marker 不在の 'git push origin main' は block（gh 非依存）" {
    _use_example
    run bash -c "printf '%s' '$(_json "git push origin main")' | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DENIED(enforce/git-push)"* ]]
}

@test "hook: git-push の marker 作成後は allow" {
    _use_example
    # git-push は command-hash 戦略のため marker 名を lib から導出して touch（hook↔lib 一致）
    local marker
    marker=$(bash -c "source '$LIB' && ep_marker_name git-push 'git push origin main'")
    mkdir -p "$ENFORCE_MARKER_DIR"
    touch "$ENFORCE_MARKER_DIR/$marker"
    run bash -c "printf '%s' '$(_json "git push origin main")' | '$HOOK'"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# marker 名導出の fail-closed（subject deny / SHA 失敗）
# ---------------------------------------------------------------------------

@test "hook: 番号省略 'gh pr merge' は subject 不明で block（fail-closed exit 2）" {
    _use_example
    run bash -c "printf '%s' '$(_json "gh pr merge")' | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"特定できません"* ]]
}

@test "hook: gh が SHA を返せない（空）と block（fail-closed exit 2）" {
    _use_example
    _stub_gh ""
    run bash -c "printf '%s' '$(_json "gh pr merge 3")' | '$HOOK'"
    [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# step5: fail-closed (scoped)
# ---------------------------------------------------------------------------

@test "hook: policy 破損 ＋ danger コマンドは block（fail-closed scoped exit 2）" {
    printf '{ broken json' > "$ENFORCE_POLICY_FILE"
    run bash -c "printf '%s' '$(_json "git push origin main")' | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"fail-closed"* ]]
}

@test "hook: policy 破損 ＋ 無害コマンドは allow（scoped＝danger だけ止める）" {
    printf '{ broken json' > "$ENFORCE_POLICY_FILE"
    run bash -c "printf '%s' '$(_json "ls -la")' | '$HOOK'"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 緊急 bypass（C-7）
# ---------------------------------------------------------------------------

@test "hook: SESSION_ENFORCE_OFF=1 なら危険コマンドでも allow" {
    _use_example
    run bash -c "export SESSION_ENFORCE_OFF=1; printf '%s' '$(_json "gh pr merge 3")' | '$HOOK'"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 入力フォールバック（jq でコマンドが取れない生入力でも危険語は止める）
# ---------------------------------------------------------------------------

@test "hook: 生コマンド入力（非JSON）でも gate 評価される" {
    _use_example
    run bash -c "printf '%s' 'git push origin main' | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"git-push"* ]]
}

@test "hook: クォート難読化 g'i't push を de-obfuscate して block（end-to-end）" {
    _use_example
    # JSON 内のクォートを避けるため生入力で渡す
    run bash -c "printf '%s' \"g'i't push origin main\" | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"git-push"* ]]
}

@test "hook: 無効 ERE 混入 policy は corrupt→fail-closed scoped で danger を block（end-to-end）" {
    jq '.gates[2].match.any_re=["*terraform"]' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "printf '%s' '$(_json "terraform apply -auto-approve")' | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"fail-closed"* ]]
}

# ---------------------------------------------------------------------------
# hooks.json 登録（C-8・P2-T3 回帰）
# ---------------------------------------------------------------------------

@test "registration: hooks.json が PreToolUse:Bash に enforce hook を登録している" {
    run jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[].command' "$ROOT_DIR/hooks/hooks.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pretooluse-enforce.sh"* ]]
    [[ "$output" == *'${CLAUDE_PLUGIN_ROOT}'* ]]
}
