#!/usr/bin/env bats
# session-comm-inject-multiline.bats — cmd_inject_file の複数行 paste 折りたたみ時の追い Enter（un-iur）unit tests
#
# 問題（un-iur）: 複数行 paste を Claude Code TUI が [Pasted text #N +M lines] に折りたたむ際、
# paste 後の既定 Enter（session_msg send … --enter-only）が paste 折りたたみ処理に吸収され、
# プロンプトが未 submit のまま入力欄に滞留することがある（25 行 paste で観測）。
#
# 修正: paste 後に submit 状態（session-state.sh state が input-waiting を抜けるか）を確認し、
# 未 submit（input-waiting 滞留）なら追い Enter を有界回数送る。
#   - confirm_receipt==0 経路: paste 後に専用ループで追い Enter（dialog 可視時は modality ガードで抑止）。
#   - confirm_receipt>0（read-back）経路（finding#2）: read-back ループ内で input-waiting を観測したら
#     有界の救済 Enter を撃つ（cld-spawn は常に --confirm-receipt 経由＝ここが spawn の主経路）。
#     desync 回避のため processing/error の連続判定ロジックは不変、受理判定には介入しない。
#
# 検証観点:
#   - Enter 吸収再現: paste 後も input-waiting 滞留 → 追い Enter/救済 Enter が送られ確実に submit される。
#   - 二重 submit 防止: submit 済み（processing/sentinel 可視）を観測したら追い Enter/救済 Enter を送らない。
#   - modality ガード: 承認/AskUserQuestion ダイアログ可視時は両経路とも Enter を送らない（既定確定を防ぐ）。
#   - SSOT 同期: _se_dialog_re は session-state.sh:INPUT_WAITING_PATTERNS から導出（手書き複製の drift 防止）。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
COMM="$SCRIPT_DIR/session-comm.sh"

setup() {
    SANDBOX="$(mktemp -d)"
    mkdir -p "$SANDBOX/bin" "$SANDBOX/mock_scripts"
    export TMUX_CALL_LOG="$SANDBOX/tmux_calls.log"
    : > "$TMUX_CALL_LOG"
    export STATE_CALL_LOG="$SANDBOX/state_calls.log"
    : > "$STATE_CALL_LOG"

    # mock tmux: paste/send-keys/load-buffer 等は exit 0、全呼び出しを記録する。
    # send-keys … Enter の回数を数えて追い Enter 挙動を検証する。capture-pane は MOCK_PANE を返す。
    cat > "$SANDBOX/bin/tmux" <<'TMUX_EOF'
#!/bin/bash
echo "$*" >> "$TMUX_CALL_LOG"
case "$1" in
    -V) echo "tmux 3.4" ;;
    has-session) exit 0 ;;
    display-message) echo "session:0" ;;
    capture-pane) printf '%s\n' "${MOCK_PANE:-}" ;;
    *) exit 0 ;;
esac
TMUX_EOF
    chmod +x "$SANDBOX/bin/tmux"

    export PATH="$SANDBOX/bin:$PATH"
    export _TEST_MODE=1
    export SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts"

    # 複数行 prompt（折りたたみ対象を模す）
    PROMPT_FILE="$SANDBOX/prompt.txt"
    printf 'line 1\nline 2\nline 3\nline 4\nline 5\n' > "$PROMPT_FILE"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

# 送られた "send-keys … Enter"（=submit）の回数を数える。
_count_enters() {
    grep -cE '^send-keys .* Enter$' "$TMUX_CALL_LOG" || true
}

@test "multiline submit: paste 後も input-waiting 滞留（Enter 吸収）なら追い Enter で submit する" {
    # mock state: 常に input-waiting を返す＝paste 折りたたみで初回 Enter が吸収され未 submit のまま滞留。
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
echo "$*" >> "$STATE_CALL_LOG"
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 0 ]
    # 初回 Enter（515 行相当）＋ 追い Enter（input-waiting 滞留のため上限 3 回）＝合計 4 回。
    local n; n=$(_count_enters)
    [ "$n" -eq 4 ]
}

@test "multiline submit: 追い Enter 回数は SESSION_COMM_SUBMIT_ENTER_MAX で有界（無限ループ防止）" {
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    export SESSION_COMM_SUBMIT_ENTER_MAX=1
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 0 ]
    # 初回 Enter 1 ＋ 追い Enter 上限 1 ＝ 合計 2 回。
    local n; n=$(_count_enters)
    [ "$n" -eq 2 ]
}

@test "no double-submit: submit 済み（processing）を初回 poll で観測したら追い Enter を送らない" {
    # submit 後すぐ processing へ遷移する正常経路を模す＝input-waiting を抜けているので追い Enter 0 回。
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "processing"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 0 ]
    # 初回 Enter 1 回のみ（追い Enter 0 回）。
    local n; n=$(_count_enters)
    [ "$n" -eq 1 ]
}

@test "no double-submit: input-waiting → processing 遷移（途中 submit 着）で追い Enter は 1 回で停止" {
    # 1 回目 poll は input-waiting（吸収）→ 追い Enter 1 回 → 2 回目 poll で processing（着）→ 停止。
    export STATE_COUNTER="$SANDBOX/state_counter"; echo 0 > "$STATE_COUNTER"
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then
    n=$(cat "$STATE_COUNTER" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STATE_COUNTER"
    if [[ "$n" -eq 1 ]]; then echo "input-waiting"; else echo "processing"; fi
fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 0 ]
    # 初回 Enter 1 ＋ 追い Enter 1（1 回目 input-waiting）＝ 合計 2 回。
    local n; n=$(_count_enters)
    [ "$n" -eq 2 ]
}

@test "read-back 救済 (un-iur finding#2): 折りたたみ placeholder の RESIDUAL 滞留に救済 Enter を撃つ" {
    # cld-spawn の初期 inject は常に --confirm-receipt 経由（confirm_receipt>0）。決定論的な折りたたみ吸収
    # （初回 Enter は常に吸収・state は input-waiting 滞留）だと、read-back の再 paste リトライ（paste+単発
    # Enter）も同じく吸収され送達失敗しうる。read-back ループは入力欄 interior に折りたたみ placeholder を
    # 確認（RESIDUAL＝未 submit の積極証明・ccs-mxv で positive-proof 化）したら有界
    # （SESSION_COMM_SUBMIT_ENTER_MAX）の救済 Enter を撃つ。dialog 不可視なので救済する。
    export MOCK_PANE=$'╭──────────────╮\n│ ❯ [Pasted text #1 +25 lines] │\n╰──────────────╯'
    export SESSION_COMM_SUBMIT_ENTER_MAX=2     # 救済 Enter を 2 回で有界化（budget 内に複数 poll が回る）
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    # confirm-receipt 3s / poll 0.3s ≈ 10 iter > _se_max=2 なので救済 Enter はちょうど 2 回（有界）で停止。
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 4 ]                        # 決定論吸収 mock では受理せず（救済 Enter は受理判定を変えない）
    # 初回 Enter 1 ＋ 救済 Enter 上限 2 ＝ 合計 3 回。救済 Enter が _se_max で有界（無限ループ防止）。
    local n; n=$(_count_enters)
    [ "$n" -eq 3 ]
}

@test "read-back 救済 modality ガード: ダイアログ可視時は救済 Enter を送らない（既定確定を防ぐ）" {
    # post-submit ダイアログが出た正当な input-waiting。救済 Enter は既定選択/空回答を確定する実アクションに
    # なるため抑止する（confirm_receipt==0 の追い Enter と同一の modality ガードを read-back 経路にも効かせる）。
    export MOCK_PANE="Do you want to proceed? ❯ 1. Yes  2. No  (Enter to select)"
    export SESSION_COMM_SUBMIT_ENTER_MAX=3
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 1
    [ "$status" -eq 4 ]                        # 受理されず（救済 Enter は撃たない）
    # 初回 Enter 1 回のみ。ダイアログ検知で救済 Enter は 0 回（既定選択を勝手に確定しない）。
    local n; n=$(_count_enters)
    [ "$n" -eq 1 ]
}

@test "read-back 救済: echo-outside-interior（受理）なら救済 Enter を撃たず exit 0（二重 submit 回避）" {
    # 折りたたみが解けて prompt 内容(sentinel)が transcript（入力欄 interior の外）に echo され、入力欄が
    # 空＝submit の積極証拠（ccs-mxv・B 経路）。救済 Enter を撃つ前に受理で break。
    # capture-pane は baseline（1 回目=空）と poll（2 回目以降=echo+空入力欄）を出し分ける（差分検証のため）。
    # 注: 生テキストの sentinel 出現だけ（入力欄 box 無し）では受理しない——到着 ≠ submit（boot-race 偽陽性の
    # 根治・その pin は session-comm-readback.bats 側）。
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
            printf '%s\n' ""
        else
            printf '%s\n' "> first prompt line here echoed"   # transcript echo
            printf '%s\n' "╭──────────────╮"
            printf '%s\n' "│ ❯            │"                   # 入力欄は空（DELIVERED）
            printf '%s\n' "╰──────────────╯"
        fi
        ;;
    *) exit 0 ;;
esac
TMUX_EOF
    chmod +x "$SANDBOX/bin/tmux"
    export SESSION_COMM_SUBMIT_ENTER_MAX=3
    # sentinel は先頭非空行の先頭 24 字（≥8 字必須）。8 字超の先頭行を持つ prompt にする。
    printf 'first prompt line here\nsecond line\nthird line\n' > "$PROMPT_FILE"
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]                        # echo-outside-interior（B）で受理
    # 初回 Enter 1 回のみ。受理を先に検知するため救済 Enter は 0 回。
    local n; n=$(_count_enters)
    [ "$n" -eq 1 ]
}

@test "read-back 非干渉: 強 processing（正常経路）では救済 Enter を撃たない（回帰なし）" {
    # cld-spawn 正常経路: submit 後すぐ turn 実行（pane に esc to interrupt）。read-back は強 processing
    # マーカー 2 連続で受理＝救済 Enter 0 回（ccs-mxv: state==processing 単独では受理しない——detect_state の
    # 既定 fallthrough が processing のため。受理は turn 固有マーカーの pane 直読 + baseline 行差分）。
    # baseline（paste 前）と poll を出し分ける counter stub（強マーカー行は paste 前には存在しない実流を模す）。
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
            printf '%s\n' ""
        else
            printf '%s\n' "✻ Working… (esc to interrupt)"
            printf '%s\n' "╭──────────────╮"
            printf '%s\n' "│ ❯            │"
            printf '%s\n' "╰──────────────╯"
        fi
        ;;
    *) exit 0 ;;
esac
TMUX_EOF
    chmod +x "$SANDBOX/bin/tmux"
    export SESSION_COMM_SUBMIT_ENTER_MAX=3
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "processing"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --confirm-receipt 3
    [ "$status" -eq 0 ]                        # 強 processing 2 連続で受理
    # 初回 Enter 1 回のみ（救済 Enter は 0 回＝回帰なし）。
    local n; n=$(_count_enters)
    [ "$n" -eq 1 ]
}

@test "no-enter: --no-enter 時は初回 Enter も追い Enter も送らない" {
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5 --no-enter
    [ "$status" -eq 0 ]
    local n; n=$(_count_enters)
    [ "$n" -eq 0 ]
}

@test "robustness: state 取得失敗（unknown）でも追い Enter で二重 submit せず停止する" {
    # session-state.sh が非 0 終了＝state 取得失敗。input-waiting 確証が無いため安全側で停止（追い Enter 0 回）。
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then exit 1; fi   # state 取得失敗を模す
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 0 ]
    # 初回 Enter 1 回のみ。unknown は二重 submit 回避のため break（追い Enter 0 回）。
    local n; n=$(_count_enters)
    [ "$n" -eq 1 ]
}

# --- 入力バリデーション（SESSION_COMM_SUBMIT_ENTER_MAX）---------------------------
# 兄弟フラグ --confirm-receipt/--wait と対称な fail-closed 検証。malformed は paste 前に exit 1、
# 負値も拒否する（負/0 の無言 disable で un-iur 修正が静かに失効する fail-open を防ぐ）。

@test "validation: SESSION_COMM_SUBMIT_ENTER_MAX が非数値なら paste 前に exit 1（fail-closed）" {
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    export SESSION_COMM_SUBMIT_ENTER_MAX=abc
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 1 ]
    [[ "$output" == *"SESSION_COMM_SUBMIT_ENTER_MAX"*"non-negative integer"* ]]
    # fail-closed: paste（load-buffer/paste-buffer）に到達せず abort する＝送達前に弾ける。
    ! grep -q '^paste-buffer' "$TMUX_CALL_LOG"
    ! grep -q '^load-buffer' "$TMUX_CALL_LOG"
}

@test "validation: SESSION_COMM_SUBMIT_ENTER_MAX が負値なら exit 1（un-iur の無言 disable を拒否）" {
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    export SESSION_COMM_SUBMIT_ENTER_MAX=-5
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 1 ]
    [[ "$output" == *"SESSION_COMM_SUBMIT_ENTER_MAX"*"non-negative integer"* ]]
}

@test "validation: SESSION_COMM_SUBMIT_ENTER_MAX=0 は『意図的 disable』として許す（追い Enter 0 回・exit 0）" {
    # 0 は許容（disable）。input-waiting 滞留でも追い Enter は 0 回、初回 Enter のみで返る。
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    export SESSION_COMM_SUBMIT_ENTER_MAX=0
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 0 ]
    # 初回 Enter 1 回のみ（disable のため追い Enter ループに入らない）。
    local n; n=$(_count_enters)
    [ "$n" -eq 1 ]
}

@test "validation: SESSION_COMM_SUBMIT_ENTER_MAX=008（leading-zero）は paste 前に exit 1（octal fail-open 回帰・errata）" {
    # errata: `^[0-9]+$` は 008/009 を通すが、算術文脈 [[ "$_se_i" -lt "$_se_max" ]] で bash が leading-zero を
    # 不正 octal と解釈し `value too great for base` → 条件が偽 → 追い Enter 0 回・exit 0 で本修正が無音 disable
    # （fail-open）。leading-zero を明示 exit 1 で拒否する仕様（^(0|[1-9][0-9]*)$）の回帰ガード。
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    export SESSION_COMM_SUBMIT_ENTER_MAX=008
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 1 ]
    [[ "$output" == *"SESSION_COMM_SUBMIT_ENTER_MAX"*"leading zeros"* ]]
    # fail-closed: paste（load-buffer/paste-buffer）に到達せず abort する＝fail-open(無音 disable)に陥らない。
    ! grep -q '^paste-buffer' "$TMUX_CALL_LOG"
    ! grep -q '^load-buffer' "$TMUX_CALL_LOG"
}

@test "validation: SESSION_COMM_SUBMIT_ENTER_MAX=009（leading-zero・別 octal 不正桁）も exit 1" {
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    export SESSION_COMM_SUBMIT_ENTER_MAX=009
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 1 ]
    [[ "$output" == *"SESSION_COMM_SUBMIT_ENTER_MAX"*"leading zeros"* ]]
}

@test "validation: SESSION_COMM_SUBMIT_ENTER_MAX=10（leading-zero 無しの複数桁）は正常受理（正の対照）" {
    # leading-zero 拒否が canonical な複数桁値を巻き込まないことの positive control。
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "processing"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    export SESSION_COMM_SUBMIT_ENTER_MAX=10
    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 0 ]   # processing 即観測で追い Enter 0 回・正常完了（受理されている＝exit 1 にならない）
    local n; n=$(_count_enters)
    [ "$n" -eq 1 ]
}

# --- modality ガード（承認/AskUserQuestion ダイアログでの誤発火防止）-----------------
# 正当な post-submit input-waiting（承認ダイアログ）で追い Enter を送らない。
# ダイアログでの Enter は『既定選択の確定』という実アクションであり no-op ではないため抑止する。

@test "modality guard: 承認ダイアログ可視時は input-waiting でも追い Enter を送らない（既定選択を確定しない）" {
    # state は input-waiting（detect_state は承認 UI も input-waiting に分類）だが pane にはダイアログが見える。
    export MOCK_PANE="Do you want to proceed? ❯ 1. Yes  2. No  (Enter to select)"
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 0 ]
    # 初回 Enter 1 回のみ。ダイアログ検知で追い Enter は 0 回（既定選択を勝手に確定しない）。
    local n; n=$(_count_enters)
    [ "$n" -eq 1 ]
}

@test "modality guard: ダイアログ無しの素の入力欄滞留では従来どおり追い Enter で submit する" {
    # pane にダイアログパターンが無い＝未 submit の素の入力欄。modality ガードは効かず追い Enter を送る。
    export MOCK_PANE="❯ line 1"
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 0 ]
    # 初回 Enter 1 ＋ 追い Enter 上限 3 ＝ 合計 4 回（ダイアログ無しなのでガードは作動しない）。
    local n; n=$(_count_enters)
    [ "$n" -eq 4 ]
}

# --- 実機 pane 回帰（bypass-permissions 衝突 / free-text 取りこぼし）-----------------
# cld は `claude --dangerously-skip-permissions` で起動するため、input-waiting 状態の実 pane には
# 必ず `⏵⏵ bypass permissions on (shift+tab to cycle)` が常時表示される（ダイアログ識別子ではない）。
# modality ガードがこれを抑止マーカー扱いすると追い Enter が 0 回＝実機で no-op になる衝突を回帰検出する。
# あわせて detect_state が input-waiting に分類する free-text 系（'Type something' / 'Waiting for user input'）
# が _se_dialog_re から漏れていないこと（post-submit 自由入力ダイアログへ空 Enter を撃たない）を固定する。

@test "modality guard: 実 status bar(bypass permissions 常時表示)下の素の入力欄滞留でも追い Enter で submit する" {
    # cld の 25 行級 paste 折りたたみ後・未 submit の実 pane を模す: 折りたたみ表示 + ❯ + 区切り線 +
    # 常時ステータスバー。`bypass permissions` を抑止マーカーにしていると追い Enter 0 回になる→これを検出。
    export MOCK_PANE="$(printf '%s\n' \
        '> [Pasted text #1 +24 lines]' \
        '' \
        '❯ ' \
        '──────────────────────────────────────────────────' \
        '  ⏵⏵ bypass permissions on (shift+tab to cycle)')"
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 0 ]
    # 初回 Enter 1 ＋ 追い Enter 上限 3 ＝ 合計 4 回。bypass permissions はダイアログではないのでガードは
    # 作動せず、未 submit の入力欄を追い Enter で submit する（critical 衝突の回帰ガード）。
    local n; n=$(_count_enters)
    [ "$n" -eq 4 ]
}

@test "modality guard: free-text 質問('Type something')可視時は input-waiting でも追い Enter を送らない" {
    # post-submit race: 初回 Enter で正常 submit → AskUserQuestion のフリーテキスト欄が出た正当な
    # input-waiting。空 Enter は『空回答の確定』という実アクションなので抑止する（detect_state も input-waiting）。
    export MOCK_PANE="$(printf '%s\n' \
        'What is the title?' \
        '❯ Type something...' \
        '  ⏵⏵ bypass permissions on (shift+tab to cycle)')"
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 0 ]
    # 初回 Enter 1 回のみ。'Type something' を modality ガードが検知し追い Enter 0 回（空回答を確定しない）。
    local n; n=$(_count_enters)
    [ "$n" -eq 1 ]
}

@test "modality guard: generic input-waiting('Waiting for user input')可視時は追い Enter を送らない" {
    # detect_state が input-waiting に分類する generic 入力待ちでも、_se_dialog_re と一致して抑止される。
    export MOCK_PANE="$(printf '%s\n' \
        'Waiting for user input' \
        '  ⏵⏵ bypass permissions on (shift+tab to cycle)')"
    cat > "$SANDBOX/mock_scripts/session-state.sh" <<'STATE_EOF'
#!/bin/bash
if [[ "$1" == "wait" ]]; then exit 0; fi
if [[ "$1" == "state" ]]; then echo "input-waiting"; fi
exit 0
STATE_EOF
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"

    run bash "$COMM" inject-file "session:0" "$PROMPT_FILE" --wait 5
    [ "$status" -eq 0 ]
    # 初回 Enter 1 回のみ。generic input-waiting を検知し追い Enter 0 回。
    local n; n=$(_count_enters)
    [ "$n" -eq 1 ]
}

# --- SSOT 同期（_se_dialog_re ↔ session-state.sh:INPUT_WAITING_PATTERNS のドリフト防止）-----------------
# finding#1: modality ガードの dialog 判別 regex は session-state.sh の INPUT_WAITING_PATTERNS（SSOT）から
# 導出される。これらが drift すると、新 dialog 文言が片側だけに追加された場合に detect_state は input-waiting と
# 分類するのに regex は一致せず、real dialog へ空 Enter を撃って既定選択/空回答を勝手に確定する fail-open に
# 静かに退行する。enforce-policy.bats:453 の builtin_danger SSOT 同期テストに倣い drift を fail-closed にする。

@test "SSOT 同期: INPUT_WAITING_PATTERNS の全エントリが _se_dialog_re（導出 regex）に一致する（drift fail-closed）" {
    # 実 session-state.sh を source し、production と同一手順で _se_dialog_re を導出して、
    # INPUT_WAITING_PATTERNS の各エントリ（PROMPT_PATTERN=❯ は配列外＝除外対象）がその regex に
    # 全て一致することを assert する。1 つでも漏れれば fail（手書き複製の drift を構造的に検出）。
    local real_state="$SCRIPT_DIR/session-state.sh"
    [ -f "$real_state" ]
    run bash -c '
        set -euo pipefail
        source "'"$real_state"'"
        IFS="|"; re="${INPUT_WAITING_PATTERNS[*]}"; unset IFS
        [ -n "$re" ] || { echo "EMPTY_RE"; exit 1; }
        # 各エントリの代表サンプルが導出 regex に一致するか（ERE の \[ 等はそのまま grep -E に通す）。
        for p in "${INPUT_WAITING_PATTERNS[@]}"; do
            # サンプル文字列: ERE メタの \[ \] を実文字に戻して「そのパターンを含む行」を作る。
            sample=$(printf "%s" "$p" | sed -e "s/\\\\\[/[/g" -e "s/\\\\\]/]/g")
            printf "prefix %s suffix\n" "$sample" | grep -qE -- "$re" \
                || { echo "MISS: $p"; exit 1; }
        done
        # PROMPT_PATTERN（素入力欄 ❯）は INPUT_WAITING_PATTERNS の要素ではない＝regex に含まれないこと。
        printf "%s\n" "❯ some unsubmitted text" | grep -qE -- "$re" && { echo "PROMPT_LEAKED"; exit 1; }
        echo "synced"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"synced"* ]]
}

@test "SSOT 同期: production が導出する _se_dialog_re と直接導出した regex が一致する（経路同一性）" {
    # cmd_inject_file 冒頭の導出（$SCRIPT_DIR から source）と、テストが直接 source して導出した regex が
    # 文字列レベルで一致することを確認する。production が fail-closed リテラルへ落ちず SSOT 由来である証跡。
    local real_state="$SCRIPT_DIR/session-state.sh"
    run bash -c '
        set -euo pipefail
        source "'"$real_state"'"
        IFS="|"; printf "%s" "${INPUT_WAITING_PATTERNS[*]}"
    '
    [ "$status" -eq 0 ]
    # 期待値（SSOT 配列順）: 片側だけ並べ替え/追加/削除されたら不一致で fail。
    [ "$output" = 'Enter to select|↑/↓ to navigate|承認しますか|確認しますか|Do you want to|\[y/N\]|\[Y/n\]|Type something|Waiting for user input' ]
}

# --- discoverability（新規公開 env knob の usage 記載）---------------------------
# 兄弟フラグ(--wait/--confirm-receipt)が usage に載るのと対称に、新規 env knob も
# `--help`/usage で発見可能にする。未記載だとユーザが追い Enter 挙動を制御/無効化できない。

@test "discoverability: usage() に SESSION_COMM_SUBMIT_ENTER_MAX が記載される（--help で発見可能）" {
    run bash "$COMM" --help
    [ "$status" -ne 0 ]   # usage() は exit 1
    [[ "$output" == *"SESSION_COMM_SUBMIT_ENTER_MAX"* ]]
}
