#!/usr/bin/env bats
# ready-compaction-cycle-first.bats — cycle-first reframe の DoD pin（orch-dmvr / ccs-1wr）
#
# H1 裁定（mandate-verify wf_b98aabff）: 契約の検証行 grep -c "/clear" は work 前から成立する
# tautological smoke で DoD にできない。DoD は Step 4 節スコープの複合 assert とする
# （work 前の SKILL.md に対して RED＝non-vacuous を mandate-verify が実測確認済み）:
#   (a) Step 4 が /compact を既定手動指示していない
#   (b) Step 4 に /clear 正路がある
#   (c) Step 4 に resume|respawn 正路がある
#   (d) auto-compact 安全網 hooks（PreCompact/PostCompact）が hooks.json に残存
#
# 注意: awk の節抽出は「### Step 4」から次の「^### 」まで（後続の「## 禁止事項」「## 注意」は
# ^## のため抽出に含まれる＝H1 裁定の式をそのまま使う。既定指示の判定は blockquote/プロンプト行
# （^>+）に限定しているので、禁止事項の bullet「/compact の自動実行を…」等は誤検知しない）。
# 脆い text-pin はこの 1 本に限定する（H2 裁定・hook chain bats は touch しない）。

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SK="$REPO_DIR/skills/ready-compaction/SKILL.md"
HOOKS="$REPO_DIR/hooks/hooks.json"

@test "cycle-first DoD: Step 4 に /compact 既定指示なし ∧ /clear 正路 ∧ resume|respawn ∧ 安全網 hooks 残存（orch-dmvr H1 複合 assert）" {
    [ -f "$SK" ]
    [ -f "$HOOKS" ]
    step4=$(awk '/^### Step 4/{f=1} /^### /{if(f && $0 !~ /Step 4/)f=0} f' "$SK")
    [ -n "$step4" ]
    # (a) Step 4 が /compact を既定手動指示していない（blockquote/プロンプト行に「/compact…手動|実行」が無い）
    ! printf '%s' "$step4" | grep -Eq '^>+.*/compact.*(手動|実行)'
    # (b) /clear 正路
    printf '%s' "$step4" | grep -q '/clear'
    # (c) resume または respawn の復帰導線
    printf '%s' "$step4" | grep -Eq 'resume|respawn'
    # (d) auto-compact incident 安全網の hooks 配線が残存
    grep -q PreCompact "$HOOKS"
    grep -q PostCompact "$HOOKS"
}
