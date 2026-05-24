#!/usr/bin/env bash
# session-start-compact.sh — SessionStart(matcher: compact) hook（ready-compaction）
#
# 役割: compaction 後の再開時に ambient hints を注入する。
#       PostCompact の sharp な作業状態復元とは棲み分け、ここでは
#       「ぼんやりした全体像」（Long-term Memory の存在ポインタ、外部化ファイル一覧）を提供する。
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

echo "=== [ready-compaction/SessionStart:compact] Ambient Context ==="
echo ""

# Long-term Memory ポインタ
echo "[Long-term Memory] doobidoo にこのプロジェクトの知見が保存されている可能性があります。"
echo "[Long-term Memory] 必要に応じて mcp__doobidoo__memory_search で検索してください。"
echo ""

# 未消費の Working Memory がある場合のフォールバック（PostCompact が走らなかったケア）
if [ -f "$WORKING_MEMORY_FILE" ]; then
    echo "[Working Memory] 未復元の作業状態が残っています: $WORKING_MEMORY_FILE"
    echo "[Working Memory] このファイルを Read して作業状態を復元してください。"
    echo ""
fi

# 外部化ファイル一覧（存在のみ通知、内容は読まない。consumed 済みは除外して再 Read 誘導を防ぐ）
if [ -d "$WORKING_MEMORY_DIR" ]; then
    shopt -s nullglob
    _md_files=()
    for f in "$WORKING_MEMORY_DIR"/*.md; do
        case "$(basename "$f")" in
            *.consumed.md) ;;  # 復元済み → 一覧から除外
            *) _md_files+=("$f") ;;
        esac
    done
    shopt -u nullglob
    if [ ${#_md_files[@]} -gt 0 ]; then
        echo "[外部化ファイル] $WORKING_MEMORY_DIR/"
        for f in "${_md_files[@]}"; do
            echo "  - $(basename "$f")"
        done
    fi
fi

echo ""
echo "=== [ready-compaction/SessionStart:compact] ここまで ==="
exit 0
