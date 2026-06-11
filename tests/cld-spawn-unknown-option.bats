#!/usr/bin/env bats
# cld-spawn-unknown-option.bats — 未知オプションの fail-loud / --help の unit tests (un-ivb)
#
# 背景（2026-06-11 実害）: 'cld-spawn --help' を実行したところ、--help が未知オプションとして
# PROMPT positional に落ち、anchor cwd で fable セッションが誤 spawn された。
#
# Scenarios:
#   - --help / -h    → usage を表示して exit 0・tmux window を作らない
#   - --bogus / -x   → exit 1・stderr に usage・tmux window を作らない（PROMPT に流さない）
#   - --             → 以降の '-' 始まり引数は PROMPT として扱う（exit 0・window 作成）
#   - 正常系（--bd-id）は従来どおり window を作る（後方互換）
#
# tmux stub が new-window 呼び出しを TMUX_LOG / TMUX_LOG.winname に記録する。
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
CLD_SPAWN="$SCRIPT_DIR/cld-spawn"

setup() {
    SANDBOX="$(mktemp -d)"
    export LAUNCHER_PATH="$SANDBOX/launcher.sh"
    export FAKE_BIN="$SANDBOX/bin"
    export TMUX_LOG="$SANDBOX/tmux-calls.log"
    mkdir -p "$FAKE_BIN"

    # --- tmux stub: new-window の -n <name> を記録 ---
    cat > "$FAKE_BIN/tmux" <<TMUX_STUB
#!/bin/bash
echo "\$@" >> "${TMUX_LOG}"
case "\${1:-}" in
    new-window)
        shift
        while [[ \$# -gt 0 ]]; do
            if [[ "\$1" == "-n" ]]; then echo "\$2" >> "${TMUX_LOG}.winname"; fi
            shift
        done
        ;;
    list-windows)
        cat "${TMUX_LOG}.winname" 2>/dev/null || echo "fallback"
        ;;
    display-message)
        echo "main"
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
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/flock"
    chmod +x "$FAKE_BIN/flock"

    export STUB_SCRIPTS="$SANDBOX/scripts"
    mkdir -p "$STUB_SCRIPTS"

    # session-name.sh: 実体をコピーし generate_window_name / find_existing_window のみスタブ
    cp "$SCRIPT_DIR/session-name.sh" "$STUB_SCRIPTS/session-name.sh"
    cat >> "$STUB_SCRIPTS/session-name.sh" <<'SESSION_STUB'
generate_window_name() { echo "semantic-fallback-name"; }
find_existing_window()  { echo ""; }
SESSION_STUB

    # window-manifest.sh: source されても安全な空スタブ
    touch "$STUB_SCRIPTS/window-manifest.sh"

    # lib/session-env.sh: namespace 定義（実体をコピー）
    mkdir -p "$STUB_SCRIPTS/lib"
    cp "$SCRIPT_DIR/lib/session-env.sh" "$STUB_SCRIPTS/lib/session-env.sh"

    # session-comm.sh: inject-file の PROMPT 内容（$3 = PROMPT_FILE）を記録して即成功。
    # → '-' 始まり PROMPT が「window 作成」だけでなく実際に inject 経路へ届いたかを観測可能にする。
    cat > "$STUB_SCRIPTS/session-comm.sh" <<INJECT_STUB
#!/bin/bash
if [[ "\${1:-}" == "inject-file" ]]; then
    cat "\${3:-/dev/null}" > "${TMUX_LOG}.injected" 2>/dev/null || true
fi
exit 0
INJECT_STUB
    chmod +x "$STUB_SCRIPTS/session-comm.sh"

    # cld stub
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/cld-stub"
    chmod +x "$FAKE_BIN/cld-stub"
    export CLD_PATH="$FAKE_BIN/cld-stub"

    cp "$CLD_SPAWN" "$STUB_SCRIPTS/cld-spawn"
    chmod +x "$STUB_SCRIPTS/cld-spawn"

    export HOME="$SANDBOX/home"
    mkdir -p "$HOME/.local/state/claude-session"
    export TMUX="fake-tmux-socket,12345,0"
    export PATH="$FAKE_BIN:$PATH"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

# new-window が一度でも呼ばれたか（呼ばれていなければ true）
_no_window_created() {
    [[ ! -f "$TMUX_LOG" ]] && return 0
    ! grep -q "new-window" "$TMUX_LOG"
}

_winname() {
    cat "${TMUX_LOG}.winname" 2>/dev/null | head -n1
}

# inject-file へ実際に渡された PROMPT 内容（送達経路に到達した文字列）
_injected() {
    cat "${TMUX_LOG}.injected" 2>/dev/null
}

# ---------------------------------------------------------------------------
# --help / -h
# ---------------------------------------------------------------------------

@test "help: --help は exit 0 で usage を表示し window を作らない" {
    run bash "$STUB_SCRIPTS/cld-spawn" --help
    [ "$status" -eq 0 ] || fail "exit $status: $output"
    [[ "$output" == *"Usage:"* ]] || fail "usage が出ていない: $output"
    _no_window_created || fail "window が作成された（--help で spawn してはならない）: $(cat "$TMUX_LOG")"
}

@test "help: -h は exit 0 で usage を表示し window を作らない" {
    run bash "$STUB_SCRIPTS/cld-spawn" -h
    [ "$status" -eq 0 ] || fail "exit $status: $output"
    [[ "$output" == *"Usage:"* ]] || fail "usage が出ていない: $output"
    _no_window_created || fail "window が作成された: $(cat "$TMUX_LOG")"
}

@test "help: --help は tmux 外（TMUX 未設定）でも exit 0 で usage を出す" {
    unset TMUX
    run bash "$STUB_SCRIPTS/cld-spawn" --help
    [ "$status" -eq 0 ] || fail "exit $status: $output"
    [[ "$output" == *"Usage:"* ]] || fail "usage が出ていない: $output"
}

# ---------------------------------------------------------------------------
# 未知オプション → fail-loud
# ---------------------------------------------------------------------------

@test "unknown: --bogus は exit 1・stderr に usage・window を作らない" {
    run bash "$STUB_SCRIPTS/cld-spawn" --bogus
    [ "$status" -eq 1 ] || fail "exit $status (expected 1): $output"
    [[ "$output" == *"未知のオプション"* ]] || fail "未知オプションのエラーが出ていない: $output"
    [[ "$output" == *"Usage:"* ]] || fail "usage が出ていない: $output"
    _no_window_created || fail "window が作成された（未知オプションで spawn してはならない）: $(cat "$TMUX_LOG")"
}

@test "unknown: 未知の短縮オプション -x も exit 1 で window を作らない" {
    run bash "$STUB_SCRIPTS/cld-spawn" -x
    [ "$status" -eq 1 ] || fail "exit $status (expected 1): $output"
    _no_window_created || fail "window が作成された: $(cat "$TMUX_LOG")"
}

@test "unknown: --bogus の usage は stderr に出る（stdout には出さない）" {
    run bash -c "bash '$STUB_SCRIPTS/cld-spawn' --bogus 2>/dev/null"
    [ "$status" -eq 1 ] || fail "exit $status (expected 1)"
    [[ "$output" != *"Usage:"* ]] || fail "usage が stdout に漏れている: $output"
}

@test "unknown: 既知オプションの後ろに未知オプションが来ても fail-loud" {
    run bash "$STUB_SCRIPTS/cld-spawn" --cd "$SANDBOX" --nope
    [ "$status" -eq 1 ] || fail "exit $status (expected 1): $output"
    _no_window_created || fail "window が作成された: $(cat "$TMUX_LOG")"
}

# ---------------------------------------------------------------------------
# -- 終端 / 後方互換
# ---------------------------------------------------------------------------

@test "endopts: -- 以降の '-' 始まり引数が PROMPT として inject まで届く" {
    run bash "$STUB_SCRIPTS/cld-spawn" -- "-から始まる prompt"
    [ "$status" -eq 0 ] || fail "exit $status: $output"
    [ -n "$(_winname)" ] || fail "window が作成されていない（-- で PROMPT 救済されるべき）"
    # window 作成だけでなく、'-' 始まり文字列が PROMPT として送達経路へ到達したことを検証
    # （空 PROMPT でも window は作られるため、内容到達まで見ないと救済の退行を見逃す）
    [ "$(_injected)" = "-から始まる prompt" ] \
        || fail "PROMPT が inject へ届いていない（取りこぼし）: '$(_injected)'"
}

@test "compat: 正常系 --bd-id は従来どおり window を作る（後方互換）" {
    run bash "$STUB_SCRIPTS/cld-spawn" --bd-id un-cbi
    [ "$status" -eq 0 ] || fail "exit $status: $output"
    [ "$(_winname)" = "wt-un-cbi" ] || fail "window name = '$(_winname)' (expected wt-un-cbi)"
}

@test "compat: 通常の PROMPT（'-' 始まりでない）は window 作成＋inject まで届く" {
    run bash "$STUB_SCRIPTS/cld-spawn" "普通のプロンプト"
    [ "$status" -eq 0 ] || fail "exit $status: $output"
    [ -n "$(_winname)" ] || fail "window が作成されていない"
    [ "$(_injected)" = "普通のプロンプト" ] || fail "PROMPT が inject へ届いていない: '$(_injected)'"
}
