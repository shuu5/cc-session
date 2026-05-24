#!/bin/bash
# =============================================================================
# claude-session-save.sh - Claude Code session_id ↔ tmuxペイン マッピング保存
#
# Claude Code SessionStart hookから呼ばれる。stdinのJSONからsession_idを取得し、
# $TMUX_PANE (pane_id, %N形式) をキーとしてTSVファイルにマッピングを保存する。
#
# pane_idはtmuxサーバー存命中は不変のため、renumber-windowsやrename-sessionの
# 影響を受けない。復元用のsession:win.pane形式への変換はpostsaveで行う。
#
# 用途: tmux-resurrect復元時に各ペインのClaude Codeを--resumeで再開するため
# =============================================================================

# tmux外なら何もしない
[ -z "${TMUX:-}" ] && exit 0

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
[ -z "$SESSION_ID" ] && exit 0

# $TMUX_PANE（%N形式）をそのままキーとして使用（不変）
TMUX_KEY="$TMUX_PANE"

# shellcheck source=./lib/session-env.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/session-env.sh"
MAPDIR="$SESSION_MAP_DIR"
mkdir -p "$MAPDIR"
LOCKFILE="$MAPDIR/session-map.lock"

# pane-map + session-map の書き込み全体を flock 排他ロックで保護
# （複数Claudeペイン同時起動時の競合状態を防止）
(
    flock -w 5 -x 9 || exit 0

    # --- pane-map アトミック書き込み ---
    MAPFILE="$MAPDIR/tmux-pane-map.tsv"
    TMPFILE=$(mktemp "${MAPFILE}.XXXXXX")
    trap 'rm -f "$TMPFILE"' EXIT

    # 同一キーの古いエントリを除外 + 新エントリ追加
    { grep -v "^${TMUX_KEY}	" "$MAPFILE" 2>/dev/null || true
      printf '%s\t%s\n' "$TMUX_KEY" "$SESSION_ID"
    } > "$TMPFILE"
    mv "$TMPFILE" "$MAPFILE"
    trap - EXIT

    # --- session-map 即時更新（postsave の15分ギャップを埋める） ---
    POSITION=$(tmux list-panes -a -f "#{==:#{pane_id},${TMUX_PANE}}" \
        -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)

    if [ -n "$POSITION" ]; then
        SESSION_MAP="$MAPDIR/tmux-session-map.tsv"
        STMPFILE=$(mktemp "${SESSION_MAP}.XXXXXX")
        trap 'rm -f "$STMPFILE"' EXIT
        { grep -v "^${POSITION}	" "$SESSION_MAP" 2>/dev/null || true
          printf '%s\t%s\n' "$POSITION" "$SESSION_ID"
        } > "$STMPFILE"
        mv "$STMPFILE" "$SESSION_MAP"
        trap - EXIT
    fi

) 9>"$LOCKFILE"
