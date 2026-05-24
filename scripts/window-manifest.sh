#!/usr/bin/env bash
# window-manifest.sh - tmux window manifest atomic write library
#
# Source this file to use its functions, or execute directly:
#   window-manifest.sh tombstone <window_name>
#
# Environment:
#   WINDOW_MANIFEST_FILE  override manifest path (default: ~/.local/share/claude-session/window-manifest.json)

_MANIFEST_SCHEMA_VERSION=1
# namespace/path は session-env.sh で解決（WINDOW_MANIFEST_FILE デフォルトを提供）
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/session-env.sh"

# Security: WINDOW_MANIFEST_FILE must be under $HOME (path traversal prevention)
if [[ -z "$HOME" ]]; then
    echo "WINDOW_MANIFEST_FILE must be under \$HOME (HOME is not set)" >&2
    return 1 2>/dev/null || exit 1
fi
# Normalize via realpath to prevent $HOME/../../etc/passwd traversal
_MANIFEST_CANONICAL="$(realpath -m -- "$WINDOW_MANIFEST_FILE" 2>/dev/null || printf '%s' "$WINDOW_MANIFEST_FILE")"
if [[ "$_MANIFEST_CANONICAL" != "$HOME/"* ]]; then
    echo "WINDOW_MANIFEST_FILE must be under \$HOME (got: $WINDOW_MANIFEST_FILE)" >&2
    unset _MANIFEST_CANONICAL
    return 1 2>/dev/null || exit 1
fi
unset _MANIFEST_CANONICAL

# _manifest_atomic_write <json>
# temp ファイル生成 → rename でアトミック上書きする。
_manifest_atomic_write() {
    local json="$1"
    local dir
    dir="$(dirname "$WINDOW_MANIFEST_FILE")"
    mkdir -p "$dir"
    local tmpfile
    tmpfile="$(mktemp "${WINDOW_MANIFEST_FILE}.XXXXXX")"
    printf '%s\n' "$json" > "$tmpfile"
    mv -f "$tmpfile" "$WINDOW_MANIFEST_FILE"
}

# _manifest_read_current
# マニフェストを読み込む。存在しない場合は空のスキャフォールドを返す。
_manifest_read_current() {
    if [[ -f "$WINDOW_MANIFEST_FILE" ]]; then
        cat "$WINDOW_MANIFEST_FILE"
    else
        printf '{"schema_version":%d,"entries":[]}' "$_MANIFEST_SCHEMA_VERSION"
    fi
}

# _manifest_check_version <json>
# schema_version が一致するか検証する。不一致なら stderr に警告して 1 を返す。
_manifest_check_version() {
    local json="$1"
    local sv
    sv=$(printf '%s' "$json" | jq -r '.schema_version // empty' 2>/dev/null)
    if [[ -z "$sv" ]]; then
        # ファイル未存在 or schema_version なし → 新規扱いで許可
        return 0
    fi
    if [[ "$sv" != "$_MANIFEST_SCHEMA_VERSION" ]]; then
        echo "⚠️ window-manifest: schema_version 不一致 (got=$sv, expected=$_MANIFEST_SCHEMA_VERSION) — write を拒否します" >&2
        return 1
    fi
    return 0
}

# _manifest_lockfile
# マニフェスト操作用ロックファイルパスを返す。
_manifest_lockfile() {
    printf '%s.lock' "$WINDOW_MANIFEST_FILE"
}

# manifest_append_entry <window_name> <session> <index> <worktree_path> <cwd> <prefix>
# マニフェストに新規エントリを append する（flock + atomic write）。
# Read-Modify-Write サイクルを flock で保護し並列呼び出し時の Lost Update を防止する。
# 失敗時は警告のみ — 呼び出し元を停止しない。
manifest_append_entry() {
    local window_name="$1" session="$2" index="$3"
    local worktree_path="$4" cwd="$5" prefix="$6"
    local created_at
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local lockfile
    lockfile="$(_manifest_lockfile)"
    local dir
    dir="$(dirname "$WINDOW_MANIFEST_FILE")"
    mkdir -p "$dir"

    # Security: reject symlink lockfile
    if [[ -L "$lockfile" ]]; then
        echo "lockfile is a symlink: $lockfile" >&2
        return 1
    fi

    (
        flock -x 9
        local current
        current="$(_manifest_read_current)"

        if ! _manifest_check_version "$current"; then
            exit 0  # 警告済み、エラー終了しない
        fi

        local new_entry
        new_entry=$(jq -n \
            --arg wn "$window_name" \
            --arg sess "$session" \
            --argjson idx "$index" \
            --arg wtp "$worktree_path" \
            --arg c "$cwd" \
            --arg pfx "$prefix" \
            --arg ca "$created_at" \
            '{window_name:$wn,session:$sess,index:$idx,worktree_path:$wtp,cwd:$c,prefix:$pfx,created_at:$ca,tombstone:false}')

        local updated
        updated=$(printf '%s' "$current" | jq --argjson entry "$new_entry" '.entries += [$entry]')

        _manifest_atomic_write "$updated"
    ) 9>"$lockfile"
}

# manifest_tombstone_entry <window_name>
# 指定 window_name のエントリを tombstone=true に更新する（flock + atomic write）。
# unknown fields は保持する。失敗時は警告のみ — 呼び出し元を停止しない。
manifest_tombstone_entry() {
    local window_name="$1"

    local lockfile
    lockfile="$(_manifest_lockfile)"
    local dir
    dir="$(dirname "$WINDOW_MANIFEST_FILE")"
    mkdir -p "$dir"

    # Security: reject symlink lockfile
    if [[ -L "$lockfile" ]]; then
        echo "lockfile is a symlink: $lockfile" >&2
        return 1
    fi

    (
        flock -x 9
        local current
        current="$(_manifest_read_current)"

        if ! _manifest_check_version "$current"; then
            exit 0  # 警告済み、エラー終了しない
        fi

        local updated
        updated=$(printf '%s' "$current" | jq \
            --arg wn "$window_name" \
            '(.entries[] | select(.window_name == $wn) | .tombstone) = true')

        _manifest_atomic_write "$updated"
    ) 9>"$lockfile"
}

# Direct invocation support
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        tombstone)
            if [[ -z "${2:-}" ]]; then
                echo "Usage: window-manifest.sh tombstone <window_name>" >&2
                exit 1
            fi
            manifest_tombstone_entry "$2"
            ;;
        *)
            echo "Usage: window-manifest.sh tombstone <window_name>" >&2
            exit 1
            ;;
    esac
fi
