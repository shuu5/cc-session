#!/usr/bin/env bash
# post-compact.sh — PostCompact hook（ready-compaction）
#
# 役割: 退避した Working Memory を compaction 後の新 context に注入し、
#       消費済みとして consumed ファイルへ mv する（削除はしない）。
#       stdout は compaction 後の新 context に直接注入される。
#
# 設計方針: `set -e` を使わず IO は握り潰す。マーカー不在なら no-op。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# session id を stdin の hook JSON から一次解決し、session-env.sh の scoped パス解決へ流す
# （session-env.sh を source する「前」。env 継承は session-env.sh 内の二次フォールバックが拾う）。
# shellcheck source=../lib/hook-session-id.sh
source "$SCRIPT_DIR/../lib/hook-session-id.sh" 2>/dev/null || true
if declare -f hook_extract_session_id >/dev/null 2>&1; then
    _sid="$(hook_extract_session_id)"
    [ -n "$_sid" ] && export WM_SESSION_ID="$_sid"
    unset _sid
fi
# shellcheck source=../lib/session-env.sh
source "$SCRIPT_DIR/../lib/session-env.sh" 2>/dev/null || exit 0

# --- opt-in ゲート ---
[ -f "$COMPACTION_ENABLED_MARKER" ] || exit 0

# --- パストラバーサル検証（pre-compact と対称: whitelist HOME/PWD/TMPDIR 外なら no-op） ---
# shellcheck source=../lib/path-validate.sh
source "$SCRIPT_DIR/../lib/path-validate.sh" 2>/dev/null || true
if declare -f validate_supervisor_dir >/dev/null 2>&1; then
    validate_supervisor_dir "$WORKING_MEMORY_DIR" >/dev/null 2>&1 || exit 0
fi

echo "=== [ready-compaction/PostCompact] Working Memory 復元 ==="
echo ""
echo "### 復帰手順"
echo "1. 以下の Working Memory を読み、「計画弧・次のステップ」で現在地と次の行動を把握する"
echo "2. 「この effort を貫く命令・制約」節を必ず把握し、以降のサイクルへ carry-forward する（忘れない）"
echo "3. 必要に応じて mcp__doobidoo__memory_search で横断/インシデントの事実を取得する"
echo ""

if [ -f "$WORKING_MEMORY_FILE" ]; then
    echo "--- 退避された作業状態 ---"
    cat "$WORKING_MEMORY_FILE" 2>/dev/null || true
    echo ""
    echo "--- 作業状態ここまで ---"
    # consumed マーク（削除せず mv で復元可能性を残す。次回退避で自然に孤立する）。
    # ★この mv は復元 cat の「後」に置く（順序は意図的・ccs-9pv）。restore landing を優先し、
    #   フックが cat→mv 間で中断されても復元は landing 済み・working-memory.md も残る（kill 耐性）。
    #   帰結として consumed への rename は session-state.sh の input-waiting 復帰と「非同期」になる
    #   （UI 判定はフックのファイル後処理を見ない）。監視/テストは input-waiting 直後に consumed の
    #   存在を即 assert せず有界ポーリングで待つこと。設計根拠は architecture/compaction-memory-model.md
    #   「PostCompact のファイル後処理は input-waiting 復帰と非同期」節。
    # 不変条件: 既存 consumed はここで上書きされるが、次サイクルの PreCompact / ready-compaction が
    # emit_working_memory 経由で旧 consumed の「命令・制約」節を新 working へ機械 carry-forward 済みのため、
    # pre→post を正しくペアリングする限り命令は失われない（post が pre 抜きで連続発火する病的列でのみ要注意）。
    mv -f "$WORKING_MEMORY_FILE" "$WORKING_MEMORY_CONSUMED_FILE" 2>/dev/null || true
else
    echo "（退避された Working Memory なし — doobidoo memory_search と直近の文脈から復元してください）"
fi

echo ""
echo "=== [ready-compaction/PostCompact] 復元完了 ==="
exit 0
