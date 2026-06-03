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

@test "normalize: コメント(#)は保持する（除去すると # 1 文字で全 gate を bypass できるため）" {
    run bash -c "source '$LIB' && ep_normalize 'gh pr merge 3 # ship it'"
    [[ "$output" == "gh pr merge 3 # ship it" ]]
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

@test "match: コメント内/引用符内の gate 語は安全側で over-block（# bypass 封じの対価）" {
    # コメントを保持してマッチするので `ls # gh pr merge 3` も gate ヒットする（過剰 block＝安全側）。
    # これにより `echo "#" && git push` のような # bypass を封じている（under-block より安全）。
    _use_example
    run bash -c "source '$LIB' && ep_match_gate 'ls # gh pr merge 3'"
    [ "$status" -eq 0 ]
    [[ "$output" == "pr-merge" ]]
}

@test "bypass 封じ: '# 以降' に隠した gate 語も検出する（# の 1 文字回避を防ぐ）" {
    _use_example
    # 改行を空白化しても # 以降を落とさないので、2 つ目以降のコマンドの gate 語も捕捉される
    run bash -c "source '$LIB' && ep_match_gate 'echo hi # x git push origin main'"
    [ "$status" -eq 0 ]
    [[ "$output" == "git-push" ]]
}

@test "match: 絶対パス・git -C・引用符ラップでも gate を外さない（C-3 強化境界）" {
    _use_example
    run bash -c "source '$LIB' && ep_match_gate '/usr/bin/gh pr merge 3'"
    [[ "$output" == "pr-merge" ]]
    run bash -c "source '$LIB' && ep_match_gate 'git -C /repo push origin main'"
    [[ "$output" == "git-push" ]]
    run bash -c "source '$LIB' && ep_match_gate \"bash -c 'terraform apply'\""
    [[ "$output" == "deploy" ]]
}

@test "match: 裸 deploy トークンは誤爆させない（git commit -m deploy は gate 不一致）" {
    _use_example
    run bash -c "source '$LIB' && ep_match_gate 'git commit -m deploy'"
    [ "$status" -eq 1 ]
}

@test "match: クォート/エスケープ/\${IFS} 難読化を de-obfuscate して捕捉する" {
    _use_example
    run bash -c "source '$LIB' && n=\$(ep_normalize \"g'i't push origin main\"); ep_match_gate \"\$n\""
    [[ "$output" == "git-push" ]]
    run bash -c "source '$LIB' && n=\$(ep_normalize 'git p\\ush origin main'); ep_match_gate \"\$n\""
    [[ "$output" == "git-push" ]]
    run bash -c "source '$LIB' && n=\$(ep_normalize 'git\${IFS}push origin main'); ep_match_gate \"\$n\""
    [[ "$output" == "git-push" ]]
    run bash -c "source '$LIB' && n=\$(ep_normalize \"terra'f'orm apply\"); ep_match_gate \"\$n\""
    [[ "$output" == "deploy" ]]
}

@test "match: 正当なクォート引数は過剰 block しない（git commit -m \"deploy stuff\"）" {
    _use_example
    run bash -c "source '$LIB' && n=\$(ep_normalize 'git commit -m \"deploy stuff\"'); ep_match_gate \"\$n\""
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

@test "marker_base: git-push は command-hash 戦略（コマンド全体で keying＝認可スコープ漏洩を防ぐ）" {
    _use_example
    # prefix は git-push-cmd-、かつ別 refspec は別 marker（main 承認が develop を認可しない＝C-4a）
    run bash -c "source '$LIB' && ep_marker_base git-push 'git push origin main'"
    [[ "$output" == git-push-cmd-* ]]
    local m_main="$output"
    run bash -c "source '$LIB' && ep_marker_base git-push 'git push origin develop'"
    [ "$m_main" != "$output" ]
    # 同一コマンドは同一 marker（決定論＝unlock 後に同 push が通る）
    run bash -c "source '$LIB' && a=\$(ep_marker_base git-push 'git push origin main'); b=\$(ep_marker_base git-push 'git push origin main'); [ \"\$a\" = \"\$b\" ] && echo same"
    [[ "$output" == "same" ]]
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

@test "builtin_danger: 絶対パス・git -C も捕捉（最後の防壁を表記揺れで貫通させない）" {
    run bash -c "source '$LIB' && ep_builtin_danger_match '/usr/bin/git push origin main'"
    [ "$status" -eq 0 ]
    run bash -c "source '$LIB' && ep_builtin_danger_match 'git -C /repo push origin main'"
    [ "$status" -eq 0 ]
    run bash -c "source '$LIB' && ep_builtin_danger_match 'kubectl --context prod apply ./m.yaml'"
    [ "$status" -eq 0 ]
}

@test "builtin_danger SSOT 同期: 例 policy の各 gate 代表コマンドが内蔵 danger list にも一致（W5 回帰）" {
    run bash -c "source '$LIB' && for c in 'gh pr merge 3' 'git push origin main' 'terraform apply' 'serverless deploy'; do ep_builtin_danger_match \"\$c\" || { echo \"MISS: \$c\"; exit 1; }; done; echo allhit"
    [ "$status" -eq 0 ]
    [[ "$output" == "allhit" ]]
}

# ---------------------------------------------------------------------------
# fail-closed 強化（無効 ERE / session-env 欠落フォールバック）
# ---------------------------------------------------------------------------

@test "health: gate の any_re が無効 ERE なら corrupt（黙って無効化＝fail-open を防ぐ）" {
    jq '.gates[0].match.any_re=["broken(re"]' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

@test "health: 先頭量化子 ERE (*terraform) も corrupt（bash =~ と同一エンジンで検証＝grep 乖離回避）" {
    # grep -qE はこれを valid 扱いするが bash [[ =~ ]] は rc=2。実マッチエンジンに揃えて検出する。
    jq '.gates[2].match.any_re=["*terraform"]' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

@test "health: subject_re が無効 ERE でも corrupt" {
    jq '.gates[0].key.subject_re=["[unclosed"]' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

@test "fallback: ENFORCE_* 未設定でも lib が安全デフォルトを設定する（unbound 回避）" {
    # session-env.sh 欠落相当: ENFORCE_* を unset した状態で source しても空にならない
    run bash -c "unset ENFORCE_POLICY_FILE ENFORCE_MARKER_DIR ENFORCE_SHA_TIMEOUT WORKING_MEMORY_DIR; source '$LIB'; set -u; printf '%s|%s|%s' \"\$ENFORCE_POLICY_FILE\" \"\$ENFORCE_MARKER_DIR\" \"\$ENFORCE_SHA_TIMEOUT\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"/.claude-session/enforce-policy.json|"*"/.claude-session/enforce-markers|5"* ]]
}

# ---------------------------------------------------------------------------
# fail-closed 強化（TTL 未指定 gate の無期限 marker＝恒久 unlock を surface・ccs-5p4.1）
#   sha_keyed=false gate は有限 TTL が無いと marker が無期限化し恒久 unlock の fail-open。
#   health が ep_gate_ttl と同一基準で TTL 必須を要求し corrupt（→fail-closed scoped）に倒す。
#   ※判定はランタイムの ep_gate_ttl で行い、jq 再実装との乖離（ERE 検証の教訓）を作らない。
# ---------------------------------------------------------------------------

@test "health: sha_keyed=false gate に有効 TTL が無い（gate も default も）と corrupt" {
    # git-push (gates[1]) は sha_keyed=false。marker_ttl_sec を削除し default も null → 無期限化
    jq 'del(.gates[1].marker_ttl_sec) | .default_marker_ttl_sec=null' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

@test "health: sha_keyed=false gate も default_marker_ttl_sec で TTL を得れば active" {
    jq 'del(.gates[1].marker_ttl_sec) | del(.gates[2].marker_ttl_sec) | .default_marker_ttl_sec=900' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "active" ]]
}

@test "health: sha_keyed=true gate は TTL 不在でも active（head SHA 変化で自動失効＝TTL 必須から除外）" {
    # pr-merge (gates[0]) は sha_keyed=true。TTL を消しても git-push/deploy は TTL 在り → active
    jq 'del(.gates[0].marker_ttl_sec) | .default_marker_ttl_sec=null' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "active" ]]
}

@test "health: sha_keyed=false gate の TTL が非整数（負/小数等）でも corrupt（ep_gate_ttl が空=無期限に倒すため）" {
    jq '.gates[1].marker_ttl_sec="-5" | .default_marker_ttl_sec=null' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

# sha_keyed-ness は jq 内で判定する（bash で再パースしない）。タブ隣接文字列の IFS read 乖離回帰（adversarial review）。
@test "health: sha_keyed 文字列でタブ隣接 \"true<TAB>\" は exempt されず TTL 必須→corrupt（IFS read 再パース乖離・ccs-5p4.1）" {
    # bash の IFS=$'\t' read だと末尾タブ欄が捨てられ "true" に化け exempt→active になる乖離を防ぐ。
    # runtime は生の "true\t" を [ = "true" ] で偽と見て固定 marker を無期限化するため、health=active は恒久 unlock。
    jq '.gates[2].key.sha_keyed="true\t" | del(.gates[2].marker_ttl_sec) | .default_marker_ttl_sec=null' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

@test "health: sha_keyed 文字列の先頭タブ \"<TAB>true\" も exempt されず corrupt" {
    jq '.gates[2].key.sha_keyed="\ttrue" | del(.gates[2].marker_ttl_sec) | .default_marker_ttl_sec=null' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

@test "health: sha_keyed が文字列 \"true\"（タブ無し）は runtime と同じく exempt＝TTL 無しでも active" {
    # ep_marker_sha_suffix の [ "$sha_keyed" = "true" ] は文字列 "true" も真＝sha-key する。health も同 exempt 集合。
    jq '.gates[2].key.sha_keyed="true" | del(.gates[2].marker_ttl_sec) | .default_marker_ttl_sec=null' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "active" ]]
}

# 非 object .key/.match は jq の index abort(rc=5)を招き、旧 process-subst では沈黙して検証ループが骨抜きに
# なり no-TTL gate を取りこぼす fail-open（第2ラウンド CONFIRMED）。probe 型ガード＋ループの rc 捕捉で corrupt。
@test "health: .key が非 object（文字列）の gate は corrupt（jq index abort の沈黙化を防ぐ）" {
    jq '.gates[2].key="brokenstr"' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

@test "health: .key が非 object（数値/配列/真偽）でも corrupt（{}・null は許容）" {
    jq '.gates[2].key=42' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"; [[ "$output" == "corrupt" ]]
    jq '.gates[2].key=[1,2]' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"; [[ "$output" == "corrupt" ]]
    jq '.gates[2].key=true' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"; [[ "$output" == "corrupt" ]]
}

@test "health: 壊れた .key gate が前順でも後順の no-TTL gate を取りこぼさず corrupt（順序非依存・第2ラウンド回帰）" {
    # gates[0] を壊れ .key（前順）、gates[1] git-push を no-TTL（後順）に。旧 process-subst では gates[0] の
    # jq index abort が沈黙し gates[1] の id を取りこぼして active＝fail-open になった。
    jq '.gates[0].key="x" | del(.gates[1].marker_ttl_sec) | .default_marker_ttl_sec=null' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

@test "health: .match が非 object の gate も corrupt（ERE 検証ループの jq abort 沈黙化を防ぐ）" {
    jq '.gates[2].match="notanobject"' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

# .match schema 検証（ccs-5p4.6 + ccs-5p4.3）: any_re は非空の文字列配列を必須。
#  any_re=object は any_re[]? が値へ黙って書き換わり gate 不発→沈黙 fail-open（5p4.6）。
#  any_re 不在は substring-only の .all 単独 gate＝境界無しの footgun のため不許可（5p4.3）。
@test "health: .match.any_re が object は corrupt（any_re[]? の値黙改変で gate 不発する fail-open・ccs-5p4.6）" {
    jq '.gates[2].match.any_re={"k":"NONMATCH"}' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

@test "health: any_re 不在の gate は corrupt（substring-only .all 単独を不許可＝境界認識 any_re 必須・ccs-5p4.3）" {
    jq 'del(.gates[2].match.any_re) | .gates[2].match.all=["terraform","apply"]' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

@test "health: any_re が空配列/非文字列要素/スカラは corrupt" {
    jq '.gates[2].match.any_re=[]' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"; [[ "$output" == "corrupt" ]]
    jq '.gates[2].match.any_re=[42]' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"; [[ "$output" == "corrupt" ]]
    jq '.gates[2].match.any_re="terraform"' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"; [[ "$output" == "corrupt" ]]
}

@test "health: .match.all が非配列/非文字列要素は corrupt（在る場合のみ検証・省略は可）" {
    jq '.gates[0].match.all="gh"' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"; [[ "$output" == "corrupt" ]]
    jq '.gates[0].match.all=[1,2]' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"; [[ "$output" == "corrupt" ]]
}

@test "health: .all 省略・any_re のみの gate（例の deploy）は active（.all は任意・any_re-only は正当）" {
    # substring-only(.all 単独)の禁止であって、境界認識 any_re のみの gate は許容。
    jq -e '.gates[2] | (has("match")) and (.match | has("all") | not) and (.match.any_re | type=="array")' "$EXAMPLE" >/dev/null
    cp "$EXAMPLE" "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "active" ]]
}

# ---------------------------------------------------------------------------
# TTL 値 hardening（先頭ゼロの8進誤解釈・巨大値の事実上恒久 unlock・ccs-5p4.5）
# ---------------------------------------------------------------------------

@test "ep_gate_ttl: 先頭ゼロ \"0900\" は 10 進 900（8進誤解釈なし・ccs-5p4.5）" {
    jq '.gates[1].marker_ttl_sec="0900"' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_gate_ttl git-push"
    [[ "$output" == "900" ]]
}

@test "ep_gate_ttl: \"0100\" は 100（8進 64 でない＝silent 縮小を防ぐ）" {
    jq '.gates[1].marker_ttl_sec="0100"' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_gate_ttl git-push"
    [[ "$output" == "100" ]]
}

@test "ep_gate_ttl: 上限超過の巨大 TTL は空（事実上の恒久 unlock を無効化・ccs-5p4.5）" {
    jq '.gates[1].marker_ttl_sec=900000000000' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_gate_ttl git-push"
    [ -z "$output" ]
}

@test "ep_gate_ttl: 18 桁超の超巨大値は空（64bit overflow 回避）" {
    jq '.gates[1].marker_ttl_sec="999999999999999999999"' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_gate_ttl git-push"
    [ -z "$output" ]
}

@test "ep_gate_ttl: 上限ちょうどは値・上限+1 は空" {
    jq '.gates[1].marker_ttl_sec=2592000' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_gate_ttl git-push"; [[ "$output" == "2592000" ]]
    jq '.gates[1].marker_ttl_sec=2592001' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_gate_ttl git-push"; [ -z "$output" ]
}

@test "ep_gate_ttl: ENFORCE_TTL_MAX_SEC は env で上書き可（上限縮小）" {
    jq '.gates[1].marker_ttl_sec=100' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "export ENFORCE_TTL_MAX_SEC=50; source '$LIB' && ep_gate_ttl git-push"
    [ -z "$output" ]
}

@test "health: 巨大 TTL の sha_keyed=false gate は corrupt（ep_gate_ttl 空→TTL 必須未充足・ccs-5p4.5）" {
    jq '.gates[1].marker_ttl_sec=900000000000 | .default_marker_ttl_sec=null' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    run bash -c "source '$LIB' && ep_policy_health"
    [[ "$output" == "corrupt" ]]
}

@test "marker_valid: \"0900\" TTL でも8進エラーなく判定（fresh=valid / aged=expired・ccs-5p4.5）" {
    jq '.gates[1].marker_ttl_sec="0900"' "$EXAMPLE" > "$ENFORCE_POLICY_FILE"
    mkdir -p "$ENFORCE_MARKER_DIR"
    touch "$ENFORCE_MARKER_DIR/git-push-test"
    run bash -c "source '$LIB' && ep_marker_valid git-push git-push-test"
    [ "$status" -eq 0 ]
    touch -d '2000-01-01' "$ENFORCE_MARKER_DIR/git-push-test"
    run bash -c "source '$LIB' && ep_marker_valid git-push git-push-test"
    [ "$status" -eq 1 ]
}
