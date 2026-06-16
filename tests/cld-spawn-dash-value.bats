#!/usr/bin/env bats
# cld-spawn-dash-value.bats — 値スロットの dash-value 拒否 / dash-prompt 受理の回帰ガード (un-3lh)
#
# 背景（un-ivb round 2 / fail-loud 堅牢化）: 値取りオプション（--cd/--env-file/--window-name/
# --bd-id/--timeout/--model）の値スロットに '-' 始まりトークンが来た場合、直後のオプションを
# 値として取りこぼした可能性が高い（例: `cld-spawn --bd-id --model opus` で --bd-id が "--model" を
# 値として吸う）。これを fail-loud（exit 1・window 非作成）で拒否し、誤った命名・env-file での
# spawn を構造的に防ぐ。
#
# 併せて、'-' 始まり PROMPT が '--' 区切り経由で正しく受理され inject まで届くこと（dash-prompt
# 受理）を回帰ガードする。SKILL.md 側の呼出が '-- "$PROMPT"' 形を保つことも grep で固定する。
#
# Scenarios:
#   - dash-value 拒否: 各値取りオプションの値が '-' 始まり → exit 1・window 非作成・stderr にエラー
#   - dash-prompt 受理: `cld-spawn -- "-x"` → exit 0・PROMPT が inject 経路へ到達（救済退行ガード）
#   - 正常値は従来どおり受理（後方互換・dash でない値）
#   - SKILL.md guard: cld-spawn の呼出が '--' で PROMPT を区切っている（誤拒否封鎖の producer 規約）
#
# tmux stub が new-window 呼び出しを TMUX_LOG / TMUX_LOG.winname に、inject 内容を TMUX_LOG.injected に記録する。
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

    # session-comm.sh: inject-file の PROMPT 内容（$3 = PROMPT_FILE）を記録して即成功
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

_injected() {
    cat "${TMUX_LOG}.injected" 2>/dev/null
}

# ---------------------------------------------------------------------------
# dash-value 拒否（fail-loud）: 各値取りオプションで値スロットに '-' 始まりが来たら exit 1・window 非作成
# ---------------------------------------------------------------------------

@test "dash-value: --cd の値が '-' 始まりなら exit 1・window 非作成" {
    run bash "$STUB_SCRIPTS/cld-spawn" --cd --window-name
    [ "$status" -eq 1 ] || fail "exit $status (expected 1): $output"
    [[ "$output" == *"--cd"* ]] || fail "エラーに --cd が出ていない: $output"
    _no_window_created || fail "window が作成された（dash-value で spawn してはならない）: $(cat "$TMUX_LOG" 2>/dev/null)"
}

@test "dash-value: --env-file の値が '-' 始まりなら exit 1・window 非作成" {
    run bash "$STUB_SCRIPTS/cld-spawn" --env-file --model
    [ "$status" -eq 1 ] || fail "exit $status (expected 1): $output"
    [[ "$output" == *"--env-file"* ]] || fail "エラーに --env-file が出ていない: $output"
    _no_window_created || fail "window が作成された: $(cat "$TMUX_LOG" 2>/dev/null)"
}

@test "dash-value: --window-name の値が '-' 始まりなら exit 1・window 非作成" {
    run bash "$STUB_SCRIPTS/cld-spawn" --window-name --bd-id
    [ "$status" -eq 1 ] || fail "exit $status (expected 1): $output"
    [[ "$output" == *"--window-name"* ]] || fail "エラーに --window-name が出ていない: $output"
    _no_window_created || fail "window が作成された: $(cat "$TMUX_LOG" 2>/dev/null)"
}

@test "dash-value: --bd-id の値が '-' 始まりなら exit 1・window 非作成（取りこぼし防止）" {
    run bash "$STUB_SCRIPTS/cld-spawn" --bd-id --model opus
    [ "$status" -eq 1 ] || fail "exit $status (expected 1): $output"
    [[ "$output" == *"--bd-id"* ]] || fail "エラーに --bd-id が出ていない: $output"
    _no_window_created || fail "window が作成された: $(cat "$TMUX_LOG" 2>/dev/null)"
}

@test "dash-value: --timeout の値が '-' 始まりなら exit 1・window 非作成" {
    run bash "$STUB_SCRIPTS/cld-spawn" --timeout -5
    [ "$status" -eq 1 ] || fail "exit $status (expected 1): $output"
    [[ "$output" == *"--timeout"* ]] || fail "エラーに --timeout が出ていない: $output"
    _no_window_created || fail "window が作成された: $(cat "$TMUX_LOG" 2>/dev/null)"
}

@test "dash-value: --model の値が '-' 始まりなら exit 1・window 非作成" {
    run bash "$STUB_SCRIPTS/cld-spawn" --model --cd /tmp
    [ "$status" -eq 1 ] || fail "exit $status (expected 1): $output"
    [[ "$output" == *"--model"* ]] || fail "エラーに --model が出ていない: $output"
    _no_window_created || fail "window が作成された: $(cat "$TMUX_LOG" 2>/dev/null)"
}

@test "dash-value: dash 拒否のエラーは stderr に出る（stdout に漏らさない）" {
    run bash -c "bash '$STUB_SCRIPTS/cld-spawn' --bd-id --model 2>/dev/null"
    [ "$status" -eq 1 ] || fail "exit $status (expected 1)"
    [[ "$output" != *"-' で始まっています"* ]] || fail "dash エラーが stdout に漏れている: $output"
}

# ---------------------------------------------------------------------------
# dash-prompt 受理（回帰ガード）: '--' 区切りなら '-' 始まり PROMPT が inject まで届く
# ---------------------------------------------------------------------------

@test "dash-prompt: '--' 区切りなら '-' 始まり PROMPT が inject 経路へ到達する" {
    run bash "$STUB_SCRIPTS/cld-spawn" -- "-x で始まる prompt"
    [ "$status" -eq 0 ] || fail "exit $status: $output"
    [ -n "$(_winname)" ] || fail "window が作成されていない（-- で PROMPT 救済されるべき）"
    [ "$(_injected)" = "-x で始まる prompt" ] \
        || fail "PROMPT が inject へ届いていない（救済退行）: '$(_injected)'"
}

@test "dash-prompt: '--' の後の '--bd-id' 風トークンも PROMPT として扱う（オプション解釈しない）" {
    run bash "$STUB_SCRIPTS/cld-spawn" -- "--bd-id っぽいが prompt"
    [ "$status" -eq 0 ] || fail "exit $status: $output"
    [ "$(_injected)" = "--bd-id っぽいが prompt" ] \
        || fail "PROMPT が inject へ届いていない: '$(_injected)'"
}

# ---------------------------------------------------------------------------
# 後方互換: dash でない正常値は従来どおり受理される
# ---------------------------------------------------------------------------

@test "compat: 正常値 --bd-id un-3lh は従来どおり window を作る（dash チェックで誤拒否しない）" {
    run bash "$STUB_SCRIPTS/cld-spawn" --bd-id un-3lh
    [ "$status" -eq 0 ] || fail "exit $status: $output"
    [ "$(_winname)" = "wt-un-3lh" ] || fail "window name = '$(_winname)' (expected wt-un-3lh)"
}

@test "compat: 正常値 --model sonnet は従来どおり受理される" {
    run bash "$STUB_SCRIPTS/cld-spawn" --model sonnet --bd-id un-3lh
    [ "$status" -eq 0 ] || fail "exit $status: $output"
    [ "$(_winname)" = "wt-un-3lh" ] || fail "window name = '$(_winname)' (expected wt-un-3lh)"
}

# ---------------------------------------------------------------------------
# SKILL.md guard: spawn skill の cld-spawn 呼出が '--' で PROMPT を区切る（誤拒否封鎖の producer 規約）
# ---------------------------------------------------------------------------

@test "skill-guard: SKILL.md に hardened 呼出形 '-- \"\$PROMPT\"' / '-- \"\$FULL_PROMPT\"' が存在する" {
    local skill="$SCRIPT_DIR/../skills/spawn/SKILL.md"
    [ -f "$skill" ] || fail "SKILL.md が見つからない: $skill"
    # worktree 経路（パターン D・複数行呼出の末尾）の hardened 形
    grep -qF -- '-- "$PROMPT"' "$skill" \
        || fail "SKILL.md に '-- \"\$PROMPT\"'（worktree 経路の hardened 呼出）が無い"
    # OPTS 経路（即実行）の hardened 形（契約が名指しした正準形）
    grep -qF -- '-- "$FULL_PROMPT"' "$skill" \
        || fail "SKILL.md に '-- \"\$FULL_PROMPT\"'（OPTS 経路の hardened 呼出）が無い"
}

@test "skill-guard: cld-spawn 呼出（行継続をまたぐ worktree 経路も）は必ず '-- ' で PROMPT を区切る" {
    local skill="$SCRIPT_DIR/../skills/spawn/SKILL.md"
    [ -f "$skill" ] || fail "SKILL.md が見つからない: $skill"
    # 行継続 '\' を畳んで論理行にしてから検査する。これにより worktree 経路（パターン D）の
    # 複数行 cld-spawn 呼出（行 140-141: 'cld-spawn ... \' + '... -- "$PROMPT"'）も 1 論理行として
    # 照合され、同一行版では盲点だった『worktree 経路から '--' だけ削除する退行』も捕捉できる。
    # cld-spawn と "$PROMPT"/"$FULL_PROMPT" を同時に含む論理行はすべて '-- "$..PROMPT"' を含むこと。
    local joined
    joined="$(sed ':a;/\\$/{N;s/\\\n//;ba}' "$skill")"
    while IFS= read -r line; do
        [[ "$line" == *cld-spawn* ]] || continue
        [[ "$line" == *'"$PROMPT"'* || "$line" == *'"$FULL_PROMPT"'* ]] || continue
        [[ "$line" == *'-- "$PROMPT"'* || "$line" == *'-- "$FULL_PROMPT"'* ]] \
            || fail "cld-spawn 呼出が '--' 区切りなしで PROMPT を渡している（誤拒否退行）: $line"
    done <<< "$joined"
}
