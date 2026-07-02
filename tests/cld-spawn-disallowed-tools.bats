#!/usr/bin/env bats
# cld-spawn-disallowed-tools.bats - --disallowed-tools passthrough の unit tests（orch-6sd / ccs-izx）
#
# cld-spawn --disallowed-tools <TOOLS> が cld→claude へ透過されることを検証する。
#   - 生成 LAUNCHER の cld 起動行に --disallowed-tools と各ツール名が含まれる
#   - 空白/カンマ区切りが個別 argv トークンへ分解される（claude の可変長 <tools...> 形）
#   - glob 文字を含むパターン（Bash(git:*)）が glob 展開されず literal で渡る
#   - --model と併用時、--disallowed-tools は末尾（variadic が余計な語を吸収しない）
#   - 未指定時は LAUNCHER に --disallowed-tools が現れない（後方互換）

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
CLD_SPAWN="$SCRIPT_DIR/cld-spawn"

setup() {
    SANDBOX="$(mktemp -d)"
    export LAUNCHER_PATH="$SANDBOX/launcher.sh"
    export FAKE_BIN="$SANDBOX/bin"
    mkdir -p "$FAKE_BIN"

    cat > "$FAKE_BIN/tmux" <<'TMUX_STUB'
#!/bin/bash
case "${1:-}" in
    list-windows) echo "${WINDOW_NAME_STUB:-cld-spawn-test}" ;;
    display-message) echo "main" ;;
esac
exit 0
TMUX_STUB
    chmod +x "$FAKE_BIN/tmux"

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

    cat > "$FAKE_BIN/flock" <<'FLOCK_STUB'
#!/bin/bash
exit 0
FLOCK_STUB
    chmod +x "$FAKE_BIN/flock"

    export STUB_SCRIPTS="$SANDBOX/scripts"
    mkdir -p "$STUB_SCRIPTS/lib"
    cat > "$STUB_SCRIPTS/session-name.sh" <<'SESSION_STUB'
generate_window_name() { echo "cld-spawn-test"; }
find_existing_window()  { echo ""; }
SESSION_STUB
    touch "$STUB_SCRIPTS/window-manifest.sh"
    cp "$SCRIPT_DIR/lib/session-env.sh" "$STUB_SCRIPTS/lib/session-env.sh"
    cat > "$STUB_SCRIPTS/session-comm.sh" <<'COMM_STUB'
#!/bin/bash
exit 0
COMM_STUB
    chmod +x "$STUB_SCRIPTS/session-comm.sh"

    # 記録用 cld スタブ: 受け取った argv を 1 行 1 引数で cld-args.txt に書く（LAUNCHER 実行で検証）
    cat > "$FAKE_BIN/cld-stub" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "$SANDBOX/cld-args.txt"
exit 0
STUB
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

_run_spawn() {
    run bash "$STUB_SCRIPTS/cld-spawn" "$@"
    LAUNCHER_CONTENT=""
    if [[ -f "$LAUNCHER_PATH" ]]; then
        LAUNCHER_CONTENT="$(cat "$LAUNCHER_PATH")"
    fi
}

# LAUNCHER を実行し cld-stub が受け取った argv を配列 CLD_ARGS に読み込む
_exec_launcher_capture_args() {
    rm -f "$SANDBOX/cld-args.txt"
    bash "$LAUNCHER_PATH"
    CLD_ARGS=()
    if [[ -f "$SANDBOX/cld-args.txt" ]]; then
        mapfile -t CLD_ARGS < "$SANDBOX/cld-args.txt"
    fi
}

# ===========================================================================
# パーサ受理・後方互換
# ===========================================================================

@test "disallowed-tools: オプションがパーサに存在する（未知オプション扱いされない）" {
    _run_spawn --disallowed-tools "AskUserQuestion"
    [[ "$output" != *"未知のオプション"* ]] || fail "--disallowed-tools が未知オプション扱い: $output"
    [[ "$status" -eq 0 ]] || fail "exit 0 期待, got $status. $output"
}

@test "disallowed-tools: 未指定時は LAUNCHER に --disallowed-tools が現れない（後方互換）" {
    _run_spawn
    [[ "$LAUNCHER_CONTENT" != *"--disallowed-tools"* ]] \
        || fail "未指定なのに LAUNCHER に --disallowed-tools がある: $LAUNCHER_CONTENT"
}

@test "disallowed-tools: 空の値（値なし）はエラーになる" {
    run bash "$STUB_SCRIPTS/cld-spawn" --disallowed-tools
    [[ "$status" -ne 0 ]] || fail "値なし --disallowed-tools で exit 0 になった"
}

# ===========================================================================
# 透過（LAUNCHER 内容 / 実 argv）
# ===========================================================================

@test "disallowed-tools: LAUNCHER の cld 行に --disallowed-tools が含まれる" {
    _run_spawn --disallowed-tools "AskUserQuestion"
    [[ "$LAUNCHER_CONTENT" == *"--disallowed-tools"* ]] \
        || fail "LAUNCHER に --disallowed-tools が無い: $LAUNCHER_CONTENT"
}

@test "disallowed-tools: 空白区切りの複数ツールが個別 argv になる" {
    _run_spawn --disallowed-tools "AskUserQuestion ExitPlanMode"
    _exec_launcher_capture_args
    # cld-stub の argv に --disallowed-tools / AskUserQuestion / ExitPlanMode が個別要素で並ぶ
    local joined="${CLD_ARGS[*]}"
    [[ "$joined" == *"--disallowed-tools AskUserQuestion ExitPlanMode"* ]] \
        || fail "argv がトークン分解されていない: [$joined]"
}

@test "disallowed-tools: カンマ区切りも個別 argv に分解される" {
    _run_spawn --disallowed-tools "AskUserQuestion,ExitPlanMode"
    _exec_launcher_capture_args
    local joined="${CLD_ARGS[*]}"
    [[ "$joined" == *"--disallowed-tools AskUserQuestion ExitPlanMode"* ]] \
        || fail "カンマ区切りが分解されていない: [$joined]"
}

@test "disallowed-tools: 複数回指定は累積される" {
    _run_spawn --disallowed-tools "AskUserQuestion" --disallowed-tools "ExitPlanMode"
    _exec_launcher_capture_args
    local joined="${CLD_ARGS[*]}"
    [[ "$joined" == *"AskUserQuestion"* && "$joined" == *"ExitPlanMode"* ]] \
        || fail "複数指定が累積されていない: [$joined]"
}

@test "disallowed-tools: glob 文字を含むツールパターンが literal で渡る（Bash(git:*)）" {
    # read -ra はパス名展開しないため CWD に何があっても literal 保持されることを確認。
    _run_spawn --disallowed-tools 'Bash(git:*)'
    _exec_launcher_capture_args
    local found=0 a
    for a in "${CLD_ARGS[@]}"; do
        [[ "$a" == 'Bash(git:*)' ]] && found=1
    done
    [[ "$found" -eq 1 ]] || fail "glob パターンが literal で渡っていない（展開された疑い）: [${CLD_ARGS[*]}]"
}

@test "disallowed-tools: --model と併用時 --disallowed-tools は末尾に置かれる（variadic 吸収防止）" {
    _run_spawn --model sonnet --disallowed-tools "AskUserQuestion ExitPlanMode"
    _exec_launcher_capture_args
    local joined="${CLD_ARGS[*]}"
    # --model sonnet が --disallowed-tools より前
    [[ "$joined" == *"--model sonnet"*"--disallowed-tools"* ]] \
        || fail "--disallowed-tools が末尾に無い（--model の後にない）: [$joined]"
    # --disallowed-tools の後に --model 等の別フラグが続かない（末尾＝最後の要素群がツール名）
    local last="${CLD_ARGS[-1]}"
    [[ "$last" == "ExitPlanMode" ]] \
        || fail "argv 末尾がツール名でない（variadic に別語が続いた）: last=[$last] all=[$joined]"
}
