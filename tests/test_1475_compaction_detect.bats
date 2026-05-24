#!/usr/bin/env bats
# test_1475_compaction_detect.bats — Issue #1475: auto-compaction 中の誤介入防止
# RED テスト: 実装前は fail する。実装後 GREEN になる。
#
# 設計注意:
#   LLM_INDICATORS の汎用 regex "[A-Z][a-z]+(in'|ing)(…| for [0-9]| \([0-9])"
#   が既存するため、"Compacting…" 等は現状でも detect_thinking にマッチする。
#   しかし、以下は現状で RED（fail）になる:
#     - AC1: llm-indicators.sh に明示的な文字列が存在しない（grep fail）
#     - AC2: COMPACTION-DETECTED イベントが emit されない（emit ロジック未実装）
#   これらが実装後に GREEN になることを確認する。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
LLM_INDICATORS_LIB="$SCRIPT_DIR/lib/llm-indicators.sh"
CLD_OBSERVE_ANY="$SCRIPT_DIR/cld-observe-any"
export SCRIPT_DIR LLM_INDICATORS_LIB CLD_OBSERVE_ANY

setup() {
    TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
    [[ -n "${TMPDIR_TEST:-}" && -d "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# AC1: LLM_INDICATORS に Compacting/Snapshotting/Externalizing/Restoring/Summarizing
#       を明示的に追加する（Approach A）
# RED: 現状これらは llm-indicators.sh に明示登録されていない → grep fail
#
# 重要: 汎用 regex "[A-Z][a-z]+(in'|ing)(…| for [0-9]| \([0-9])" が既存するため
#        detect_thinking 自体は現状でもマッチする場合があるが、
#        明示登録なしでは以下が問題になる:
#        - 汎用 regex は末尾に特定サフィックス (…, for N, (N) が必須
#        - "Compacting" 単体（サフィックスなし）は検知できない
#        - 明示登録により確実に検知できることを保証する
# ---------------------------------------------------------------------------

@test "ac1(#1475): Compacting が llm-indicators.sh に明示登録されていること (RED)" {
    # RED: 現状 "Compacting" という文字列が llm-indicators.sh に存在しない
    grep -q "Compacting" "$LLM_INDICATORS_LIB"
}

@test "ac1(#1475): Snapshotting が llm-indicators.sh に明示登録されていること (RED)" {
    # RED: 現状 "Snapshotting" という文字列が llm-indicators.sh に存在しない
    grep -q "Snapshotting" "$LLM_INDICATORS_LIB"
}

@test "ac1(#1475): Externalizing が llm-indicators.sh に明示登録されていること (RED)" {
    # RED: 現状 "Externalizing" という文字列が llm-indicators.sh に存在しない
    grep -q "Externalizing" "$LLM_INDICATORS_LIB"
}

@test "ac1(#1475): Restoring が llm-indicators.sh に明示登録されていること (RED)" {
    # RED: 現状 "Restoring" という文字列が llm-indicators.sh に存在しない
    grep -q "Restoring" "$LLM_INDICATORS_LIB"
}

@test "ac1(#1475): Summarizing が llm-indicators.sh に明示登録されていること (RED)" {
    # RED: 現状 "Summarizing" という文字列が llm-indicators.sh に存在しない
    grep -q "Summarizing" "$LLM_INDICATORS_LIB"
}

@test "ac1(#1475): detect_thinking が 'Compacting' (サフィックスなし) を検知すること (RED)" {
    # RED: "Compacting" 単体は汎用 regex "[A-Z][a-z]+(in'|ing)(…| for [0-9]| \([0-9])" に
    #      マッチしない（サフィックス必須）
    # 実装後: "Compacting" を明示登録 → サフィックスなしでも検知可能
    run bash <<EOF
source "$LLM_INDICATORS_LIB"
pane_text="Compacting"
detected=""
for ind in "\${LLM_INDICATORS[@]}"; do
    if echo "\$pane_text" | grep -qiE "\$ind" 2>/dev/null; then
        detected="\$ind"
        break
    fi
done
[[ -n "\$detected" ]] && echo "PASS: \$detected" || { echo "FAIL: Compacting (no suffix) not detected"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac1(#1475): detect_thinking が 'Snapshotting' (サフィックスなし) を検知すること (RED)" {
    # RED: "Snapshotting" 単体は汎用 regex にマッチしない（サフィックス必須）
    run bash <<EOF
source "$LLM_INDICATORS_LIB"
pane_text="Snapshotting"
detected=""
for ind in "\${LLM_INDICATORS[@]}"; do
    if echo "\$pane_text" | grep -qiE "\$ind" 2>/dev/null; then
        detected="\$ind"
        break
    fi
done
[[ -n "\$detected" ]] && echo "PASS: \$detected" || { echo "FAIL: Snapshotting (no suffix) not detected"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# AC2: cld-observe-any で [COMPACTION-DETECTED] event 発火、stagnate 判定から除外
# RED: 現状 COMPACTION-DETECTED emit ロジックが存在しない → output に含まれない
# ---------------------------------------------------------------------------

@test "ac2(#1475): 'Compacting…' pane で COMPACTION-DETECTED が emit されること (RED)" {
    local script_dir="$SCRIPT_DIR"
    local cld_observe_any="$CLD_OBSERVE_ANY"

    # RED: 現状 cld-observe-any に COMPACTION-DETECTED emit ロジックが存在しない
    # 実装後: "Compacting" を pane 内容から検知して [COMPACTION-DETECTED] を emit する
    run bash <<EOF
win="ap-test-win-1475-ac2"
capture="Compacting…"
export win capture

tmux() {
    case "\$1" in
        list-windows)
            if [[ "\${2:-}" == "-a" ]]; then
                printf 'test-session:0 %s\n' "\$win"
                return
            fi
            echo "test-session:0 \$win"
            ;;
        display-message)
            echo "0 claude"
            ;;
        capture-pane)
            printf '%s\n' "\$capture"
            ;;
        *)
            return 0 ;;
    esac
}
export -f tmux

output=\$(_TEST_MODE=1 CLD_OBSERVE_ANY_SCRIPT_DIR="$script_dir" \
    bash "$cld_observe_any" --window "\$win" --once \
    --complete-regex "PHASE_COMPLETE" --stagnate-sec 10 2>/dev/null)
echo "\$output"
echo "\$output" | grep -q "COMPACTION-DETECTED"
EOF
    [[ "$status" -eq 0 ]]
}

# ---------------------------------------------------------------------------
# AC3: bats test で Worker pane に "Compacting…" 出力 → STAGNATE-300 false positive 回避を検証
# RED テストは「汎用 regex が届かない状況」= pane 静止後（compaction 完了直後）を模倣する
#
# 現状の問題の本質:
#   compaction 中の "Compacting…" 表示時 → 汎用 regex で detect → thinking 非空 → STAGNATE 抑止
#   compaction 完了後に pane が静止 → 表示は変わらず "Compacting completed" 等が残る
#   → log_age が伸びて STAGNATE 発火
#
# AC3 の RED テスト: COMPACTION-DETECTED フラグが持続して stagnate を除外するか確認
# 現状フラグなし → pane 静止時に STAGNATE が発火する
# ---------------------------------------------------------------------------

@test "ac3(#1475): COMPACTION-DETECTED 発火後にフラグ持続して次サイクルで STAGNATE を抑止すること (RED)" {
    local script_dir="$SCRIPT_DIR"
    local cld_observe_any="$CLD_OBSERVE_ANY"

    # RED: 現状 COMPACTION-DETECTED の状態フラグ機構が存在しない
    # → pane に "Compacting…" が存在しなくなった後もフラグを維持して STAGNATE 抑止が必要
    # 実装後: COMPACTION_ACTIVE フラグ or event-dir への書き込みで持続する
    run bash <<EOF
win="ap-test-win-1475-ac3"

# pane 静止後（compaction 完了後）を模倣: pane に indicator 文字列なし
# detect_thinking は空 → 現状は STAGNATE 発火 → RED
capture="Claude compacted your context."
export win capture

tmux() {
    case "\$1" in
        list-windows)
            if [[ "\${2:-}" == "-a" ]]; then
                printf 'test-session:0 %s\n' "\$win"
                return
            fi
            echo "test-session:0 \$win"
            ;;
        display-message)
            echo "0 claude"
            ;;
        capture-pane)
            printf '%s\n' "\$capture"
            ;;
        *)
            return 0 ;;
    esac
}
export -f tmux

output=\$(_TEST_MODE=1 CLD_OBSERVE_ANY_SCRIPT_DIR="$script_dir" \
    COMPACTION_ACTIVE=1 \
    bash "$cld_observe_any" --window "\$win" --once \
    --complete-regex "PHASE_COMPLETE" --stagnate-sec 10 2>/dev/null)
echo "\$output"
# 実装後: COMPACTION_ACTIVE フラグで STAGNATE 抑止 → STAGNATE-10 が emit されない
if echo "\$output" | grep -q "STAGNATE-10"; then
    echo "FAIL: STAGNATE-10 was emitted despite COMPACTION_ACTIVE=1"
    exit 1
fi
echo "PASS: STAGNATE-10 not emitted when COMPACTION_ACTIVE=1"
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac3(#1475): Compacting キーワード含む pane で detect_thinking が 'Compacting' を返すこと (RED)" {
    # detect_thinking は grep -qiE で部分マッチ（アンカーなし）。
    # "Compacting" 明示登録が generic regex より先に並ぶため、
    # "Compacting for 9m 19s · max effort" を与えると "Compacting" が最初にマッチする。
    # → 返値が "Compacting" であることを確認。
    run bash <<EOF
source "$LLM_INDICATORS_LIB"
pane_text="Compacting for 9m 19s · max effort"
detected=""
for ind in "\${LLM_INDICATORS[@]}"; do
    if echo "\$pane_text" | grep -qiE "\$ind" 2>/dev/null; then
        detected="\$ind"
        break
    fi
done
# 明示登録 "Compacting" が generic regex より先に反応することを確認
if [[ "\$detected" == "Compacting" ]]; then
    echo "PASS: detected by explicit 'Compacting' entry"
else
    echo "FAIL: Compacting not detected by explicit entry (detected='\$detected')"
    exit 1
fi
EOF
    [[ "$status" -eq 0 ]]
}


# ---------------------------------------------------------------------------
# AC5: Wave 56+ で Worker auto-compaction 中の誤介入が発生しないことを確認
# AC1+AC2 組み合わせ統合確認
# RED: COMPACTION-DETECTED イベントが実装されていない
# ---------------------------------------------------------------------------

@test "ac5(#1475): cld-observe-any が compaction 状態を検知して COMPACTION-DETECTED を emit すること (RED)" {
    local script_dir="$SCRIPT_DIR"
    local cld_observe_any="$CLD_OBSERVE_ANY"

    # RED: COMPACTION-DETECTED emit ロジック未実装
    # 実装後: Compacting/Snapshotting/Externalizing/Restoring/Summarizing のいずれかを
    #         pane で検知した場合に [COMPACTION-DETECTED] を emit する
    run bash <<EOF
win="ap-test-win-1475-ac5"
capture="Snapshotting…"
export win capture

tmux() {
    case "\$1" in
        list-windows)
            if [[ "\${2:-}" == "-a" ]]; then
                printf 'test-session:0 %s\n' "\$win"
                return
            fi
            echo "test-session:0 \$win"
            ;;
        display-message)
            echo "0 claude"
            ;;
        capture-pane)
            printf '%s\n' "\$capture"
            ;;
        *)
            return 0 ;;
    esac
}
export -f tmux

output=\$(_TEST_MODE=1 CLD_OBSERVE_ANY_SCRIPT_DIR="$script_dir" \
    bash "$cld_observe_any" --window "\$win" --once \
    --complete-regex "PHASE_COMPLETE" --stagnate-sec 10 2>/dev/null)
echo "\$output"
# 実装後: COMPACTION-DETECTED が含まれること
echo "\$output" | grep -q "COMPACTION-DETECTED"
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac5(#1475): Externalizing (サフィックスなし) が detect_thinking で検知されること (RED)" {
    # RED: "Externalizing" 単体は汎用 regex にマッチしない
    run bash <<EOF
source "$LLM_INDICATORS_LIB"
pane_text="Externalizing"
detected=""
for ind in "\${LLM_INDICATORS[@]}"; do
    if echo "\$pane_text" | grep -qiE "\$ind" 2>/dev/null; then
        detected="\$ind"
        break
    fi
done
[[ -n "\$detected" ]] && echo "PASS: \$detected" \
    || { echo "FAIL: Externalizing (no suffix) not detected"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac5(#1475): Restoring (サフィックスなし) が detect_thinking で検知されること (RED)" {
    # RED: "Restoring" 単体は汎用 regex にマッチしない
    run bash <<EOF
source "$LLM_INDICATORS_LIB"
pane_text="Restoring"
detected=""
for ind in "\${LLM_INDICATORS[@]}"; do
    if echo "\$pane_text" | grep -qiE "\$ind" 2>/dev/null; then
        detected="\$ind"
        break
    fi
done
[[ -n "\$detected" ]] && echo "PASS: \$detected" \
    || { echo "FAIL: Restoring (no suffix) not detected"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}

@test "ac5(#1475): Summarizing (サフィックスなし) が detect_thinking で検知されること (RED)" {
    # RED: "Summarizing" 単体は汎用 regex にマッチしない
    run bash <<EOF
source "$LLM_INDICATORS_LIB"
pane_text="Summarizing"
detected=""
for ind in "\${LLM_INDICATORS[@]}"; do
    if echo "\$pane_text" | grep -qiE "\$ind" 2>/dev/null; then
        detected="\$ind"
        break
    fi
done
[[ -n "\$detected" ]] && echo "PASS: \$detected" \
    || { echo "FAIL: Summarizing (no suffix) not detected"; exit 1; }
EOF
    [[ "$status" -eq 0 ]]
}
