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
    # 主提示: 貼りやすい 1 行 helper（ccs-cym）
    [[ "$output" == *"/scripts/enforce-unlock pr-merge"* ]]
    [[ "$output" == *"'gh pr merge 3'"* ]]
    # フォールバックの生 touch も併記
    [[ "$output" == *"touch"* ]]
}

# 危険フラグ keying e2e（ccs-5p4.7）: --squash の marker では素の --admin を allow しない
@test "hook: --squash を unlock しても素の --admin は別 marker で block（認可スコープ分離 e2e）" {
    _use_example
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    # 人間が --squash を unlock（marker 作成）
    local marker
    marker=$(bash -c "source '$LIB' && ep_marker_name pr-merge 'gh pr merge 3 --squash'")
    mkdir -p "$ENFORCE_MARKER_DIR"
    touch "$ENFORCE_MARKER_DIR/$marker"
    # 同 PR・同 head の --squash は allow
    run bash -c "printf '%s' '$(_json "gh pr merge 3 --squash")' | '$HOOK'"
    [ "$status" -eq 0 ]
    # しかし --admin（レビュー要件 bypass）は別 marker 不在で block
    run bash -c "printf '%s' '$(_json "gh pr merge 3 --admin")' | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DENIED(enforce/pr-merge)"* ]]
}

@test "hook: --admin を unlock した後は --admin が allow（フラグ込み marker 往復）" {
    _use_example
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    local marker
    marker=$(bash -c "source '$LIB' && ep_marker_name pr-merge 'gh pr merge 3 --admin'")
    mkdir -p "$ENFORCE_MARKER_DIR"
    touch "$ENFORCE_MARKER_DIR/$marker"
    run bash -c "printf '%s' '$(_json "gh pr merge 3 --admin")' | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "hook: --squash unlock 後も語末メタ文字終端の --admin は block（CRIT-1 e2e・ccs-5p4.7 review）" {
    _use_example
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    # --squash の marker のみ作成（base＝pr-merge-pr-3・risk 無し）
    local marker
    marker=$(bash -c "source '$LIB' && ep_marker_name pr-merge 'gh pr merge 3 --squash'")
    mkdir -p "$ENFORCE_MARKER_DIR"
    touch "$ENFORCE_MARKER_DIR/$marker"
    # 素の --admin に加え、語末メタ文字終端の --admin も別 marker 不在で block されること
    for c in 'gh pr merge 3 --admin' 'gh pr merge 3 --admin;' 'gh pr merge 3 --admin|cat' 'gh pr merge 3 --admin&' 'gh pr merge 3 --admin>/dev/null' 'gh pr merge 3 --admin)'; do
        run bash -c "printf '%s' '$(_json "$c")' | '$HOOK'"
        [ "$status" -eq 2 ]
    done
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

@test "hook: TTL 未指定 sha_keyed=false gate の policy は corrupt→fail-closed scoped で danger を block（ccs-5p4.1 e2e）" {
    jq 'del(.gates[1].marker_ttl_sec) | .default_marker_ttl_sec=null' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "printf '%s' '$(_json "git push origin main")' | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"fail-closed"* ]]
}

@test "hook: sha_keyed=\"true<TAB>\"・TTL 欠落 gate は corrupt→block（health↔runtime 乖離による恒久 unlock の回帰・ccs-5p4.1）" {
    # fix 前: health=active かつ runtime は固定 marker（sha 無し・無期限）→ 古い marker で terraform apply が allow。
    # fix 後: health=corrupt→fail-closed scoped で terraform（builtin danger）を block。
    jq '.gates[2].key.sha_keyed="true\t" | del(.gates[2].marker_ttl_sec) | .default_marker_ttl_sec=null' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    local marker
    marker=$(bash -c "source '$LIB' && ep_marker_name deploy 'terraform apply'")
    mkdir -p "$ENFORCE_MARKER_DIR"
    touch -d '2000-01-01' "$ENFORCE_MARKER_DIR/$marker"
    run bash -c "printf '%s' '$(_json "terraform apply")' | '$HOOK'"
    [ "$status" -eq 2 ]
}

@test "hook: 壊れた .key gate が前順でも後順 no-TTL gate を corrupt→block（第2ラウンド fail-open の E2E 回帰・ccs-5p4.1）" {
    # gates[0] 壊れ .key（前順）+ gates[1] git-push no-TTL + 26年前の固定 marker。fix 前は jq 沈黙 abort で
    # health=active→古い marker で allow。fix 後は corrupt→fail-closed scoped で git push を block。
    jq '.gates[0].key="x" | del(.gates[1].marker_ttl_sec) | .default_marker_ttl_sec=null' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    local marker
    marker=$(bash -c "source '$LIB' && ep_marker_name git-push 'git push origin main'")
    mkdir -p "$ENFORCE_MARKER_DIR"
    touch -d '2000-01-01' "$ENFORCE_MARKER_DIR/$marker"
    run bash -c "printf '%s' '$(_json "git push origin main")' | '$HOOK'"
    [ "$status" -eq 2 ]
}

@test "hook: .match.any_re=object の gate は corrupt→block（gate 沈黙不発による fail-open の E2E 回帰・ccs-5p4.6）" {
    # fix 前: health=active かつ deploy の any_re が object の値へ黙改変され terraform apply に非マッチ→ALLOW。
    # fix 後: health=corrupt→fail-closed scoped で terraform（builtin danger）を block。
    jq '.gates[2].match.any_re={"k":"NONMATCH"}' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "printf '%s' '$(_json "terraform apply -auto-approve")' | '$HOOK'"
    [ "$status" -eq 2 ]
}

# dup-id leak e2e（ccs-5p4.8）: 同一 id・both sha_keyed の dup gate では良性 unlock が危険操作を認可しない
@test "hook: dup gate-id（both sha_keyed）で危険 --admin は block（dup-id leak を fail-closed 化・ccs-5p4.8）" {
    # fix 前: health=active のまま良性 --squash の unlock marker を危険 --admin が同一 marker で流用し exit 0。
    # fix 後: id 一意性検証で health=corrupt → step5 fail-closed scoped → builtin danger（gh pr merge）で block。
    cat > "$ENFORCE_POLICY_FILE" <<'JSON'
{ "schema":"cc-session/enforce-policy","version":1,"enforce":true,"gates":[
  {"id":"pr-merge","match":{"any_re":["gh +pr +merge +[0-9]+ +--squash"]},
   "key":{"strategy":"token","subject_prefix":"pr-","subject_re":["pr +merge +([0-9]+)"],"sha_keyed":true,"sha_cmd":["echo","DEADBEEF"],"sha_len":8},"marker_ttl_sec":3600},
  {"id":"pr-merge","match":{"any_re":["gh +pr +merge +[0-9]+ +--admin"]},
   "key":{"sha_keyed":true,"sha_cmd":["echo","DEADBEEF"],"sha_len":8}}
]}
JSON
    # 良性 --squash の unlock は corrupt 化により拒否される（marker を作れない＝二重防御）
    run "$ROOT_DIR/scripts/enforce-unlock" pr-merge "gh pr merge 7 --squash"
    [ "$status" -ne 0 ]
    # 危険 --admin は fail-closed scoped で block（exit 2）
    run bash -c "printf '%s' '$(_json "gh pr merge 7 --admin")' | '$HOOK'"
    [ "$status" -eq 2 ]
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
