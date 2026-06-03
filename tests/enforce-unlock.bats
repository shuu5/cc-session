#!/usr/bin/env bats
# enforce-unlock.bats — 生シェル unlock helper（scripts/enforce-unlock）の tests
# marker 作成・gate 取り違え防止・fail-closed（SHA 失敗/subject 不明では作らない）・
# そして「unlock した marker で hook が allow する」往復（hook↔helper の名前一致）を検証

ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
UNLOCK="$ROOT_DIR/scripts/enforce-unlock"
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
    cp "$EXAMPLE" "$ENFORCE_POLICY_FILE"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

_stub_gh() {
    printf '#!/usr/bin/env bash\necho "%s"\n' "$1" > "$SANDBOX/bin/gh"
    chmod +x "$SANDBOX/bin/gh"
}
_json() { printf '{"tool_input":{"command":"%s"}}' "$1"; }

@test "unlock: 引数不足は usage + exit 64" {
    run "$UNLOCK"
    [ "$status" -eq 64 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "unlock: gate 取り違え（コマンド不一致）は exit 65・marker 作らない" {
    run "$UNLOCK" pr-merge "git push origin main"
    [ "$status" -eq 65 ]
    [ ! -d "$ENFORCE_MARKER_DIR" ] || [ -z "$(ls -A "$ENFORCE_MARKER_DIR")" ]
}

@test "unlock: policy 不在では exit 66（認可対象なし）" {
    rm -f "$ENFORCE_POLICY_FILE"
    run "$UNLOCK" git-push "git push origin main"
    [ "$status" -eq 66 ]
}

@test "unlock: TTL 未指定 sha_keyed=false gate（corrupt）は exit 66 で拒否し marker を作らない（policy 修復を促す・ccs-5p4.1）" {
    jq 'del(.gates[1].marker_ttl_sec) | .default_marker_ttl_sec=null' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run "$UNLOCK" git-push "git push origin main"
    [ "$status" -eq 66 ]
    [ ! -d "$ENFORCE_MARKER_DIR" ] || [ -z "$(ls -A "$ENFORCE_MARKER_DIR")" ]
}

@test "unlock: git-push（command-hash）は marker を作成し exit 0" {
    local marker
    marker=$(bash -c "source '$LIB' && ep_marker_name git-push 'git push origin main'")
    run "$UNLOCK" git-push "git push origin main"
    [ "$status" -eq 0 ]
    [ -e "$ENFORCE_MARKER_DIR/$marker" ]
    [[ "$output" == *"認可しました"* ]]
}

@test "unlock: pr-merge（sha_keyed=true）は SHA 込み marker を作成し exit 0" {
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    run "$UNLOCK" pr-merge "gh pr merge 3"
    [ "$status" -eq 0 ]
    local marker; marker=$(bash -c "source '$LIB' && ep_marker_name pr-merge 'gh pr merge 3'")
    [[ "$marker" == pr-merge-pr-3-sha-a1b2c3d4-* ]]
    [ -e "$ENFORCE_MARKER_DIR/$marker" ]
}

@test "unlock: --admin は -flag-admin 込み marker を作成（helper↔hook 名一致・ccs-5p4.7）" {
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    run "$UNLOCK" pr-merge "gh pr merge 3 --admin"
    [ "$status" -eq 0 ]
    local marker; marker=$(bash -c "source '$LIB' && ep_marker_name pr-merge 'gh pr merge 3 --admin'")
    [[ "$marker" == pr-merge-pr-3-flag-admin-sha-a1b2c3d4-* ]]
    [ -e "$ENFORCE_MARKER_DIR/$marker" ]
}

@test "unlock: --squash は -flag- を付けず admin marker を作らない（認可スコープ分離）" {
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    run "$UNLOCK" pr-merge "gh pr merge 3 --squash"
    [ "$status" -eq 0 ]
    local sq adm
    sq=$(bash -c "source '$LIB' && ep_marker_name pr-merge 'gh pr merge 3 --squash'")
    adm=$(bash -c "source '$LIB' && ep_marker_name pr-merge 'gh pr merge 3 --admin'")
    [[ "$sq" == pr-merge-pr-3-sha-a1b2c3d4-* ]]    # squash は -flag- 無し
    [ -e "$ENFORCE_MARKER_DIR/$sq" ]               # squash marker は作られた
    [ ! -e "$ENFORCE_MARKER_DIR/$adm" ]            # admin marker は作られていない（scope 分離）
}

@test "round-trip: --squash unlock 後も --admin は再 block（フラグ scope 分離往復）" {
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    run "$UNLOCK" pr-merge "gh pr merge 3 --squash"
    [ "$status" -eq 0 ]
    run bash -c "printf '%s' '$(_json "gh pr merge 3 --admin")' | '$HOOK'"
    [ "$status" -eq 2 ]
}

@test "round-trip: --squash unlock 後も語末メタ文字終端の --admin は再 block（CRIT-1 e2e・ccs-5p4.7 review）" {
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    run "$UNLOCK" pr-merge "gh pr merge 3 --squash"
    [ "$status" -eq 0 ]
    for c in 'gh pr merge 3 --admin;' 'gh pr merge 3 --admin|cat' 'gh pr merge 3 --admin)'; do
        run bash -c "printf '%s' '$(_json "$c")' | '$HOOK'"
        [ "$status" -eq 2 ]
    done
}

@test "unlock: subject 不明（番号省略）は exit 4・marker 作らない" {
    run "$UNLOCK" pr-merge "gh pr merge"
    [ "$status" -eq 4 ]
    [ ! -d "$ENFORCE_MARKER_DIR" ] || [ -z "$(ls -A "$ENFORCE_MARKER_DIR")" ]
}

@test "unlock: SHA 導出失敗（gh 空）は exit 3・marker 作らない" {
    _stub_gh ""
    run "$UNLOCK" pr-merge "gh pr merge 3"
    [ "$status" -eq 3 ]
    [ ! -d "$ENFORCE_MARKER_DIR" ] || [ -z "$(ls -A "$ENFORCE_MARKER_DIR")" ]
}

# ---- 往復: unlock 後に hook が allow する（helper↔hook の marker 名一致を担保） ----

@test "round-trip: git-push を unlock すると hook が allow する" {
    # まず block されることを確認
    run bash -c "printf '%s' '$(_json "git push origin main")' | '$HOOK'"
    [ "$status" -eq 2 ]
    # 人間が unlock
    run "$UNLOCK" git-push "git push origin main"
    [ "$status" -eq 0 ]
    # 同コマンドが allow される
    run bash -c "printf '%s' '$(_json "git push origin main")' | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "round-trip: pr-merge を unlock すると hook が allow する（SHA 一致）" {
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    run bash -c "printf '%s' '$(_json "gh pr merge 3")' | '$HOOK'"
    [ "$status" -eq 2 ]
    run "$UNLOCK" pr-merge "gh pr merge 3"
    [ "$status" -eq 0 ]
    run bash -c "printf '%s' '$(_json "gh pr merge 3")' | '$HOOK'"
    [ "$status" -eq 0 ]
}

@test "round-trip: head SHA が進むと unlock 済みでも再 block（C-4a 自動失効）" {
    _stub_gh "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    run "$UNLOCK" pr-merge "gh pr merge 3"
    [ "$status" -eq 0 ]
    # head SHA が進んだ状況をスタブ差し替えで再現
    _stub_gh "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    run bash -c "printf '%s' '$(_json "gh pr merge 3")' | '$HOOK'"
    [ "$status" -eq 2 ]
}
