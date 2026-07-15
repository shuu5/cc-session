#!/usr/bin/env bats
# cld-spawn-session.bats - --session オプション（session ターゲティング）の unit tests
#
# orch-8rn8 leg-② / ccs-y9h: session=project 対称性の write 側。
#
# Scenarios covered:
#   - --session <既存 session>: new-window -t '=<session>:' で宛先 session 内に生成される
#   - --session <不在 session>: new-session -d -s で create-if-absent される（追補4）
#   - window 再利用探索が TARGET_SESSION スコープで呼ばれる（--session 明示/省略の両方）
#   - 再利用 hit 時は new-window/new-session を発行しない
#   - --session と --inject-existing の併用は fail-loud
#   - 不正な session 名（':' '.' 先頭 '-' 等）は fail-loud
#   - spawned メッセージに session が含まれる
#
# スタブ方針は cld-spawn-model.bats と同型（tmux/flock/mktemp/session-name.sh/session-comm.sh を
# スタブ化）。tmux スタブは受けた引数を $TMUX_LOG へ記録し、has-session は $EXISTING_SESSIONS
# （空白区切り）との完全一致で応答する。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
CLD_SPAWN="$SCRIPT_DIR/cld-spawn"

setup() {
    SANDBOX="$(mktemp -d)"
    export LAUNCHER_PATH="$SANDBOX/launcher.sh"
    export FAKE_BIN="$SANDBOX/bin"
    export TMUX_LOG="$SANDBOX/tmux.log"
    : > "$TMUX_LOG"
    mkdir -p "$FAKE_BIN"

    # --- tmux stub: 呼び出しを記録し、コマンド別に応答 ---
    cat > "$FAKE_BIN/tmux" <<'TMUX_STUB'
#!/bin/bash
echo "tmux $*" >> "$TMUX_LOG"
case "${1:-}" in
    has-session)
        tgt=""; prev=""
        for a in "$@"; do
            [[ "$prev" == "-t" ]] && tgt="${a#=}"
            prev="$a"
        done
        for s in ${EXISTING_SESSIONS:-}; do
            [[ "$s" == "$tgt" ]] && exit 0
        done
        exit 1
        ;;
    list-windows)
        echo "${WINDOW_NAME_STUB:-cld-spawn-test}"
        ;;
    display-message)
        echo "${CURRENT_SESSION_STUB:-cursess}"
        ;;
esac
exit 0
TMUX_STUB
    chmod +x "$FAKE_BIN/tmux"

    # --- mktemp stub: LAUNCHER パスを固定 ---
    cat > "$FAKE_BIN/mktemp" <<MKTEMP_STUB
#!/bin/bash
if [[ "\$*" == *"cld-spawn-XXXXXX.sh"* ]]; then
    touch "${LAUNCHER_PATH}"
    echo "${LAUNCHER_PATH}"
else
    /usr/bin/mktemp "\$@"
fi
MKTEMP_STUB
    chmod +x "$FAKE_BIN/mktemp"

    # --- flock stub ---
    cat > "$FAKE_BIN/flock" <<'FLOCK_STUB'
#!/bin/bash
exit 0
FLOCK_STUB
    chmod +x "$FAKE_BIN/flock"

    # --- スタブスクリプトディレクトリ ---
    export STUB_SCRIPTS="$SANDBOX/scripts"
    mkdir -p "$STUB_SCRIPTS"

    # session-name.sh: find_existing_window は受けた引数を記録して FEW_RESULT を返す
    cat > "$STUB_SCRIPTS/session-name.sh" <<'SESSION_STUB'
generate_window_name() { echo "cld-spawn-test"; }
find_existing_window()  { echo "FEW:$*" >> "$TMUX_LOG"; echo "${FEW_RESULT:-}"; }
SESSION_STUB

    # window-manifest.sh: source されても安全な空スタブ（manifest 経路は対象外）
    touch "$STUB_SCRIPTS/window-manifest.sh"

    # lib/session-env.sh: 実体をコピー
    mkdir -p "$STUB_SCRIPTS/lib"
    cp "$SCRIPT_DIR/lib/session-env.sh" "$STUB_SCRIPTS/lib/session-env.sh"

    # session-comm.sh: 呼び出し引数（送達 target 含む）を記録して成功を返す
    cat > "$STUB_SCRIPTS/session-comm.sh" <<'COMM_STUB'
#!/bin/bash
echo "COMM:$*" >> "$TMUX_LOG"
exit 0
COMM_STUB
    chmod +x "$STUB_SCRIPTS/session-comm.sh"

    # cld stub
    cat > "$FAKE_BIN/cld-stub" <<'CLD_STUB'
#!/bin/bash
exit 0
CLD_STUB
    chmod +x "$FAKE_BIN/cld-stub"
    export CLD_PATH="$FAKE_BIN/cld-stub"

    # cld-spawn 本体をコピー
    cp "$CLD_SPAWN" "$STUB_SCRIPTS/cld-spawn"
    chmod +x "$STUB_SCRIPTS/cld-spawn"

    export HOME="$SANDBOX/home"
    mkdir -p "$HOME/.local/state/claude-session"
    export TMUX="fake-tmux-socket,12345,0"
    export PATH="$FAKE_BIN:$PATH"

    unset EXISTING_SESSIONS FEW_RESULT || true
    export EXISTING_SESSIONS=""
    export FEW_RESULT=""
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

_run_spawn() {
    run bash "$STUB_SCRIPTS/cld-spawn" "$@"
}

@test "session: --session が usage に存在する" {
    run bash "$STUB_SCRIPTS/cld-spawn" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--session"* ]]
}

@test "session: --session <既存> は '=<session>:' 宛の new-window で生成される" {
    export EXISTING_SESSIONS="proj"
    _run_spawn --session proj
    [ "$status" -eq 0 ]
    grep -q "tmux new-window -t =proj: -n cld-spawn-test" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
    ! grep -q "tmux new-session" "$TMUX_LOG"
}

@test "session: --session <不在> は new-session -d で create-if-absent される" {
    export EXISTING_SESSIONS=""
    _run_spawn --session proj
    [ "$status" -eq 0 ]
    grep -q "tmux new-session -d -s proj -n cld-spawn-test" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
    # 本体 window は new-session の初期 window として生成される（new-window は使わない）。
    # new-session 時に併設される hold（番兵）window の new-window は例外（orch-oktg・
    # 検証は cld-spawn-hold-window.bats）。
    ! grep -q "tmux new-window.*-n cld-spawn-test" "$TMUX_LOG"
}

@test "session: 再利用探索が --session の session スコープで呼ばれる" {
    export EXISTING_SESSIONS="proj"
    _run_spawn --session proj
    [ "$status" -eq 0 ]
    grep -q "FEW:cld-spawn-test proj" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
}

@test "session: --session 省略時は現在 session スコープで再利用探索・生成される" {
    export EXISTING_SESSIONS="cursess"
    export CURRENT_SESSION_STUB="cursess"
    _run_spawn
    [ "$status" -eq 0 ]
    grep -q "FEW:cld-spawn-test cursess" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
    grep -q "tmux new-window -t =cursess: -n cld-spawn-test" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
}

@test "session: 再利用 hit 時は new-window/new-session を発行しない" {
    export EXISTING_SESSIONS="proj"
    export FEW_RESULT="proj:5"
    _run_spawn --session proj
    [ "$status" -eq 0 ]
    [[ "$output" == *"reusing existing window: proj:5"* ]]
    ! grep -q "tmux new-window" "$TMUX_LOG"
    ! grep -q "tmux new-session" "$TMUX_LOG"
}

@test "session: spawned メッセージに session が含まれる" {
    export EXISTING_SESSIONS="proj"
    _run_spawn --session proj
    [ "$status" -eq 0 ]
    [[ "$output" == *"spawned → tmux window 'cld-spawn-test' (session: proj)"* ]]
}

@test "session: --session と --inject-existing の併用は fail-loud" {
    _run_spawn --session proj --inject-existing some-win -- "hello"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--session"* ]]
    [[ "$output" == *"併用できません"* ]]
}

@test "session: ':' を含む session 名は fail-loud" {
    _run_spawn --session "pro:j"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--session 名は英数字"* ]]
}

@test "session: '.' を含む session 名は fail-loud" {
    _run_spawn --session "pro.j"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--session 名は英数字"* ]]
}

@test "session: '-' 始まりの session 名は値取りこぼしとして拒否される" {
    _run_spawn --session --force-new
    [ "$status" -ne 0 ]
    [[ "$output" == *"'-' で始まっています"* ]]
}

@test "session: --session に空値は fail-loud" {
    _run_spawn --session ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"値を指定してください"* ]]
}

# --- プロンプト送達の session 修飾（受入基準(5) の gating・review 反映） ---

@test "session: --session 指定時の送達 target は session:window 修飾される" {
    export EXISTING_SESSIONS="proj"
    _run_spawn --session proj -- "hello"
    [ "$status" -eq 0 ]
    grep -q "COMM:inject-file proj:cld-spawn-test" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
    [[ "$output" == *"prompt injected → 'proj:cld-spawn-test'"* ]]
}

@test "session: --session 省略時も現在 session で修飾送達される" {
    export EXISTING_SESSIONS="cursess"
    export CURRENT_SESSION_STUB="cursess"
    _run_spawn -- "hello"
    [ "$status" -eq 0 ]
    grep -q "COMM:inject-file cursess:cld-spawn-test" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
    [[ "$output" == *"prompt injected → 'cursess:cld-spawn-test'"* ]]
}

@test "session: 現在 session 名が送達 allowlist 外なら bare 名送達へフォールバック（偽失敗回帰の防止）" {
    # 'user@host' は tmux 的に合法だが resolve_target の session allowlist 外
    export EXISTING_SESSIONS="user@host"
    export CURRENT_SESSION_STUB="user@host"
    _run_spawn -- "hello"
    [ "$status" -eq 0 ]
    # 修飾せず bare window 名で送達される（session 修飾だと送達層が reject し偽失敗になる）
    grep -q "COMM:inject-file cld-spawn-test" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
    ! grep -q "COMM:inject-file user@host:cld-spawn-test" "$TMUX_LOG"
    [[ "$output" == *"prompt injected → 'cld-spawn-test'"* ]]
    [[ "$output" == *"安全文字集合外"* ]]
}

@test "session: --window-name が送達 allowlist 外でも偽失敗しない（window 軸の bare フォールバック・round-2 反映）" {
    export EXISTING_SESSIONS="cursess"
    export CURRENT_SESSION_STUB="cursess"
    export WINDOW_NAME_STUB="foo@bar"
    _run_spawn --window-name "foo@bar" -- "hello"
    [ "$status" -eq 0 ]
    # 修飾すると resolve_target の window allowlist が '@' を reject し偽失敗になるため bare 送達
    grep -q "COMM:inject-file foo@bar " "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
    ! grep -q "COMM:inject-file cursess:foo@bar" "$TMUX_LOG"
    [[ "$output" == *"prompt injected → 'foo@bar'"* ]]
    [[ "$output" == *"安全文字集合外"* ]]
}

@test "session: dotted bd id の window 名は修飾送達される（安全集合内・回帰確認）" {
    export EXISTING_SESSIONS="cursess"
    export CURRENT_SESSION_STUB="cursess"
    export WINDOW_NAME_STUB="wt-un-3sh.3.5"
    _run_spawn --window-name "wt-un-3sh.3.5" -- "hello"
    [ "$status" -eq 0 ]
    grep -q "COMM:inject-file cursess:wt-un-3sh.3.5 " "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
    [[ "$output" == *"prompt injected → 'cursess:wt-un-3sh.3.5'"* ]]
}
