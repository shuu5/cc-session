#!/usr/bin/env bats
# session-comm-queued.bats — cmd_inject_file read-back の queued 受理（exit 5）unit tests（ccs-3bj）
#
# 背景（orch-uwv6 / bd ccs-3bj）: 宛先 window が turn 処理中（busy）のとき、detect_state が
# spinner 非可視フレームで input-waiting へ誤フォールバックし paste が走る。paste+Enter は CC の
# message queue に積まれる（transcript echo は turn 終了まで出ない）。旧 read-back は queued を
# 表現できず vanished 2 連続 or budget 失効で偽 exit 4 → 呼出側の再送で重複 queue。
#
# 本 WF の修正（加算分岐のみ・既存 vanished/(A)/(B)/(B') 述語は不変）:
#   queued 受理述語 = (1)cls 0（interior 空）∧ (2)live turn 観測（saw_live_turn）∧
#   (3)queued 固有 pane マーカー可視 ∧ (4)sentinel 未 echo の**積極証拠**でのみ成立し exit 5 を返す。
#   証拠不在（marker 不可視 / live turn 未観測 / env 無効化）なら不発→vanished→exit 4（安全側＝再送）。
#
# ★★ pane 形状の仮定は cell 内 live 未確認（description [uncertain]）★★
#   busy 宛先で queued message がどう表示されるか（dim / placeholder / 専用 glyph）は live e2e 未確認。
#   本テストは queued マーカーを SESSION_COMM_QUEUED_MARKER_RE で明示注入して exit-code plumbing を
#   決定論 pin する（＝acceptance(3) の live 検証には数えない）。複数の表示仮説を別ケースで pin し、
#   いずれの仮説でも「マーカー不在なら安全側（silent 消失より二重投入＝再送 exit 4）へ倒れる」ことを固定する。
#
# スタブは session-comm-readback.bats と同型（MOCK_STATE/MOCK_BASELINE/MOCK_PANE/MOCK_PANE_AFTER[_N]）。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
COMM="$SCRIPT_DIR/session-comm.sh"

# live turn 可視フレーム（強マーカー "esc to interrupt" + 入力欄 box）＝saw_live_turn を立てる
STRONG_PANE=$'✻ Churning… (esc to interrupt)\n╭──────────────╮\n│ ❯            │\n╰──────────────╯'
# 空の入力欄 box（interior は ❯ のみ＝cls 0 DELIVERED）
EMPTY_BOX=$'╭──────────────╮\n│ ❯            │\n╰──────────────╯'

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
    # lock dir を書込可な場所へ（allowlist は /tmp・$XDG_RUNTIME_DIR。OS sandbox 下では /tmp が
    # read-only になりうるため $TMPDIR〔=/tmp/... で allowlist の /tmp/* に合致〕へ逃がす。normal CI では
    # /tmp で無害・挙動不変）。
    export SESSION_COMM_LOCK_DIR="${TMPDIR:-/tmp}"

    PROMPT_FILE="$SANDBOX/prompt.txt"
    printf 'hello world\n' > "$PROMPT_FILE"   # sentinel = "hello world"（>=8 字・single-line）

    unset MOCK_STATE MOCK_BASELINE MOCK_PANE MOCK_PANE_AFTER MOCK_PANE_AFTER_N SESSION_COMM_QUEUED_MARKER_RE || true
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

# =============================================================================
# queued 受理（exit 5）— exit-code plumbing の決定論 pin
# =============================================================================

@test "queued: live turn 観測→spinner 消失+queued マーカー+空 box+sentinel 未 echo＝exit 5（ccs-3bj）" {
    # 仮定: queued message は pane に "message queued" 行として現れる（live 未確認・明示注入で決定論化）。
    export MOCK_BASELINE=""
    export MOCK_PANE="$STRONG_PANE"                    # iter1: live turn 可視→saw_live_turn=1
    export MOCK_PANE_AFTER_N=3
    export MOCK_PANE_AFTER=$'message queued\n'"$EMPTY_BOX"  # iter2+: spinner 消失+queued マーカー+空 box
    export SESSION_COMM_QUEUED_MARKER_RE="message queued"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 5 ]
    [[ "$output" == *"queued"* ]]
}

@test "GATE-R1 赤→緑 pin: 既定 OFF（env 未設定）× live turn × post-baseline 'will be sent' 散文 × sentinel 全 pane 不在（真の消失）→ exit 4（偽 exit5 封鎖）" {
    # admin GATE ROUND-1 CONFIRMED の fail-open を封鎖する回帰 pin。旧（汎用語 default-on）: baseline 捕捉**後**に
    # running turn が stream する散文に 'will be sent' が新規 echo される × sticky saw_live_turn × 真の消失
    # （cls0・sentinel 全 pane 不在）の合流で偽 exit5（再送禁止＝silent 消失＝不変量反転）が可到達だった。
    # fix: 既定 OFF（opt-in）で本経路が無効化され、真の消失は既存 vanished→exit4（再送＝安全側）へ倒れる。
    export MOCK_BASELINE=""                                          # 'will be sent' は post-baseline の新規語
    export MOCK_PANE="$STRONG_PANE"                                  # iter1: live turn 観測→saw_live_turn=1（sticky）
    export MOCK_PANE_AFTER_N=3
    export MOCK_PANE_AFTER=$'the request will be sent to the model shortly\n'"$EMPTY_BOX"  # running turn の散文＋空 box・sentinel 不在
    # ★env 未設定＝既定 OFF（SESSION_COMM_QUEUED_MARKER_RE を export しない）
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 4 ]
}

@test "opt-in pin: 既定 OFF では valid な queued マーカーが outside 新規 echo でも queued 不発→exit 4（GATE-R1 mandate1）" {
    # env 未設定なら _rb_queued_re='' ＝本経路 OFF。queued 実表示様の marker が outside に新規 echo され live turn
    # 観測済み・空 box・sentinel 未 echo でも、opt-in（env 非空 set）でない限り受理せず vanished→exit4（旧挙動＝
    # 安全側）。「非空 set のときのみ有効」の不変量を pin する。
    export MOCK_BASELINE=""
    export MOCK_PANE="$STRONG_PANE"
    export MOCK_PANE_AFTER_N=3
    export MOCK_PANE_AFTER=$'message queued\n'"$EMPTY_BOX"
    # ★env 未設定＝既定 OFF
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 4 ]
}

@test "queued: 別の表示仮説 'will be sent' でも上書き regex 一致で受理＝exit 5" {
    # 表示形態は live 未確認ゆえ、別仮説（'will be sent after the current turn'）も上書きで pin。
    export MOCK_BASELINE=""
    export MOCK_PANE="$STRONG_PANE"
    export MOCK_PANE_AFTER_N=3
    export MOCK_PANE_AFTER=$'will be sent after the current turn\n'"$EMPTY_BOX"
    export SESSION_COMM_QUEUED_MARKER_RE="will be sent"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 5 ]
}

# =============================================================================
# 安全側 fallback（証拠不在→exit 4＝再送＝silent 消失より二重投入）
# =============================================================================

@test "safe-side: queued マーカー不在（空 box のみ）→ vanished→exit 4（再送側・silent 消失にしない）" {
    # 仮定が外れて queued マーカーが pane に無い場合、queued は不発→既存 vanished 述語が exit 4 で再送を促す。
    export MOCK_BASELINE=""
    export MOCK_PANE="$STRONG_PANE"                    # live turn は観測するが…
    export MOCK_PANE_AFTER_N=3
    export MOCK_PANE_AFTER="$EMPTY_BOX"                # …マーカーが無い→queued 不発→vanished
    export SESSION_COMM_QUEUED_MARKER_RE="message queued"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 4 ]
}

@test "safe-side: SESSION_COMM_QUEUED_MARKER_RE='' で queued 検知を無効化→exit 4（旧挙動）" {
    # env が set かつ空＝queued 検知 disable。マーカーが見えていても受理せず vanished→exit 4 へ倒す。
    export MOCK_BASELINE=""
    export MOCK_PANE="$STRONG_PANE"
    export MOCK_PANE_AFTER_N=3
    export MOCK_PANE_AFTER=$'message queued\n'"$EMPTY_BOX"
    export SESSION_COMM_QUEUED_MARKER_RE=""
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 4 ]
}

@test "safe-side pin(baseline-newness): マーカーが baseline に既存（静的 transcript の一般語）は受理しない→exit 4（偽 exit 5＝silent 消失を封鎖・ccs-3bj major fix）" {
    # 回帰 pin（confirmed major finding）: 既定 regex は 'will be sent' 等の一般英語句で、静的 transcript
    # （前 turn 出力・running turn ストリーム）に居るだけで pane 全走査 grep に一致し偽 exit 5 を招いた。
    # baseline-newness 要件（マーカー行が baseline に逐語存在するなら新規 echo でない＝積極証拠にしない）で
    # 構造排除する。ここでは live turn を観測（saw_live_turn=1）し空 box + sentinel 未 echo でも、marker が
    # baseline に既存なら queued 不発→vanished→exit 4（安全側＝再送＝silent 消失にしない）。
    export MOCK_BASELINE=$'will be sent\n'"$EMPTY_BOX"     # マーカーが paste 前から静的に存在（新規性なし）
    export MOCK_PANE="$STRONG_PANE"                        # iter1: live turn 観測→saw_live_turn=1
    export MOCK_PANE_AFTER_N=3
    export MOCK_PANE_AFTER=$'will be sent\n'"$EMPTY_BOX"   # baseline と同一 marker 行＝新規 echo でない
    export SESSION_COMM_QUEUED_MARKER_RE="will be sent"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 4 ]
}

@test "safe-side pin(KEY): live turn 未観測なら queued マーカーがあっても受理しない→exit 4（boot-race 非誤判定）" {
    # boot splash は timer-spinner を出さない＝saw_live_turn=0。queued マーカー様の文字列が pane に
    # 偶発包含されても、live turn の積極証拠が無い限り queued として受理してはならない（silent 消失防止）。
    export MOCK_BASELINE=""
    export MOCK_PANE=$'message queued\n'"$EMPTY_BOX"   # マーカーはあるが strong turn は一度も観測されない
    export SESSION_COMM_QUEUED_MARKER_RE="message queued"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 4 ]
}

# =============================================================================
# 優先順（既存受理述語を queued が shadow しないこと）
# =============================================================================

@test "priority: sentinel が transcript に echo 済み（clean submit）は (B) が先に受理＝exit 0（queued マーカー併存でも）" {
    # (B) echo-outside は queued 分岐より前に評価される。sentinel が outside に載れば clean submit＝exit 0。
    export MOCK_BASELINE=""
    export MOCK_PANE="$STRONG_PANE"
    export MOCK_PANE_AFTER_N=3
    export MOCK_PANE_AFTER=$'> hello world\nmessage queued\n'"$EMPTY_BOX"  # sentinel echo + マーカー併存
    export SESSION_COMM_QUEUED_MARKER_RE="message queued"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]
}

@test "priority: 強 processing 2 連続（clean turn）は (A) が exit 0（queued より優先・回帰なし）" {
    # (A) は strong_streak>=2 で exit 0。queued は (A) が 2 連続を得られない flicker のときだけ働く。
    export MOCK_BASELINE=""
    export MOCK_PANE="$STRONG_PANE"                    # 常に強マーカー可視＝2 連続で (A) 受理
    export SESSION_COMM_QUEUED_MARKER_RE="message queued"
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]
}
