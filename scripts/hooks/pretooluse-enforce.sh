#!/usr/bin/env bash
# pretooluse-enforce.sh — PreToolUse(Bash) hook（ready-compaction Phase-2: hard 強制層）
#
# 役割: 人間レビュー等の gate を通っていない危険操作（PR merge / push / deploy 等）を
#   deny-block（exit 2 + stderr）する。認可（marker 作成）は人間の生シェルだけが行えるため、
#   Claude は自己認可できない＝これが hard 性の実体（C-4b）。判定の SSOT は enforce-policy.sh。
#
# 判定フロー（§9.6・1 Bash 呼び出しごと）:
#   step1 policy 不在/空/enforce!=true → allow（no-op opt-in）
#   step2 command が gate に不一致      → allow
#   step3 gate 一致 ＆ 有効 marker 在り → allow
#   step4 gate 一致 ＆ marker 不在      → block（exit 2 + unlock 案内）
#   step5 policy 在り＋破損/jq 不在/version 超過 → fail-closed (scoped):
#         内蔵 danger list のみ block、他は allow
#
# 設計方針:
#   - 入力は stdin JSON（.tool_input.command）。jq 不在/失敗時は env / 生入力へフォールバック。
#   - 外部コマンド(gh)は sha_keyed gate の block 経路でのみ走る（allow 経路は jq+正規表現のみ）。
#   - グローバル git-destructive-guard.sh と共存（C-8）。policy 不在で no-op のため波及は無害。
#   - lib をロードできない（plugin 整合性異常）ときは no-op（exit 0）。全 Bash を巻き込まない判断。

set -uo pipefail

# C-7 緊急 bypass（人間が生シェルで env を立てたときのみ）。Claude は実行せず提示のみ。
[ "${SESSION_ENFORCE_OFF:-}" = "1" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/enforce-policy.sh
source "$SCRIPT_DIR/../lib/enforce-policy.sh" 2>/dev/null || exit 0   # lib 不在 → 強制不能 → no-op

# --- 入力からコマンド文字列を取り出す（git-destructive-guard.sh と同型） ---
INPUT=$(cat 2>/dev/null || true)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$CMD" ] && CMD="${TOOL_INPUT_command:-}"
[ -z "$CMD" ] && CMD="$INPUT"     # jq 不在/パース失敗 → 生入力で判定（fail-closed 寄り）
[ -z "$CMD" ] && exit 0

NORM=$(ep_normalize "$CMD")

# --- step1 / step5: policy health で分岐 ---
case "$(ep_policy_health)" in
    absent|off)
        exit 0 ;;                                    # step1: opt-in 不成立 → allow
    active)
        : ;;                                         # 正常稼働 → step2 へ
    *)                                               # step5: corrupt|nojq|badversion|未知/空 → fail-closed (scoped)
        if ep_builtin_danger_match "$NORM"; then     # ★未知/空 health もここで安全側に倒す（fail-open 防止）
            echo "DENIED(enforce/fail-closed): policy を評価できません（破損 / jq 不在 / version 超過 / 判定不能）。" >&2
            echo "  内蔵 danger list に該当するため安全側で block しました。" >&2
            echo "  policy を修復するか、緊急時は人間が生シェルで SESSION_ENFORCE_OFF=1 を設定してください。" >&2
            exit 2
        fi
        exit 0 ;;                                    # danger 以外は通す（scoped）
esac

# --- step2: gate マッチ ---
GATE=$(ep_match_gate "$NORM") || exit 0              # 不一致 → allow

# --- marker 名導出（sha_keyed gate なら block 経路でのみ gh を 1 回呼ぶ） ---
MARKER=$(ep_marker_name "$GATE" "$NORM"); rc=$?
if [ "$rc" -eq 3 ] || [ "$rc" -eq 4 ]; then          # SHA 導出不能 / subject 不明 → fail-closed
    echo "DENIED(enforce/$GATE): 操作インスタンスを特定できません（SHA 導出失敗 or 対象不明）。" >&2
    echo "  安全側で block しました。gh の認証/ネットワークを確認するか、対象（PR番号等）を明示してください。" >&2
    echo "  該当 gate を sha_keyed:false に下げる選択肢もあります（policy 編集は人間）。" >&2
    exit 2
fi

# --- step3: 有効な marker があれば allow ---
ep_marker_valid "$GATE" "$MARKER" && exit 0

# --- step4: marker 不在 → block + unlock 案内 ---
ep_block_message "$GATE" "$NORM" "$MARKER" >&2
exit 2
