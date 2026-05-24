#!/usr/bin/env bash
# lib/tmux-resolve.sh — tmux window target の session:index 形式への安全な解決
#
# Issue #1218: tmux kill-window / set-option に session:index 形式の target 解決を追加
# Reference: cld-observe-any:386 の evaluate_window() パターンを helper として extract
#
# 提供関数:
#   _resolve_window_target <window_name>
#     current session を対象に window を解決し session:index 形式で返す（-a なし設計）。
#     stdout: "session:index"（例: "main:3"）
#     exit 0: 一意に解決
#     exit 1: 不在（stderr: "window not found: <window_name>"）
#     exit 1: 複数一致（stderr: "ambiguous: multiple sessions have window <window_name>"）
#
#   _kill_window_safe <window_name>
#     exit 0: _resolve_window_target 成功 → tmux kill-window -t <session:index> を実行
#     exit 1: _resolve_window_target 失敗 → kill は呼ばない + stderr に理由をログ

# source guard — 直接実行不可
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && {
    echo "Error: $(basename "$0") は source して使用してください" >&2
    exit 1
}

# _resolve_window_target <window_name>
# current session の window_name に一致する window を session:index 形式で返す。
# （-a なし = current session スコープ。orchestrator は自セッション内の window を管理する前提）
# 複数一致（ambiguous: 同一 session に同名 window が複数）または不在の場合は exit 1。
_resolve_window_target() {
    local window_name="$1"

    if [[ -z "$window_name" ]]; then
        echo "window not found: (empty)" >&2
        return 1
    fi

    local all_matches
    all_matches=$(tmux list-windows -F '#{session_name}:#{window_index} #{window_name}' 2>/dev/null \
        | awk -v n="$window_name" '$2 == n { print $1 }')

    if [[ -z "$all_matches" ]]; then
        echo "window not found: $window_name" >&2
        return 1
    fi

    local count
    count=$(printf '%s\n' "$all_matches" | wc -l | tr -d ' ')

    if [[ "$count" -gt 1 ]]; then
        echo "ambiguous: multiple sessions have window $window_name" >&2
        return 1
    fi

    printf '%s\n' "$all_matches"
    return 0
}

# _kill_window_safe <window_name>
# _resolve_window_target で session:index に解決し、tmux kill-window を安全に実行する。
# 解決失敗時は kill をスキップして exit 1。
_kill_window_safe() {
    local window_name="$1"
    local target

    if ! target=$(_resolve_window_target "$window_name"); then
        echo "[tmux-resolve] kill_window_safe: '$window_name' の解決に失敗 — kill をスキップ" >&2
        return 1
    fi

    tmux kill-window -t "$target"
}
