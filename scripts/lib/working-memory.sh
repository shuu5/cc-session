#!/usr/bin/env bash
# working-memory.sh — Working Memory 2 節スキーマの SSOT ＋ carry-forward 機構
#
# このファイルは「## 計画弧・次のステップ」「## この effort を貫く命令・制約」の
# 2 節スキーマの唯一の正典（SSOT）。pre-compact フックと ready-compaction スキルの
# 両方がここを source して同一スキーマに収束する（3 重ドリフトの解消）。
#
# carry-forward（ハイブリッド）:
#   - シェル（extract_effort_directives / emit_working_memory）が前サイクルの consumed から
#     「命令・制約」節を機械的に抽出し、新 working-file へ決定論的に引き継ぐ（絶対落とさない）。
#   - その上で LLM（スキル）が現在文脈とマージ・更新する。
#
# 設計方針: 純関数のみ（副作用なし、stdout 生成）。多重 source ガード付き。

[ -n "${_WORKING_MEMORY_SH_SOURCED:-}" ] && return 0
_WORKING_MEMORY_SH_SOURCED=1

# --- 正典スキーマ定数（SSOT。Phase-2 hook もこの文字列で grep する想定。書式は freeze） ---
WM_HEADING_PLAN="## 計画弧・次のステップ"
WM_HEADING_DIRECTIVES="## この effort を貫く命令・制約"
# 強制モードタグ（半角・行頭リストの先頭トークン）: [auto] / [confirm] / [hard候補]
# 旧 3 節スキーマ（後方互換フォールバック対象）の命令相当節:
WM_HEADING_LEGACY_CONTEXT="## 重要なコンテキスト"

export WM_HEADING_PLAN WM_HEADING_DIRECTIVES WM_HEADING_LEGACY_CONTEXT

# _wm_extract_section <file> <heading>
#   <file> の <heading> 節の「内容行のみ」を stdout に出す。
#   HTML コメント（単一行・複数行）と空行は除去し、命令項目の実体だけを返す。
#   見出し行自体・次の ## 見出し以降は含めない。
_wm_extract_section() {
    local file="$1" heading="$2"
    awk -v h="$heading" '
        $0 == h            { in_sec=1; next }
        in_sec && /^## /   { in_sec=0; next }
        !in_sec            { next }
        incmt              { if (sub(/.*-->/, "")) incmt=0; else next }   # 複数行コメント: 閉じたら-->までを削り後続を残す。未閉なら行を捨てる
        { gsub(/<!--[^-]*(-[^-]+)*-->/, "") }                  # 同一行で完結するコメントを非貪欲に除去（複数あっても間を食わない）
        /^[[:space:]]*<!--/ { incmt=1; next }                  # 行頭の未完オープンのみコメント区間入り（命令行中の <!-- は飲み込まない）
        /^[[:space:]]*$/   { next }
                           { print }
    ' "$file" 2>/dev/null
}

# extract_effort_directives <file>
#   <file>（通常は consumed）の「命令・制約」節の項目を stdout に返す。
#   新節が空/不在なら旧スキーマ「重要なコンテキスト」節をフォールバックで読む（後方互換）。
#   ファイル不在なら空出力 + return 0。
extract_effort_directives() {
    local file="$1"
    [ -f "$file" ] || return 0
    local out
    out="$(_wm_extract_section "$file" "$WM_HEADING_DIRECTIVES")"
    # 新節が「不在」のときのみ旧スキーマにフォールバック（新節が在って空＝意図的な空は尊重する）
    if [ -z "$out" ] && ! grep -qF -- "$WM_HEADING_DIRECTIVES" "$file" 2>/dev/null; then
        out="$(_wm_extract_section "$file" "$WM_HEADING_LEGACY_CONTEXT")"
    fi
    printf '%s' "$out"
}

# emit_working_memory <timestamp> <trigger> [consumed_file]
#   2 節スキーマの working-memory を stdout に生成する（SSOT テンプレ）。
#   consumed_file が与えられ、その「命令・制約」節に項目があれば、それを
#   「命令・制約」節へ機械的に carry-forward する（決定論的に絶対落とさない）。
#   trigger: manual | auto_precompact
emit_working_memory() {
    local ts="$1" trigger="$2" consumed="${3:-}"
    local carried=""
    [ -n "$consumed" ] && carried="$(extract_effort_directives "$consumed")"

    echo "---"
    echo "externalized_at: \"$ts\""
    echo "trigger: $trigger"
    echo "lifecycle: temporary"
    echo "---"
    echo ""
    echo "$WM_HEADING_PLAN"
    echo "<!-- ephemeral: 毎サイクル再生成。今どこにいて、次に何をするか。 -->"
    echo ""
    echo "$WM_HEADING_DIRECTIVES"
    echo "<!-- persistent-within-effort: 前サイクルの consumed から carry-forward。"
    echo "     各項目の先頭に強制モードタグを付ける: [auto] / [confirm] / [hard候補] -->"
    if [ -n "$carried" ]; then
        echo "<!-- ↓前サイクルから機械引き継ぎ。現在文脈とマージ・更新せよ（古い項目は削除可）。 -->"
        printf '%s\n' "$carried"
    fi
}
