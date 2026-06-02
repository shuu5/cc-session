#!/usr/bin/env bats
# enforce-policy.bats — hard 強制 policy パーサ lib（scripts/lib/enforce-policy.sh）の unit tests
# health / 正規化 / gate マッチ / subject 抽出 / marker 導出（sha_keyed の fail-closed 含む）/
# marker 有効性・TTL / lib が marker を作らない回帰（C-4b）/ 内蔵 danger list の SSOT 同期 を検証

ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB="$ROOT_DIR/scripts/lib/enforce-policy.sh"
EXAMPLE="$ROOT_DIR/architecture/enforce-policy.example.json"

setup() {
    SANDBOX="$(mktemp -d)"
    export ENFORCE_POLICY_FILE="$SANDBOX/enforce-policy.json"
    export ENFORCE_MARKER_DIR="$SANDBOX/markers"
    export ENFORCE_SHA_TIMEOUT=5
    mkdir -p "$SANDBOX/bin"
    # gh スタブを最優先で解決させる（sha_keyed gate が実 gh を叩かないように隔離）
    export PATH="$SANDBOX/bin:$PATH"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

_use_example() { cp "$EXAMPLE" "$ENFORCE_POLICY_FILE"; }

_stub_gh() {  # $1 = stdout として返す文字列
    printf '#!/usr/bin/env bash\necho "%s"\n' "$1" > "$SANDBOX/bin/gh"
    chmod +x "$SANDBOX/bin/gh"
}

# ---------------------------------------------------------------------------
# ライフサイクル / health
# ---------------------------------------------------------------------------

@test "health: policy 不在は absent" {
    run bash -c "source '$LIB' && ep_policy_health"
    [ "$status" -eq 0 ]
    [[ "$output" == "absent" ]]
}

@test "health: 空ファイルは absent" {
    : > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "absent" ]]
}

@test "health: 正常な例 policy は active（shipped example が parse できる回帰）" {
    _use_example
    run bash -c "source '$LIB' && ep_policy_health"
    [ "$status" -eq 0 ]
    [[ "$output" == "active" ]]
}

@test "health: enforce!=true は off" {
    jq '.enforce=false' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "off" ]]
}

@test "health: 壊れた JSON は corrupt" {
    printf '{ this is not json' > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

@test "health: schema マジック不一致は corrupt" {
    jq '.schema="something/else"' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

@test "health: gate id に不正文字（大文字）は corrupt" {
    jq '.gates[0].id="PR_Merge"' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

@test "health: version > MAX は badversion" {
    jq '.version=99' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "badversion" ]]
}

@test "health: jq 不在は nojq（fail-closed トリガ）" {
    _use_example
    run bash -c "source '$LIB'; PATH=''; ep_policy_health"
    [[ "$output" == "nojq" ]]
}

@test "health: 多重 source ガードが効く" {
    run bash -c "source '$LIB' && ENFORCE_POLICY_VERSION_MAX=SENTINEL && source '$LIB' && echo \"\$ENFORCE_POLICY_VERSION_MAX\""
    [[ "$output" == "SENTINEL" ]]
}

# ---------------------------------------------------------------------------
# 正規化（誤爆対策・guard テンプレ踏襲）
# ---------------------------------------------------------------------------

@test "normalize: 連続空白・タブを単一スペースに圧縮" {
    run bash -c "source '$LIB' && ep_normalize 'git    push$(printf '\t')origin'"
    [[ "$output" == "git push origin" ]]
}

@test "normalize: # 以降のコメントを除去" {
    run bash -c "source '$LIB' && ep_normalize 'gh pr merge 3 # ship it'"
    [[ "$output" == "gh pr merge 3 " ]]
}

# ---------------------------------------------------------------------------
# gate マッチ（step2）
# ---------------------------------------------------------------------------

@test "match: 'gh pr merge 3' は pr-merge" {
    _use_example
    run bash -c "source '$LIB' && ep_match_gate 'gh pr merge 3'"
    [ "$status" -eq 0 ]
    [[ "$output" == "pr-merge" ]]
}

@test "match: 'git push origin main' は git-push" {
    _use_example
    run bash -c "source '$LIB' && ep_match_gate 'git push origin main'"
    [[ "$output" == "git-push" ]]
}

@test "match: 'terraform apply' は deploy" {
    _use_example
    run bash -c "source '$LIB' && ep_match_gate 'terraform apply'"
    [[ "$output" == "deploy" ]]
}

@test "match: 非 gate コマンドは不一致（exit 1・allow）" {
    _use_example
    run bash -c "source '$LIB' && ep_match_gate 'git status'"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "match: コメント内の gate 語は誤爆しない（正規化後不一致）" {
    _use_example
    run bash -c "source '$LIB' && n=\$(ep_normalize 'ls # gh pr merge 3'); ep_match_gate \"\$n\""
    [ "$status" -eq 1 ]
}

@test "match: 引用符内の gate 語は any_re アンカーで誤爆しない（echo \"gh pr merge 3\"）" {
    _use_example
    # gh の直前が \" のため any_re の (^| ) 境界に一致せず gate ヒットしない（誤爆保護）
    run bash -c "source '$LIB' && ep_match_gate 'echo \"gh pr merge 3\"'"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# subject 抽出 / marker base（外部コマンド無し）
# ---------------------------------------------------------------------------

@test "subject: 'gh pr merge 3 --squash' から 3 を抽出" {
    _use_example
    run bash -c "source '$LIB' && ep_extract_subject pr-merge 'gh pr merge 3 --squash'"
    [ "$status" -eq 0 ]
    [[ "$output" == "3" ]]
}

@test "subject: PR URL 形から番号を抽出（2nd パターン）" {
    _use_example
    run bash -c "source '$LIB' && ep_extract_subject pr-merge 'gh pr merge https://github.com/o/r/pull/7'"
    [[ "$output" == "7" ]]
}

@test "subject: deny フォールバックは exit 4（番号省略の 'gh pr merge'）" {
    _use_example
    run bash -c "source '$LIB' && ep_extract_subject pr-merge 'gh pr merge'"
    [ "$status" -eq 4 ]
}

@test "marker_base: token 戦略 'git push origin main' → git-push-push-main" {
    _use_example
    run bash -c "source '$LIB' && ep_marker_base git-push 'git push origin main'"
    [[ "$output" == "git-push-push-main" ]]
}

@test "marker_base: command-hash 戦略はコマンド差で異なる（再 gate）" {
    _use_example
    run bash -c "source '$LIB' && a=\$(ep_marker_base deploy 'deploy alpha'); b=\$(ep_marker_base deploy 'deploy beta'); [ \"\$a\" != \"\$b\" ] && echo differ"
    [[ "$output" == "differ" ]]
}

# ---------------------------------------------------------------------------
# SHA suffix / gh 呼び出し（block 経路限定・スタブ）
# ---------------------------------------------------------------------------

@test "sha_suffix: sha_keyed=false gate は空文字 + gh を呼ばない" {
    _use_example
    # gh が呼ばれたら sentinel を残すスタブ
    printf '#!/usr/bin/env bash\ntouch "%s/gh_called"\necho dead\n' "$SANDBOX" > "$SANDBOX/bin/gh"
    chmod +x "$SANDBOX/bin/gh"
    run bash -c "source '$LIB' && ep_marker_sha_suffix git-push main; echo \"rc=\$?\""
    [[ "$output" == "rc=0" ]]
    [ ! -e "$SANDBOX/gh_called" ]
}

@test "sha_suffix: sha_keyed=true ＋ 40hex → -sha-<先頭8>" {
    _use_example
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    run bash -c "source '$LIB' && ep_marker_sha_suffix pr-merge 3"
    [ "$status" -eq 0 ]
    [[ "$output" == "-sha-a1b2c3d4" ]]
}

@test "sha_suffix: gh が空出力 → exit 3（fail-closed）" {
    _use_example
    _stub_gh ""
    run bash -c "source '$LIB' && ep_marker_sha_suffix pr-merge 3"
    [ "$status" -eq 3 ]
}

@test "sha_suffix: gh が非0終了 → exit 3（command not found も同経路）" {
    _use_example
    printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gh"
    chmod +x "$SANDBOX/bin/gh"
    run bash -c "source '$LIB' && ep_marker_sha_suffix pr-merge 3"
    [ "$status" -eq 3 ]
}

@test "sha_suffix: validate_re 不一致（非 SHA 出力）→ exit 3" {
    _use_example
    _stub_gh "not-a-valid-sha"
    run bash -c "source '$LIB' && ep_marker_sha_suffix pr-merge 3"
    [ "$status" -eq 3 ]
}

@test "sha_suffix: timeout 到達 → exit 3" {
    _use_example
    printf '#!/usr/bin/env bash\nsleep 3\necho dead\n' > "$SANDBOX/bin/gh"
    chmod +x "$SANDBOX/bin/gh"
    run bash -c "export ENFORCE_SHA_TIMEOUT=1; source '$LIB' && ep_marker_sha_suffix pr-merge 3"
    [ "$status" -eq 3 ]
}

@test "sha_suffix: subject に不正文字（;rm 等）→ exit 3（argv injection 面の縮小）" {
    _use_example
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    run bash -c "source '$LIB' && ep_marker_sha_suffix pr-merge '3; rm -rf /'"
    [ "$status" -eq 3 ]
}

# ---------------------------------------------------------------------------
# marker 名 SSOT 一致（hook ↔ unlock helper のドリフト防止）
# ---------------------------------------------------------------------------

@test "marker_name: 決定論（同一入力 → 同名）＋ pr-merge 完全形" {
    _use_example
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    run bash -c "source '$LIB' && a=\$(ep_marker_name pr-merge 'gh pr merge 3'); b=\$(ep_marker_name pr-merge 'gh pr merge 3'); [ \"\$a\" = \"\$b\" ] && echo \"\$a\""
    [ "$status" -eq 0 ]
    [[ "$output" == "pr-merge-pr-3-sha-a1b2c3d4" ]]
}

@test "marker_name: head SHA が変われば marker 名が変わる（C-4a 自動再 gate）" {
    _use_example
    _stub_gh "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    run bash -c "source '$LIB' && ep_marker_name pr-merge 'gh pr merge 3'"
    local n1="$output"
    _stub_gh "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    run bash -c "source '$LIB' && ep_marker_name pr-merge 'gh pr merge 3'"
    [ "$n1" != "$output" ]
    [[ "$n1" == *"-sha-aaaaaaaa" ]]
    [[ "$output" == *"-sha-bbbbbbbb" ]]
}

@test "marker_name: subject deny は exit 4 を伝播（fail-closed）" {
    _use_example
    run bash -c "source '$LIB' && ep_marker_name pr-merge 'gh pr merge'"
    [ "$status" -eq 4 ]
}

@test "marker_name: SHA 導出失敗は exit 3 を伝播（fail-closed）" {
    _use_example
    _stub_gh ""
    run bash -c "source '$LIB' && ep_marker_name pr-merge 'gh pr merge 3'"
    [ "$status" -eq 3 ]
}

# ---------------------------------------------------------------------------
# marker 有効性 / TTL（step3）＋ lib が作らない回帰（C-4b）
# ---------------------------------------------------------------------------

@test "marker_valid: 不在 marker は exit 1" {
    _use_example
    run bash -c "source '$LIB' && ep_marker_valid git-push git-push-push-main"
    [ "$status" -eq 1 ]
}

@test "marker_valid: 存在 ＋ TTL 内は exit 0" {
    _use_example
    mkdir -p "$ENFORCE_MARKER_DIR"
    touch "$ENFORCE_MARKER_DIR/git-push-push-main"
    run bash -c "source '$LIB' && ep_marker_valid git-push git-push-push-main"
    [ "$status" -eq 0 ]
}

@test "marker_valid: 期限切れ（mtime を過去へ）は exit 1" {
    _use_example
    mkdir -p "$ENFORCE_MARKER_DIR"
    touch -d '2000-01-01' "$ENFORCE_MARKER_DIR/git-push-push-main"
    run bash -c "source '$LIB' && ep_marker_valid git-push git-push-push-main"
    [ "$status" -eq 1 ]
}

@test "marker_valid: TTL 無し（無期限）の gate は古い marker でも exit 0" {
    jq '.gates[1].marker_ttl_sec=null | .default_marker_ttl_sec=null' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    mkdir -p "$ENFORCE_MARKER_DIR"
    touch -d '2000-01-01' "$ENFORCE_MARKER_DIR/git-push-push-main"
    run bash -c "source '$LIB' && ep_marker_valid git-push git-push-push-main"
    [ "$status" -eq 0 ]
}

@test "C-4b 回帰: marker 判定・名前導出を経ても lib は marker を作らない" {
    _use_example
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    run bash -c "source '$LIB' && ep_marker_name pr-merge 'gh pr merge 3' >/dev/null; ep_marker_valid pr-merge whatever; echo done"
    [[ "$output" == *"done"* ]]
    # marker ディレクトリが空（または不在）であること
    [ ! -d "$ENFORCE_MARKER_DIR" ] || [ -z "$(ls -A "$ENFORCE_MARKER_DIR")" ]
}

# ---------------------------------------------------------------------------
# unlock コマンド / block メッセージ（step4）
# ---------------------------------------------------------------------------

@test "unlock_command: marker を touch する 1 行を返す" {
    _use_example
    run bash -c "source '$LIB' && ep_unlock_command pr-merge-pr-3-sha-a1b2c3d4"
    [[ "$output" == *"touch"* ]]
    [[ "$output" == *"pr-merge-pr-3-sha-a1b2c3d4"* ]]
    [[ "$output" == *"$ENFORCE_MARKER_DIR"* ]]
}

@test "block_message: 説明・unlock コマンド・自己認可不可の注記を含む" {
    _use_example
    _stub_gh "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    run bash -c "source '$LIB' && m=\$(ep_marker_name pr-merge 'gh pr merge 3'); ep_block_message pr-merge 'gh pr merge 3' \"\$m\""
    [[ "$output" == *"DENIED(enforce/pr-merge)"* ]]
    [[ "$output" == *"PR #3"* ]]          # unlock_hint の {subject} 展開
    [[ "$output" == *"touch"* ]]
    [[ "$output" == *"自己認可"* ]]
}

# ---------------------------------------------------------------------------
# 内蔵 danger list / fail-closed(C-6)
# ---------------------------------------------------------------------------

@test "builtin_danger: 'git push origin main' は一致（exit 0）" {
    run bash -c "source '$LIB' && ep_builtin_danger_match 'git push origin main'"
    [ "$status" -eq 0 ]
}

@test "builtin_danger: 'git status' は不一致（exit 1）" {
    run bash -c "source '$LIB' && ep_builtin_danger_match 'git status'"
    [ "$status" -eq 1 ]
}

@test "builtin_danger SSOT 同期: 例 policy の各 gate 代表コマンドが内蔵 danger list にも一致（W5 回帰）" {
    run bash -c "source '$LIB' && for c in 'gh pr merge 3' 'git push origin main' 'terraform apply' 'deploy'; do ep_builtin_danger_match \"\$c\" || { echo \"MISS: \$c\"; exit 1; }; done; echo allhit"
    [ "$status" -eq 0 ]
    [[ "$output" == "allhit" ]]
}
