#!/usr/bin/env bats
# session-comm-readback.bats — cmd_inject_file の送達 read-back（--confirm-receipt / --clear-first）unit tests
#
# ccs-ldt: tmux 層 paste 成功だけでは成功扱いにしない。
# ccs-mxv（orch-ttqe）: 受理は submit（turn 開始）の**積極証拠のみ**——
#   (A) 強 processing マーカー（esc to interrupt / thinking / compaction）の pane 直読 2 連続
#   (B) echo-outside-interior（sentinel が入力欄 interior の外＝transcript に出現 ∧ baseline 不在）
# sentinel-presence 単独（到着の証拠）と state==processing（detect_state の既定 fallthrough＝splash も
# processing と読める弱い証拠）では受理しない。boot-race（promo/再描画が Enter を食う）の偽陽性を pin する。
#
# スタブ:
#   - MOCK_STATE: session-state.sh state の返り値（既定 input-waiting）
#   - MOCK_BASELINE: capture-pane 1 回目（paste 前 baseline）
#   - MOCK_PANE: capture-pane 2 回目以降の pane 内容
#   - MOCK_PANE_AFTER / MOCK_PANE_AFTER_N: capture 回数 >= N で MOCK_PANE_AFTER へ切替（2 相シーケンス）
#   - MOCK_PANE_ALT: 指定時は capture 回数の偶奇で MOCK_PANE / MOCK_PANE_ALT を交互に返す（振動系）

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
COMM="$SCRIPT_DIR/session-comm.sh"

# 強 processing マーカー（session-state.sh SSOT の一部・テストでは literal で使用）
STRONG="✻ Churning… (esc to interrupt)"
# 空の入力欄 box（interior は ❯ のみ＝DELIVERED）
EMPTY_BOX=$'╭──────────────╮\n│ ❯            │\n╰──────────────╯'
# prompt（hello world）が残留した入力欄 box（interior に sentinel＝RESIDUAL）
RESIDUAL_BOX=$'╭──────────────╮\n│ ❯ hello world │\n╰──────────────╯'

setup() {
    SANDBOX="$(mktemp -d)"
    mkdir -p "$SANDBOX/bin" "$SANDBOX/mock_scripts"
    export TMUX_CALL_LOG="$SANDBOX/tmux_calls.log"
    : > "$TMUX_CALL_LOG"

    export CAP_COUNTER="$SANDBOX/cap_counter"; echo 0 > "$CAP_COUNTER"
    cat > "$SANDBOX/bin/tmux" <<'TMUX_EOF'
#!/bin/bash
echo "$*" >> "$TMUX_CALL_LOG"
case "$1" in
    -V) echo "tmux 3.4" ;;
    has-session) exit 0 ;;
    display-message) echo "session:0" ;;
    capture-pane)
        c=$(cat "$CAP_COUNTER" 2>/dev/null || echo 0); c=$((c + 1)); echo "$c" > "$CAP_COUNTER"
        if [[ "$c" -eq 1 ]]; then
            printf '%s\n' "${MOCK_BASELINE:-}"
        elif [[ -n "${MOCK_PANE_ALT:-}" ]]; then
            if (( c % 2 == 0 )); then printf '%s\n' "${MOCK_PANE:-}"; else printf '%s\n' "${MOCK_PANE_ALT:-}"; fi
        elif [[ -n "${MOCK_PANE_AFTER_N:-}" ]] && (( c >= MOCK_PANE_AFTER_N )); then
            printf '%s\n' "${MOCK_PANE_AFTER:-}"
        else
            printf '%s\n' "${MOCK_PANE:-}"
        fi
        ;;
    *) exit 0 ;;
esac
TMUX_EOF
    chmod +x "$SANDBOX/bin/tmux"

    # mock session-state.sh: wait は常に成功、state は $MOCK_STATE を返す（既定 input-waiting）
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "${MOCK_STATE:-input-waiting}"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    export PATH="$SANDBOX/bin:$PATH"
    export _TEST_MODE=1
    export SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts"

    PROMPT_FILE="$SANDBOX/prompt.txt"
    printf 'hello world\n' > "$PROMPT_FILE"

    unset MOCK_STATE MOCK_BASELINE MOCK_PANE MOCK_PANE_ALT MOCK_PANE_AFTER MOCK_PANE_AFTER_N || true
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

# Enter 送出（tmux send-keys ... Enter）の回数を数える（初回 paste 後の Enter で必ず 1 以上）
_enter_count() {
    grep -cE 'send-keys.*Enter$' "$TMUX_CALL_LOG" || true
}

# =============================================================================
# 受理（positive proof）
# =============================================================================

@test "read-back: 強 processing マーカー 2 連続で受理＝exit 0（A）" {
    export MOCK_STATE=input-waiting            # state 経路は使わない（pane 直読で受理）
    export MOCK_PANE="$STRONG"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]
}

@test "read-back: echo-outside-interior で受理＝exit 0（B・fast-complete 救済）" {
    export MOCK_STATE=input-waiting
    export MOCK_BASELINE=""
    export MOCK_PANE=$'> hello world\n'"$EMPTY_BOX"   # transcript に echo・入力欄は空
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]
}

@test "read-back: 単発 error は即 break せず、後続の強 processing で受理＝exit 0（ccs-e0i item3）" {
    export STATE_COUNTER="$SANDBOX/state_counter"; echo 0 > "$STATE_COUNTER"
    export MOCK_PANE="noise"
    export MOCK_PANE_AFTER_N=3; export MOCK_PANE_AFTER="$STRONG"
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then
    n=$(cat "$STATE_COUNTER" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STATE_COUNTER"
    if [[ "$n" -eq 1 ]]; then echo "error"; else echo "input-waiting"; fi
fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 5
    [ "$status" -eq 0 ]
}

@test "read-back: 単発 exited も即 break せず、後続の強 processing で受理＝exit 0（ccs-e0i item3）" {
    export STATE_COUNTER="$SANDBOX/state_counter"; echo 0 > "$STATE_COUNTER"
    export MOCK_PANE="noise"
    export MOCK_PANE_AFTER_N=3; export MOCK_PANE_AFTER="$STRONG"
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then
    n=$(cat "$STATE_COUNTER" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STATE_COUNTER"
    if [[ "$n" -eq 1 ]]; then echo "exited"; else echo "input-waiting"; fi
fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 5
    [ "$status" -eq 0 ]
}

# =============================================================================
# 偽陽性の封鎖（boot-race pin・orch-ttqe acceptance）
# =============================================================================

@test "boot-race pin: state==processing だけでは受理しない（splash は fallthrough で processing と読める）" {
    # detect_state の既定 fallthrough は processing。splash 滞留（強マーカーも ❯ も無い pane）で
    # state だけ processing を返し続けても、submit の積極証拠が無い限り受理してはならない。
    export MOCK_STATE=processing
    export MOCK_PANE="Welcome to Claude Code"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
}

@test "boot-race pin: 入力欄残留の sentinel では受理しない（到着 ≠ submit）＋救済 Enter が撃たれる" {
    # 旧実装: sentinel が pane に出現し baseline に無い→即受理（偽陽性）。
    # 新実装: interior 残留＝RESIDUAL は「未 submit」の積極証明→受理せず救済 Enter（DJ-b）。
    export MOCK_STATE=input-waiting
    export MOCK_BASELINE=""
    export MOCK_PANE="$RESIDUAL_BOX"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
    # 初回 Enter(1) + 救済 Enter(>=1)
    [ "$(_enter_count)" -ge 2 ]
}

@test "boot-race pin: 残留 → 救済 Enter → 強 processing で回復受理＝exit 0" {
    export MOCK_STATE=input-waiting
    export MOCK_PANE="$RESIDUAL_BOX"
    export MOCK_PANE_AFTER_N=3; export MOCK_PANE_AFTER="$STRONG"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 5
    [ "$status" -eq 0 ]
    [ "$(_enter_count)" -ge 2 ]
}

@test "boot-race pin: 一過性 sentinel（box 無しの生テキスト）→ 消失は受理せず早期 fail＝exit 4" {
    # boot 中の TUI 再描画: paste が一瞬生テキストで見え（interior 特定不能＝判定保留）、
    # その後 pane から全消失（空 box のみ）。旧実装は一過性フレームの sentinel で即受理していた。
    export MOCK_STATE=input-waiting
    export MOCK_BASELINE=""
    export MOCK_PANE="hello world"                       # 一過性フレーム（box 無し）
    export MOCK_PANE_AFTER_N=3; export MOCK_PANE_AFTER="$EMPTY_BOX"   # 消失（空入力欄のみ）
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 6
    [ "$status" -eq 4 ]
}

@test "boot-race pin: baseline に既にある sentinel では受理しない（baseline 差分が必須）" {
    export MOCK_STATE=input-waiting
    export MOCK_BASELINE=$'> hello world\n'"$EMPTY_BOX"
    export MOCK_PANE=$'> hello world\n'"$EMPTY_BOX"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 1
    [ "$status" -eq 4 ]
}

# =============================================================================
# RESIDUAL / INCONCLUSIVE の規律（DJ-b）
# =============================================================================

@test "read-back: 折りたたみ placeholder は RESIDUAL 扱い＝救済 Enter → 強 processing で受理（un-iur 保持）" {
    export MOCK_STATE=input-waiting
    export MOCK_PANE=$'╭──────────────╮\n│ ❯ [Pasted text #1 +25 lines] │\n╰──────────────╯'
    export MOCK_PANE_AFTER_N=3; export MOCK_PANE_AFTER="$STRONG"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 5
    [ "$status" -eq 0 ]
    [ "$(_enter_count)" -ge 2 ]
}

@test "read-back: ダイアログが interior を占める場合（INCONCLUSIVE）は Enter を撃たない（DJ-b）" {
    # ダイアログへの空 Enter は既定選択の確定＝実アクションになるため、RESIDUAL（自分の注入テキストの
    # 積極確認）以外では撃たない。初回 paste 後の Enter 1 回のみであること。
    export MOCK_STATE=input-waiting
    export MOCK_PANE=$'╭──────────────╮\n│ Do you want to proceed? 1. Yes 2. No │\n╰──────────────╯'
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
    [ "$(_enter_count)" -eq 1 ]
}

# =============================================================================
# streak 規律（flicker 除去・リセット固定）
# =============================================================================

@test "read-back: 強 processing 単発では受理しない（2 連続要求で flicker を除去）" {
    export MOCK_STATE=input-waiting
    export MOCK_PANE="$STRONG"
    export MOCK_PANE_AFTER_N=3; export MOCK_PANE_AFTER="noise"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
}

@test "read-back: 強 processing の非連続振動は受理しない（streak リセット固定＝fail-open 回帰防護）" {
    # 強マーカーが交互にしか見えない（strong→noise→strong→…）場合、非連続の lone 観測を
    # 「2 連続」と誤計上して受理する fail-open を封じる（streak リセットの mutation 検出）。
    export MOCK_STATE=input-waiting
    export MOCK_PANE="$STRONG"
    export MOCK_PANE_ALT="noise"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
}

@test "read-back: state=error は 2 連続で fail（持続 error＝exit 4）" {
    export MOCK_STATE=error
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 4 ]
}

@test "read-back: state=exited も 2 連続で fail（持続 exited＝exit 4）" {
    export MOCK_STATE=exited
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 4 ]
}

@test "read-back: budget 内に積極証拠なし（input-waiting のまま）なら未着＝exit 4" {
    export MOCK_STATE=input-waiting
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 1
    [ "$status" -eq 4 ]
    [[ "$output" == *"not confirmed received"* ]]
}

# =============================================================================
# 経路・引数の回帰（既存）
# =============================================================================

@test "back-compat: --confirm-receipt 未指定なら read-back せず exit 0（state が processing でなくても）" {
    export MOCK_STATE=input-waiting
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 0 ]
}

@test "clear-first: paste 前に C-u（send-keys）を送る" {
    export MOCK_PANE="$STRONG"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3 --clear-first
    [ "$status" -eq 0 ]
    grep -qE 'send-keys.*C-u' "$TMUX_CALL_LOG"
}

@test "clear-first 未指定なら C-u を送らない（既定）" {
    export MOCK_PANE="$STRONG"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]
    ! grep -qE 'send-keys.*C-u' "$TMUX_CALL_LOG"
}

@test "read-back: --confirm-receipt は正の整数を要求する" {
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --confirm-receipt 0
    [ "$status" -ne 0 ]
    [[ "$output" == *"positive integer"* ]]
}

@test "read-back: --no-enter 時は read-back しない（Enter 未送出）" {
    export MOCK_STATE=input-waiting
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 1 --no-enter
    [ "$status" -eq 0 ]
}

@test "read-back: 空白のみ prompt でも sentinel 導出で abort しない（paste まで到達・回帰）" {
    printf '   \n\t\n' > "$PROMPT_FILE"
    export MOCK_PANE="$STRONG"               # 受理は強マーカー経由（sentinel は空で無効）
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]
    grep -qE 'paste-buffer' "$TMUX_CALL_LOG"
}

@test "read-back: 完全空 prompt でも abort しない（grep no-match の set -e 回帰）" {
    : > "$PROMPT_FILE"
    export MOCK_PANE="$STRONG"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]
    grep -qE 'paste-buffer' "$TMUX_CALL_LOG"
}

@test "boot-race pin: boot スピナー語彙（Loading…）では受理しない（強マーカーは turn 固有限定・e2e 実測反映）" {
    # THINKING_PROGRESS_PATTERN（英語進行形+…）は boot スピナー（Loading…/Starting…/Baking… 等）にも
    # 一致するため受理条件に使えない。boot 中の 2 連続偽成立で RESIDUAL 分岐に到達する前に偽受理し、
    # spawn kickoff が silent 消失する（live e2e で再現）。turn 固有の esc to interrupt / compaction のみ許す。
    export MOCK_STATE=processing
    export MOCK_PANE="Loading…"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
}

@test "boot-race pin: Baking…/Initializing… 等の boot 語彙でも受理しない" {
    export MOCK_STATE=processing
    export MOCK_PANE=$'Baking…\nInitializing…'
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
}
