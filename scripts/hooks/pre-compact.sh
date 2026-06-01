#!/usr/bin/env bash
# pre-compact.sh — PreCompact hook（ready-compaction）
#
# 役割:
#   1. side effect: Working Memory が未退避なら安全網スケルトンを書き出す
#      （スキルが既に sharp な内容を書いていればそれを尊重して上書きしない）
#   2. stdout: compaction される context に「退避済み」ヒントを注入する
#
# 設計方針:
#   - フックの失敗で compaction をブロックしないため `set -e` は使わず、IO は握り潰す
#   - opt-in マーカーが無いプロジェクトでは即 no-op（exit 0）
#   - 既存の Working Memory は決して破壊しない（存在すれば常に保持）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/session-env.sh
source "$SCRIPT_DIR/../lib/session-env.sh" 2>/dev/null || exit 0
# shellcheck source=../lib/working-memory.sh
source "$SCRIPT_DIR/../lib/working-memory.sh" 2>/dev/null || true

# --- opt-in ゲート: マーカー不在なら何もしない ---
[ -f "$COMPACTION_ENABLED_MARKER" ] || exit 0

# --- パストラバーサル検証（whitelist: HOME / PWD / TMPDIR 配下のみ） ---
# shellcheck source=../lib/path-validate.sh
source "$SCRIPT_DIR/../lib/path-validate.sh" 2>/dev/null || true
if declare -f validate_supervisor_dir >/dev/null 2>&1; then
    if ! validate_supervisor_dir "$WORKING_MEMORY_DIR" >/dev/null 2>&1; then
        echo "[ready-compaction/pre-compact] WARN: WORKING_MEMORY_DIR の検証に失敗 — スキップ: $WORKING_MEMORY_DIR" >&2
        exit 0
    fi
fi

mkdir -p "$WORKING_MEMORY_DIR" 2>/dev/null || exit 0

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- 安全網スケルトン書き出し（atomic write: tmp → mv） ---
# ready-compaction スキルを実行せずに compaction が発生した場合のみ動く。
# スキルが書いた working-memory.md が既に存在する場合は触らない。
_write_skeleton() {
    local tmp
    tmp="$(mktemp "${WORKING_MEMORY_FILE}.XXXXXX" 2>/dev/null)" || return 1
    # 2 節スキーマ（SSOT = working-memory.sh）。前サイクルの consumed があれば
    # 「命令・制約」節を機械的に carry-forward（スキル未実行でも命令を落とさない）。
    {
        if declare -f emit_working_memory >/dev/null 2>&1; then
            emit_working_memory "$TIMESTAMP" auto_precompact "$WORKING_MEMORY_CONSUMED_FILE"
            echo ""
            echo "<!-- ready-compaction スキル未実行のままの自動退避。計画弧は空。"
            echo "     次回は /compact の前に /session:ready-compaction を実行してください。 -->"
        else
            # lib 未ロード時のフォールバック: 最小 frontmatter のみ（壊さない）
            echo "---"
            echo "externalized_at: \"$TIMESTAMP\""
            echo "trigger: auto_precompact"
            echo "lifecycle: temporary"
            echo "---"
        fi
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$WORKING_MEMORY_FILE" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null
        return 1
    }
}

# 退避状態を追跡: 既存ファイル（スキル書き込み）は尊重、無ければスケルトン書き出し
_wm_staged=false
if [ -f "$WORKING_MEMORY_FILE" ]; then
    _wm_staged=true
elif _write_skeleton; then
    _wm_staged=true
fi

# --- compaction ログへ追記 ---
echo "$TIMESTAMP pre-compact" >> "$COMPACTION_LOG_FILE" 2>/dev/null || true

# --- stdout: 圧縮ヒント（この出力は compaction 対象 context に含まれる） ---
# 退避に成功した場合のみ「退避しました」と注入する（失敗時に嘘を残さない）
if $_wm_staged; then
    echo "[ready-compaction] 作業状態を $WORKING_MEMORY_FILE に退避しました。PostCompact で復元されます。"
else
    echo "[ready-compaction] WARN: Working Memory の退避に失敗しました。PostCompact での復元は期待できません。" >&2
fi

exit 0
