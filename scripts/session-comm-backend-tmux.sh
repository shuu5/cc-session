#!/bin/bash
# session-comm-backend-tmux.sh — tmux backend for session_msg API (ADR-029 Decision 5)
#
# Phase 1 default backend. Contains all tmux send-keys calls for session_msg.
# Remains as rollback/emergency-override backend in Phase 3+ (whitelist entry).
#
# Source mode (from session-comm.sh):
#   source session-comm-backend-tmux.sh
#   _backend_tmux_send TARGET CONTENT [opts]
#
# Direct execution:
#   session-comm-backend-tmux.sh send TARGET CONTENT [opts]
#
# Options:
#   --enter-only   Send only Enter (no content)
#   --no-enter     Send content without trailing Enter
#   --type=TYPE    Message type (metadata; tmux backend ignores it)

set -euo pipefail

# _backend_tmux_send TARGET CONTENT [--enter-only] [--no-enter] [--type=TYPE]
_backend_tmux_send() {
    local target="${1:-}"
    local content="${2:-}"
    local enter_only=false
    local no_enter=false
    shift 2 2>/dev/null || { shift $# 2>/dev/null; true; }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --enter-only)  enter_only=true ;;
            --no-enter)    no_enter=true ;;
            --type=*)      : ;;  # metadata; ignored by tmux backend
            *)             ;;
        esac
        shift
    done

    if [[ -z "$target" ]]; then
        echo "Error: backend-tmux send: target required" >&2
        return 1
    fi

    if $enter_only; then
        tmux send-keys -t "$target" Enter 2>/dev/null || true
        return 0
    fi

    if [[ -n "$content" ]]; then
        tmux send-keys -t "$target" -l "$content" || {
            echo "Error: backend-tmux send: failed to send keys to '$target'" >&2
            return 1
        }
    fi

    if ! $no_enter; then
        tmux send-keys -t "$target" Enter
    fi
}

# Direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        send)
            shift
            _backend_tmux_send "$@"
            ;;
        *)
            echo "Usage: session-comm-backend-tmux.sh send TARGET CONTENT [--enter-only] [--no-enter]" >&2
            exit 1
            ;;
    esac
fi
