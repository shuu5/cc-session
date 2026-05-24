#!/usr/bin/env bash
# lib/llm-indicators.sh - LLM thinking indicator SSOT
# Source this file to get LLM_INDICATORS array.
# Usage: source "$(dirname "$0")/lib/llm-indicators.sh"
#
# References: scripts/cld-observe-any

# Guard: do nothing if sourced multiple times
[[ -n "${_LLM_INDICATORS_LOADED:-}" ]] && return 0
_LLM_INDICATORS_LOADED=1

# COMPACTION_INDICATORS: Sonnet 4.6 auto-compaction フェーズ名（#1475 SSOT）
# cld-observe-any の [COMPACTION-DETECTED] ループも本配列を参照する
COMPACTION_INDICATORS=("Compacting" "Snapshotting" "Externalizing" "Restoring" "Summarizing")

LLM_INDICATORS=(
    # --- existing EN indicators ---
    "Thinking"
    "Brewing"
    "Brewed"
    "Concocting"
    "Ebbing"
    "Proofing"
    "Frosting"
    "Reasoning"
    "Computing"
    "Planning"
    "Composing"
    "Processing"
    "Running .* agents"
    "[0-9]+ tool uses"
    "thinking with max effort"
    "Sautéing"
    "Burrowing"
    "Cerebrating"
    "Spinning"
    "Beboppin"
    "Thundering"
    "Baked"
    "Cooked"
    "Crunched"
    "Churned"
    "Skedaddling"
    "Orchestrating"

    # --- compaction phase indicators: Sonnet 4.6 auto-compaction (#1475) ---
    # SSOT: COMPACTION_INDICATORS 配列に定義し、LLM_INDICATORS は参照する
    "${COMPACTION_INDICATORS[@]}"

    # Generalized PCRE regex: Unicode uppercase + lowercase + ASCII ellipsis (#1153)
    # NOTE: this pattern requires grep -qiP (PCRE mode) in detect_thinking()
    # NOTE: 'ed' suffix intentionally omitted — past-tense + "for N" is IDLE (v18 past tense filter)
    "[\\p{Lu}][\\p{Ll}]+(in'|ing)(…|\\.{3}| for [0-9]| \\([0-9])"

    # --- AC: EN 9 new indicators (#1454) ---
    "Newspapering"
    "Fiddle-faddling"
    "Levitating"
    "Cogitating"
    "Bloviating"
    "Vibing"
    "Puttering"
    "Zesting"

    # --- AC5: EN 13 new indicators (#1374) ---
    "Philosophising"
    "Drizzling"
    "Fluttering"
    "Spelunking"
    "Determining"
    "Infusing"
    "Prestidigitating"
    "Cogitated"
    "Frolicking"
    "Marinating"
    "Metamorphosing"
    "Shimmying"
    "Transfiguring"

    # --- AC6: JP 6 indicators (#1374) ---
    "生成中"
    "構築中"
    "処理中"
    "作成中"
    "分析中"
    "検証中"

    # --- AC (#1153): 20 new indicators ---
    "Garnishing"
    "Embellishing"
    "Flambéing"
    "Tomfoolering"
    "Reticulating"
    "Topsy-turvying"
    "Generating"
    "Whisking"
    "Mulling"
    "Fermenting"
    "Caramelizing"
    "Inferring"
    "Discerning"
    "Ratiocinating"
    "Sleuthing"
    "Investigating"
    "Reviewing"
    "Studying"
    "Pondering"
    "Reflecting"

    # --- AC (#1153): 6 catalog-only indicators (Marinating/Newspapering already above) ---
    "Steeping"
    "Simmering"
    "Flummoxing"
    "Befuddling"
    "Waddling"
    "Lollygagging"
)

export LLM_INDICATORS
