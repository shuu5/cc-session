#!/usr/bin/env bash
# post-compact.sh — PostCompact hook（ready-compaction）
#
# 役割: 退避した Working Memory を compaction 後の新 context に注入し、
#       消費済みとして consumed ファイルへ mv する（削除はしない）。
#       stdout は compaction 後の新 context に直接注入される。
#
# 設計方針: `set -e` を使わず IO は握り潰す。マーカー不在なら no-op。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
echo "1. 以下の Working Memory を読み、処理中タスクと次のステップを把握する"
echo "2. 必要に応じて mcp__doobidoo__memory_search で関連記憶を取得する（query: 直近のタスク内容）"
echo ""

if [ -f "$WORKING_MEMORY_FILE" ]; then
    echo "--- 退避された作業状態 ---"
    cat "$WORKING_MEMORY_FILE" 2>/dev/null || true
    echo ""
    echo "--- 作業状態ここまで ---"
    # consumed マーク（削除せず mv で復元可能性を残す。次回退避で自然に孤立する）
    mv -f "$WORKING_MEMORY_FILE" "$WORKING_MEMORY_CONSUMED_FILE" 2>/dev/null || true
else
    echo "（退避された Working Memory なし — doobidoo memory_search と直近の文脈から復元してください）"
fi

echo ""
echo "=== [ready-compaction/PostCompact] 復元完了 ==="
exit 0
