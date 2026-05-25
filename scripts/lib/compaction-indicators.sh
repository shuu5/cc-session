#!/usr/bin/env bash
# lib/compaction-indicators.sh - Claude Code auto-compaction フェーズ名 SSOT
# Source this file to get the COMPACTION_INDICATORS array.
# Usage: source "$(dirname "$0")/lib/compaction-indicators.sh"
#
# References: scripts/session-state.sh（detect_state の processing 判定）

# Guard: do nothing if sourced multiple times
[[ -n "${_COMPACTION_INDICATORS_LOADED:-}" ]] && return 0
_COMPACTION_INDICATORS_LOADED=1

# COMPACTION_INDICATORS: auto-compaction フェーズ名（#1475 SSOT）
COMPACTION_INDICATORS=("Compacting" "Snapshotting" "Externalizing" "Restoring" "Summarizing")

export COMPACTION_INDICATORS
