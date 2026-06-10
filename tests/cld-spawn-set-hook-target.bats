#!/usr/bin/env bats
# cld-spawn-set-hook-target.bats — manifest tombstone set-hook を dot-safe な window_id で参照する
#
# 背景（admin live finding, un-cbi）: bd 階層 id（dotted、例 un-3sh.3.5）の window 名
# `wt-un-3sh.3.5` は tmux の -t ターゲット構文（`.` = window.pane 区切り）と衝突し、
# `-t <名前>` の send-keys/capture-pane/set-hook が "can't find pane" で失敗しうる
# （独立 socket で実証）。cld-spawn は set-hook を **不変な window_id(@N)** で参照することで
# dotted 名でも確実に紐づける（id 解決不能時のみ名前へフォールバック＝後方互換）。
#
# NB: 送達(session-comm.sh)・状態(session-state.sh)は resolve_target で名前→session:index を
#     先に解決済み＝既に dot-safe。fleet-monitor の照合も name 文字列一致で dot-safe。
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
CLD_SPAWN="$SCRIPT_DIR/cld-spawn"

setup() {
    SANDBOX="$(mktemp -d)"
    export LAUNCHER_PATH="$SANDBOX/launcher.sh"
    export FAKE_BIN="$SANDBOX/bin"
    export TMUX_LOG="$SANDBOX/tmux"
    mkdir -p "$FAKE_BIN"
    # window_id は runtime にこのファイルから読む（テストが上書きしてフォールバックを検証できる）
    echo "@9" > "${TMUX_LOG}.wid"

    # tmux stub: new-window 記録、list-windows は -F 形式で出し分け、set-hook の -t を記録。
    # ${TMUX_LOG} のみ setup 時に展開、その他（$win/$wid/$@）は runtime 評価（\$ でエスケープ）。
    cat > "$FAKE_BIN/tmux" <<TMUX_STUB
#!/bin/bash
sub="\${1:-}"; shift || true
args="\$*"
case "\$sub" in
    new-window)
        prev=""
        for a in "\$@"; do
            [[ "\$prev" == "-n" ]] && echo "\$a" > "${TMUX_LOG}.winname"
            prev="\$a"
        done
        ;;
    list-windows)
        win=\$(cat "${TMUX_LOG}.winname" 2>/dev/null || echo "fallback")
        wid=\$(cat "${TMUX_LOG}.wid" 2>/dev/null)
        if [[ "\$args" == *'#{window_id}'*'#{window_name}'* ]]; then
            if [[ -n "\$wid" ]]; then echo "\$wid \$win"; else echo "\$win"; fi
        elif [[ "\$args" == *'#{window_name}'*'#{window_index}'* ]]; then
            echo "\$win 1"
        else
            echo "\$win"
        fi
        ;;
    display-message) echo "main" ;;
    set-hook)
        prev=""
        for a in "\$@"; do
            [[ "\$prev" == "-t" ]] && echo "\$a" >> "${TMUX_LOG}.sethook"
            prev="\$a"
        done
        ;;
esac
exit 0
TMUX_STUB
    chmod +x "$FAKE_BIN/tmux"

    cat > "$FAKE_BIN/mktemp" <<MKTEMP_STUB
#!/bin/bash
if [[ "\$*" == *"cld-spawn-XXXXXX.sh"* ]]; then
    touch "${LAUNCHER_PATH}"; echo "${LAUNCHER_PATH}"
else
    /usr/bin/mktemp "\$@"
fi
MKTEMP_STUB
    chmod +x "$FAKE_BIN/mktemp"

    printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/flock"; chmod +x "$FAKE_BIN/flock"

    export STUB_SCRIPTS="$SANDBOX/scripts"
    mkdir -p "$STUB_SCRIPTS/lib"
    cp "$SCRIPT_DIR/session-name.sh" "$STUB_SCRIPTS/session-name.sh"
    cat >> "$STUB_SCRIPTS/session-name.sh" <<'SS'
generate_window_name() { echo "semantic-fallback-name"; }
find_existing_window()  { echo ""; }
SS
    cp "$SCRIPT_DIR/lib/session-env.sh" "$STUB_SCRIPTS/lib/session-env.sh"
    cat > "$STUB_SCRIPTS/window-manifest.sh" <<'WM'
manifest_append_entry() { return 0; }
WM
    printf '#!/bin/bash\nexit 0\n' > "$STUB_SCRIPTS/session-comm.sh"; chmod +x "$STUB_SCRIPTS/session-comm.sh"
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/cld-stub"; chmod +x "$FAKE_BIN/cld-stub"
    export CLD_PATH="$FAKE_BIN/cld-stub"
    cp "$CLD_SPAWN" "$STUB_SCRIPTS/cld-spawn"; chmod +x "$STUB_SCRIPTS/cld-spawn"

    export HOME="$SANDBOX/home"; mkdir -p "$HOME/.local/state/claude-session"
    export TMUX="fake-tmux-socket,12345,0"
    export PATH="$FAKE_BIN:$PATH"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

@test "set-hook: dotted id の window では -t が解決済み window_id(@N)・raw dotted 名でない" {
    run bash "$STUB_SCRIPTS/cld-spawn" --bd-id "un-3sh.3.5"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ -f "${TMUX_LOG}.sethook" ] || { echo "no set-hook recorded"; false; }
    run cat "${TMUX_LOG}.sethook"
    [[ "$output" == *"@9"* ]] || { echo "set-hook targets: $output"; false; }
    [[ "$output" != *"wt-un-3sh.3.5"* ]] || { echo "set-hook used raw dotted name: $output"; false; }
}

@test "set-hook: 非 dotted id でも window_id 参照で記録される" {
    run bash "$STUB_SCRIPTS/cld-spawn" --bd-id "un-cbi"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run cat "${TMUX_LOG}.sethook"
    [[ "$output" == *"@9"* ]] || { echo "set-hook targets: $output"; false; }
    [[ "$output" != *"wt-un-cbi"* ]] || { echo "set-hook used raw name: $output"; false; }
}

@test "set-hook: window_id 解決不能なら window 名へフォールバック（後方互換）" {
    : > "${TMUX_LOG}.wid"   # window_id を空に → _WM_WID 解決不能
    run bash "$STUB_SCRIPTS/cld-spawn" --bd-id "un-cbi"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run cat "${TMUX_LOG}.sethook"
    # フォールバックでは window 名で参照する（id が無いので）
    [[ "$output" == *"wt-un-cbi"* ]] || { echo "fallback did not use name: $output"; false; }
    [[ "$output" != *"@9"* ]] || { echo "unexpected window_id when unresolvable: $output"; false; }
}
