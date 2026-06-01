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

# --- 作業状態の復元案内（PreCompact/PostCompact/SessionStart の発火順序に非依存） ---
# 順序は Anthropic docs で保証されないため、両ファイルの有無で排他に分岐し矛盾ヒントを出さない:
#   consumed あり          = PostCompact が復元済み（命令・制約は consumed に保全されている）
#   consumed なし + working = PostCompact 未走の可能性（SessionStart が先に発火した等。
#                            PostCompact が直後に注入＋consumed 化する）
if [ -f "$WORKING_MEMORY_CONSUMED_FILE" ]; then
    # PostCompact 復元済み。working-memory.md への再 Read は誘導しない（PostCompact が注入済みのため）。
    echo "[carry-forward] 前サイクルの「この effort を貫く命令・制約」は次に保全されています: $WORKING_MEMORY_CONSUMED_FILE"
    echo "[carry-forward] この effort を続ける場合、その命令・制約を必ず引き継ぐこと（次の ready-compaction 実行時に新 working-file へ自動 carry-forward される）。"
    echo ""
elif [ -f "$WORKING_MEMORY_FILE" ]; then
    # consumed が無く working がある＝PostCompact がまだ復元していない可能性。
    # 断定的な Read 指示は出さず条件付きにする（順序が逆転して直後に消える場合の誤誘導を避ける）。
    echo "[Working Memory] 退避された作業状態があります: $WORKING_MEMORY_FILE"
    echo "[Working Memory] PostCompact がこの内容をまだ注入していなければ、このファイルを Read して作業状態を復元してください。"
    echo ""
fi

# 外部化ファイル一覧（存在のみ通知、内容は読まない）。consumed 済みは除外。
# さらに consumed が在るなら working-memory.md は復元済みサイクルの未 rename 重複とみなし除外する
# （SessionStart が PostCompact の mv より先に走り working がまだ rename されていない場合の二重 Read 誘導を防ぐ）。
if [ -d "$WORKING_MEMORY_DIR" ]; then
    _wm_base="$(basename "$WORKING_MEMORY_FILE")"
    shopt -s nullglob
    _md_files=()
    for f in "$WORKING_MEMORY_DIR"/*.md; do
        _b="$(basename "$f")"
        case "$_b" in
            *.consumed.md) ;;  # 復元済み → 一覧から除外
            *)
                if [ "$_b" = "$_wm_base" ] && [ -f "$WORKING_MEMORY_CONSUMED_FILE" ]; then
                    : # consumed 済み → working は重複とみなし一覧からも除外
                else
                    _md_files+=("$f")
                fi
                ;;
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
