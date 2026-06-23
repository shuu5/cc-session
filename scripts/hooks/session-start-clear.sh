#!/usr/bin/env bash
# session-start-clear.sh — SessionStart(matcher: clear) hook（ready-compaction）
#
# 役割: /clear（文脈の完全リセット）後の新セッションに、退避済み Working Memory の
#       存在を **read-only のポインタとして**通知する。ユーザー運用 (b) の安全網:
#       「基本は /compact。たまに /clear したくなる時、退避ファイルが失われず拾える」。
#
# 設計（grill 2026-06-23 / bd ccs-et2 で合意 = 論点2 案 B）:
#   - read-only に徹する。working-memory への cat 注入も consumed への mv も **しない**
#     （compaction 経路の post-compact.sh とは責務が違う。あちらは「復元＋consumed 化」）。
#   - 発見性フォールバック: 厳密 sid 一致（$WORKING_MEMORY_FILE）が無ければ、
#     ディレクトリ内で最新 mtime の working-memory*.md（*.consumed.md は除外）を提示する。
#     /clear で session_id が変わると旧 sid 名のファイルは exact 一致しないため
#     （un-gcu の session-scoped 命名の副作用）、この mtime フォールバックで拾う。
#   - cwd 共有の並走セッションがあると他セッションの退避ファイルを拾いうるが、
#     read-only ポインタなので un-gcu が閉じた「上書き破壊」は再導入しない。
#     代わりに「別セッション由来の可能性」を正直に明示してユーザー判断に委ねる。
#
# 設計方針: `set -e` を使わず IO は握り潰す。マーカー不在なら no-op。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# session id を stdin の hook JSON から一次解決し、session-env.sh の scoped パス解決へ流す
# （session-env.sh を source する「前」。env 継承は session-env.sh 内の二次フォールバックが拾う）。
# shellcheck source=../lib/hook-session-id.sh
source "$SCRIPT_DIR/../lib/hook-session-id.sh" 2>/dev/null || true
if declare -f hook_extract_session_id >/dev/null 2>&1; then
    _sid="$(hook_extract_session_id)"
    [ -n "$_sid" ] && export WM_SESSION_ID="$_sid"
    unset _sid
fi
# shellcheck source=../lib/session-env.sh
source "$SCRIPT_DIR/../lib/session-env.sh" 2>/dev/null || exit 0

# --- opt-in ゲート ---
[ -f "$COMPACTION_ENABLED_MARKER" ] || exit 0

# --- パストラバーサル検証（compact と対称: whitelist HOME/PWD/TMPDIR 外なら no-op） ---
# shellcheck source=../lib/path-validate.sh
source "$SCRIPT_DIR/../lib/path-validate.sh" 2>/dev/null || true
if declare -f validate_supervisor_dir >/dev/null 2>&1; then
    validate_supervisor_dir "$WORKING_MEMORY_DIR" >/dev/null 2>&1 || exit 0
fi

# ディレクトリ内で最新 mtime の working-memory*.md（consumed 除外）を stdout に出す純関数。
# read-only（glob と -nt 比較のみ。ファイルには一切触れない）。
_find_newest_working_memory() {
    local dir="$1" newest="" f b
    [ -d "$dir" ] || return 0
    shopt -s nullglob
    for f in "$dir"/working-memory*.md; do
        b="$(basename "$f")"
        case "$b" in
            *.consumed.md) continue ;;  # 復元済み（consumed）は提示対象外
        esac
        if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then
            newest="$f"
        fi
    done
    shopt -u nullglob
    [ -n "$newest" ] && printf '%s' "$newest"
}

echo "=== [ready-compaction/SessionStart:clear] Working Memory ポインタ ==="
echo ""

# Long-term Memory ポインタ（compact 経路と同様の ambient hint）
echo "[Long-term Memory] doobidoo にこのプロジェクトの知見が保存されている可能性があります。"
echo "[Long-term Memory] 必要に応じて mcp__doobidoo__memory_search で検索してください。"
echo ""

# --- 退避ファイルの発見（read-only） ---
# 1) 厳密 sid 一致を最優先（この会話系譜の「自分の」ファイル）
# 2) 無ければ最新 mtime の working-memory*.md（consumed 除外）へフォールバック
if [ -f "$WORKING_MEMORY_FILE" ]; then
    echo "[Working Memory] 退避された作業状態があります（read-only ポインタ）: $WORKING_MEMORY_FILE"
    echo "[Working Memory] /clear で文脈をリセットしました。続きをやるなら、このファイルを Read して作業状態を復元してください。"
    echo "[Working Memory] （このフックは復元を自動注入しません。読むかどうかはあなたの判断です。）"
    echo ""
else
    _newest="$(_find_newest_working_memory "$WORKING_MEMORY_DIR")"
    if [ -n "$_newest" ]; then
        echo "[Working Memory] 退避された作業状態があります（read-only ポインタ）: $_newest"
        echo "[Working Memory] /clear で session_id が変わったため、現セッション名義の退避ファイルとは一致しませんでした。"
        echo "[Working Memory] ※ これは cwd を共有する別セッション由来の可能性があります。内容を確認のうえ、続きなら Read してください。"
        echo "[Working Memory] （このフックは復元を自動注入しません。読むかどうかはあなたの判断です。）"
        echo ""
    fi
    unset _newest
fi

echo "=== [ready-compaction/SessionStart:clear] ここまで ==="
exit 0
