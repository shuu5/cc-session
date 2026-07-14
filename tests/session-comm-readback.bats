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
# 実 turn の pane（強マーカー + 入力欄 box。(A) は入力欄 interior を特定できたフレームの
# outside view のみで評価するため、受理には box の存在が必要——実 TUI は turn 中も常に描画する）
STRONG_PANE=$'✻ Churning… (esc to interrupt)\n╭──────────────╮\n│ ❯            │\n╰──────────────╯' 
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
    export MOCK_PANE="$STRONG_PANE"
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
    export MOCK_PANE_AFTER_N=3; export MOCK_PANE_AFTER="$STRONG_PANE"
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
    export MOCK_PANE_AFTER_N=3; export MOCK_PANE_AFTER="$STRONG_PANE"
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
    export MOCK_PANE_AFTER_N=3; export MOCK_PANE_AFTER="$STRONG_PANE"
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
    export MOCK_PANE_AFTER_N=3; export MOCK_PANE_AFTER="$STRONG_PANE"
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
    export MOCK_PANE="$STRONG_PANE"
    export MOCK_PANE_AFTER_N=3; export MOCK_PANE_AFTER="noise"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
}

@test "read-back: 強 processing の非連続振動は受理しない（streak リセット固定＝fail-open 回帰防護）" {
    # 強マーカーが交互にしか見えない（strong→noise→strong→…）場合、非連続の lone 観測を
    # 「2 連続」と誤計上して受理する fail-open を封じる（streak リセットの mutation 検出）。
    export MOCK_STATE=input-waiting
    export MOCK_PANE="$STRONG_PANE"
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
    export MOCK_PANE="$STRONG_PANE"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3 --clear-first
    [ "$status" -eq 0 ]
    grep -qE 'send-keys.*C-u' "$TMUX_CALL_LOG"
}

@test "clear-first 未指定なら C-u を送らない（既定）" {
    export MOCK_PANE="$STRONG_PANE"
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
    export MOCK_PANE="$STRONG_PANE"          # 受理は強マーカー経由（sentinel は空で無効）
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]
    grep -qE 'paste-buffer' "$TMUX_CALL_LOG"
}

@test "read-back: 完全空 prompt でも abort しない（grep no-match の set -e 回帰）" {
    : > "$PROMPT_FILE"
    export MOCK_PANE="$STRONG_PANE"
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

@test "boot-race pin: ダイアログ文言が marker 断片を偶発包含しても救済 Enter を撃たない（dialog ガード belt・review 反映）" {
    # tail marker（prompt 末尾 24 字）がダイアログ文言に部分一致すると RESIDUAL に誤分類されうる。
    # その場合でも _se_dialog_re ガード（belt）が救済 Enter を抑止する（既定選択の確定＝fail-open 防止）。
    export MOCK_STATE=input-waiting
    export MOCK_PANE=$'╭──────────────╮\n│ Do you want to hello world? 1. Yes 2. No │\n╰──────────────╯'
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
    # 初回 Enter 1 回のみ（RESIDUAL 誤分類でも dialog 可視なら救済 Enter 0 回）
    [ "$(_enter_count)" -eq 1 ]
}

@test "boot-race pin: prompt 本文が強マーカー語を含んでも入力欄残留で受理しない（(A) の interior 除外・round-2 反映）" {
    # (A) を pane 全体で grep すると、prompt 本文の 'Summarizing' 等が未 submit の入力欄残留に
    # ヒットして偽受理する（round-2 review wf_58b5c18e が決定論再現）。(A) は outside view のみを見る。
    printf 'Summarizing logs from the build\n' > "$PROMPT_FILE"
    export MOCK_STATE=input-waiting
    export MOCK_PANE=$'╭──────────────╮\n│ ❯ Summarizing logs from the build │\n╰──────────────╯'
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
    # RESIDUAL として救済 Enter は撃たれる（受理はしない）
    [ "$(_enter_count)" -ge 2 ]
}

@test "boot-race pin: interior 不特定のフレームでは強マーカー語が見えても受理しない（(A) は box 特定が前提）" {
    # boot splash 等で入力欄 box が無いフレームは、生テキストに強マーカー語が見えても積極証拠にしない
    # （入力欄残留と transcript の区別がつかないため）。
    printf 'Summarizing logs from the build\n' > "$PROMPT_FILE"
    export MOCK_STATE=input-waiting
    export MOCK_PANE="Summarizing logs from the build"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
}

@test "read-back: 長文で head が隠れ tail のみ入力欄に可視でも RESIDUAL 検出→救済 Enter（tail marker pin・round-2 反映）" {
    # tail marker（最終非空行の末尾 24 字）の存在意義: 長文 prompt で head（先頭 24 字）が入力欄から
    # 隠れ、cursor が座る tail のみ可視な残留。head 不在・tail 一致で RESIDUAL を検出できること。
    printf 'alpha first line of the long prompt\nmiddle line\nzz-tail-unique-suffix-9\n' > "$PROMPT_FILE"
    export MOCK_STATE=input-waiting
    export MOCK_PANE=$'╭──────────────╮\n│ ❯ zz-tail-unique-suffix-9 │\n╰──────────────╯'
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
    [ "$(_enter_count)" -ge 2 ]
}

@test "boot-race pin: transcript の水平線ペアがあっても残留 corner box を入力欄として扱う（box 誤帰属の封鎖・round-3 反映）" {
    # Type A（罫線ペア）を無条件優先すると transcript の markdown 水平線を入力欄と誤認し、
    # 実在の残留 corner box が outside へ漏れて (B) が偽受理する（round-3 review が決定論再現）。
    # bottom edge がより下の box（=実入力欄）を採用すること。
    export MOCK_STATE=input-waiting
    export MOCK_BASELINE=""
    export MOCK_PANE=$'some transcript here\n──────────────────\nmiddle transcript text\n──────────────────\nmore transcript text\n╭──────────────────╮\n│ ❯ hello world │\n╰──────────────────╯'
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
    [ "$(_enter_count)" -ge 2 ]   # 正しく RESIDUAL → 救済 Enter
}

@test "boot-race pin: transcript の静的な compaction 語（baseline にも存在）では受理しない（(A) の baseline 行差分・round-3 反映）" {
    # Summarizing/Restoring は一般英単語＝既存 transcript の出力に居るだけで (A) が発火してはならない。
    # inject-existing の実流では baseline（paste 前 capture）に同じ transcript が写っている。
    export MOCK_STATE=input-waiting
    export MOCK_BASELINE=$'Summarizing the build logs before the change\nmore transcript'
    export MOCK_PANE=$'Summarizing the build logs before the change\nmore transcript\n╭──────────────────╮\n│ ❯ hello world │\n╰──────────────────╯'
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
    [ "$(_enter_count)" -ge 2 ]
}

@test "read-back: Type A（水平罫線ペア）の入力欄でも RESIDUAL を検出する（実 TUI rules モードの pin）" {
    export MOCK_STATE=input-waiting
    export MOCK_PANE=$'transcript text\n──────────────────\n❯ hello world\n──────────────────\n  status line'
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
    [ "$(_enter_count)" -ge 2 ]
}

@test "read-back: NBSP 入りの空入力欄（Type A）は DELIVERED＝echo-outside-interior 受理が機能する" {
    # 実 CC の空入力欄は「❯ + NBSP」（sc-6vj）。NBSP を除去して空判定できること。
    export MOCK_STATE=input-waiting
    export MOCK_BASELINE=""
    export MOCK_PANE=$'> hello world\n──────────────────\n❯ \xc2\xa0\n──────────────────\n  status line'
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]
}

# --- SSOT 同期（_rb_strong_re ↔ compaction-indicators.sh のドリフト防止・round-4 minor 反映）--------

@test "SSOT 同期: COMPACTION_INDICATORS 全エントリ + esc to interrupt が _rb_strong_re の fallback リテラルに含まれる（drift fail-closed）" {
    # _se_dialog_re の drift pin（session-comm-inject-multiline.bats）に倣う。SSOT に phase 名が
    # 追加されたのに fallback リテラルが追随しないと、source 失敗時の縮退で compaction-accept
    # modality が不完全化する（false-negative→再送二重投入方向）。
    local real_ci="$SCRIPT_DIR/lib/compaction-indicators.sh"
    [ -f "$real_ci" ]
    local fb
    fb=$(grep -E "_rb_strong_re='esc to interrupt" "$SCRIPT_DIR/session-comm.sh" | head -1)
    [ -n "$fb" ]
    run bash -c "source '$real_ci'; printf '%s\n' \"\${COMPACTION_INDICATORS[@]}\""
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    local ind
    while IFS= read -r ind; do
        [[ "$fb" == *"$ind"* ]] || { echo "MISS in fallback literal: $ind"; false; }
    done <<< "$output"
}

@test "read-back: compaction フェーズ名（SSOT 全エントリ）でも受理する（(A) の compaction modality・正例 pin）" {
    # (A) の正例が esc to interrupt に偏ると、導出から compaction 語を落とす mutation を検出できない
    # （round-4 review が mutation 実験で実証）。SSOT の各 phase 名で受理できることを直接 pin する。
    source "$SCRIPT_DIR/lib/compaction-indicators.sh"
    local ind
    for ind in "${COMPACTION_INDICATORS[@]}"; do
        : > "$TMUX_CALL_LOG"; echo 0 > "$CAP_COUNTER"
        export MOCK_STATE=input-waiting
        export MOCK_BASELINE=""
        export MOCK_PANE="${ind}… conversation history"$'\n'"$EMPTY_BOX"
        run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
        [ "$status" -eq 0 ] || { echo "compaction 語 '$ind' で受理されない"; false; }
    done
}

@test "boot-race pin: transcript の corner tool box があっても最下部の Type A 入力欄を選ぶ（A-wins 方向・round-4 反映）" {
    # bottom-most 選択則の A-wins 方向（rules 入力欄が corner tool box より下）。この方向の pin が
    # 無いと『常時 B 選択』mutation が素通りし、残留が outside へ漏れて (B) 偽受理する
    # （round-4 review が mutation 実験で実証）。
    export MOCK_STATE=input-waiting
    export MOCK_BASELINE=""
    export MOCK_PANE=$'╭── tool ──╮\n│ tool output │\n╰──────────╯\nmore transcript\n──────────────────\n❯ hello world\n──────────────────\n  status line'
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 2
    [ "$status" -eq 4 ]
    [ "$(_enter_count)" -ge 2 ]
}
