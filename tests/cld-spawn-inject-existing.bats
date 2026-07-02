#!/usr/bin/env bats
# cld-spawn-inject-existing.bats - --inject-existing モードの unit tests（orch-6sd / ccs-izx）
#
# cld-spawn --inject-existing <WINDOW> <PROMPT> が spawn せず既存 window へ inject する:
#   - session-comm.sh inject-file を対象 window + --wait/--confirm-receipt 付きで呼ぶ（read-back 再利用）
#   - tmux new-window を呼ばない（新規 window を作らない）
#   - PROMPT 必須（無ければ exit 1）
#   - 既存 window が無ければ exit 1（session-comm を呼ばない）
#   - spawn 専用オプション（--model / --disallowed-tools 等）との併用は exit 1
#   - inject-file 失敗（read-back 未確認）は exit 1 で偽成功を出さない

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
CLD_SPAWN="$SCRIPT_DIR/cld-spawn"

setup() {
    SANDBOX="$(mktemp -d)"
    export FAKE_BIN="$SANDBOX/bin"
    mkdir -p "$FAKE_BIN"

    export NEWWIN_LOG="$SANDBOX/newwin.log"; : > "$NEWWIN_LOG"
    export INJECT_ARGS_FILE="$SANDBOX/inject-args.txt"

    # tmux スタブ: list-windows で既存 window 一覧を返す（_win_exists 用）。new-window は記録して検出。
    cat > "$FAKE_BIN/tmux" <<'TMUX_STUB'
#!/bin/bash
case "${1:-}" in
    list-windows) printf '%s\n' ${EXISTING_WINDOWS:-target-win} ;;
    new-window)   echo "NEW_WINDOW_CALLED $*" >> "$NEWWIN_LOG" ;;
    display-message) echo "main" ;;
esac
exit 0
TMUX_STUB
    chmod +x "$FAKE_BIN/tmux"

    export STUB_SCRIPTS="$SANDBOX/scripts"
    mkdir -p "$STUB_SCRIPTS/lib"
    cat > "$STUB_SCRIPTS/session-name.sh" <<'SESSION_STUB'
generate_window_name() { echo "cld-spawn-test"; }
find_existing_window()  { echo ""; }
SESSION_STUB
    touch "$STUB_SCRIPTS/window-manifest.sh"
    cp "$SCRIPT_DIR/lib/session-env.sh" "$STUB_SCRIPTS/lib/session-env.sh"

    # session-comm.sh スタブ: inject-file の argv を記録し、INJECT_STUB_EXIT で終了コードを制御
    cat > "$STUB_SCRIPTS/session-comm.sh" <<COMM_STUB
#!/bin/bash
printf '%s\n' "\$@" > "$INJECT_ARGS_FILE"
exit "\${INJECT_STUB_EXIT:-0}"
COMM_STUB
    chmod +x "$STUB_SCRIPTS/session-comm.sh"

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

# ===========================================================================
# 正常系
# ===========================================================================

@test "inject-existing: 既存 window へ inject-file を呼び exit 0（read-back 付き）" {
    EXISTING_WINDOWS="target-win" \
        run bash "$STUB_SCRIPTS/cld-spawn" --inject-existing target-win "hello prompt"
    [[ "$status" -eq 0 ]] || fail "exit 0 期待, got $status. $output"
    [[ "$output" == *"prompt injected → 'target-win' (existing)"* ]] \
        || fail "成功メッセージが無い: $output"
    # session-comm inject-file が対象 window + read-back 付きで呼ばれた
    run cat "$INJECT_ARGS_FILE"
    [[ "$output" == *"inject-file"* ]] || fail "inject-file 未呼び出し: $output"
    [[ "$output" == *"target-win"* ]] || fail "対象 window が渡っていない: $output"
    [[ "$output" == *"--wait"* ]] || fail "--wait が無い: $output"
    [[ "$output" == *"--confirm-receipt"* ]] || fail "--confirm-receipt(read-back) が無い: $output"
}

@test "inject-existing: 新規 window を作らない（tmux new-window を呼ばない）" {
    EXISTING_WINDOWS="target-win" \
        run bash "$STUB_SCRIPTS/cld-spawn" --inject-existing target-win "hello"
    [[ "$status" -eq 0 ]] || fail "exit 0 期待, got $status. $output"
    run cat "$NEWWIN_LOG"
    [[ -z "$output" ]] || fail "new-window が呼ばれてしまった: $output"
}

# ===========================================================================
# バリデーション
# ===========================================================================

@test "inject-existing: PROMPT が無ければ exit 1" {
    EXISTING_WINDOWS="target-win" \
        run bash "$STUB_SCRIPTS/cld-spawn" --inject-existing target-win
    [[ "$status" -eq 1 ]] || fail "PROMPT 無しで exit 1 期待, got $status. $output"
    [[ "$output" == *"PROMPT が必須"* ]] || fail "PROMPT 必須エラーが無い: $output"
    [[ ! -f "$INJECT_ARGS_FILE" ]] || fail "PROMPT 無しなのに inject-file が呼ばれた"
}

@test "inject-existing: 既存 window が無ければ exit 1・inject しない" {
    EXISTING_WINDOWS="some-other-win" \
        run bash "$STUB_SCRIPTS/cld-spawn" --inject-existing target-win "hello"
    [[ "$status" -eq 1 ]] || fail "不在 window で exit 1 期待, got $status. $output"
    [[ "$output" == *"見つかりません"* ]] || fail "不在エラーが無い: $output"
    [[ ! -f "$INJECT_ARGS_FILE" ]] || fail "不在 window なのに inject-file が呼ばれた"
}

@test "inject-existing: bare 名が複数 session に一致すると曖昧 error・inject しない（#4 修正）" {
    # EXISTING_WINDOWS に同名を 2 つ → list-windows が 2 行返し曖昧一致（先頭一致誤注入を防ぐ）
    EXISTING_WINDOWS="target-win target-win" \
        run bash "$STUB_SCRIPTS/cld-spawn" --inject-existing target-win "hello"
    [[ "$status" -eq 1 ]] || fail "曖昧 window で exit 1 期待, got $status. $output"
    [[ "$output" == *"複数 session に一致"* ]] || fail "曖昧エラーが無い: $output"
    [[ ! -f "$INJECT_ARGS_FILE" ]] || fail "曖昧なのに inject-file が呼ばれた（誤 window 注入の恐れ）"
}

@test "inject-existing: --model との併用は exit 1（spawn 専用オプション）" {
    EXISTING_WINDOWS="target-win" \
        run bash "$STUB_SCRIPTS/cld-spawn" --inject-existing target-win --model sonnet "hello"
    [[ "$status" -eq 1 ]] || fail "--model 併用で exit 1 期待, got $status. $output"
    [[ "$output" == *"併用できません"* ]] || fail "併用エラーが無い: $output"
    [[ "$output" == *"--model"* ]] || fail "衝突オプション名 --model が示されない: $output"
}

@test "inject-existing: --disallowed-tools との併用は exit 1" {
    EXISTING_WINDOWS="target-win" \
        run bash "$STUB_SCRIPTS/cld-spawn" --inject-existing target-win --disallowed-tools AskUserQuestion "hi"
    [[ "$status" -eq 1 ]] || fail "--disallowed-tools 併用で exit 1 期待, got $status. $output"
    [[ "$output" == *"併用できません"* ]] || fail "併用エラーが無い: $output"
}

@test "inject-existing: --force-new / --bd-id との併用も exit 1" {
    EXISTING_WINDOWS="target-win" \
        run bash "$STUB_SCRIPTS/cld-spawn" --inject-existing target-win --force-new "hi"
    [[ "$status" -eq 1 ]] || fail "--force-new 併用で exit 1 期待, got $status. $output"
    EXISTING_WINDOWS="target-win" \
        run bash "$STUB_SCRIPTS/cld-spawn" --inject-existing target-win --bd-id ccs-1 "hi"
    [[ "$status" -eq 1 ]] || fail "--bd-id 併用で exit 1 期待, got $status. $output"
}

# ===========================================================================
# 送達失敗（read-back 未確認）は偽成功を出さない
# ===========================================================================

@test "inject-existing: inject-file が全試行失敗なら exit 1・偽成功を出さない" {
    EXISTING_WINDOWS="target-win" INJECT_STUB_EXIT=1 CLD_INJECT_ATTEMPTS=1 \
        run bash "$STUB_SCRIPTS/cld-spawn" --inject-existing target-win "hello"
    [[ "$status" -eq 1 ]] || fail "送達失敗で exit 1 期待, got $status. $output"
    [[ "$output" == *"送達に失敗"* ]] || fail "送達失敗メッセージが無い: $output"
    [[ "$output" != *"prompt injected"* ]] || fail "失敗なのに偽の prompt injected を出した: $output"
}
