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

# ディレクトリ内の非 consumed working-memory*.md を mtime 降順で stdout に列挙する純関数。
# read-only（glob と -nt 比較のみ。ファイルには一切触れない）。最新 1 件だけでなく
# 全候補を返すのは、自分の古い pre-clear ファイルが並走セッションの新しいファイルの陰に
# 隠れる発見ギャップ（un-gcu corr-2）を防ぐため。
_collect_working_memory() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    local files=() f b
    shopt -s nullglob
    for f in "$dir"/working-memory*.md; do
        b="$(basename "$f")"
        case "$b" in
            *.consumed.md) continue ;;  # 復元済み（consumed）は提示対象外
        esac
        files+=("$f")
    done
    shopt -u nullglob
    local n=${#files[@]}
    [ "$n" -eq 0 ] && return 0
    # selection sort by mtime desc（小 n 前提・subprocess 不使用）
    local i j sel tmp
    for ((i = 0; i < n; i++)); do
        sel=$i
        for ((j = i + 1; j < n; j++)); do
            [ "${files[$j]}" -nt "${files[$sel]}" ] && sel=$j
        done
        if [ "$sel" -ne "$i" ]; then
            tmp="${files[$i]}"; files[$i]="${files[$sel]}"; files[$sel]="$tmp"
        fi
        printf '%s\n' "${files[$i]}"
    done
}

echo "=== [ready-compaction/SessionStart:clear] Working Memory ポインタ ==="
echo ""

# Long-term Memory ポインタ（compact 経路と同様の ambient hint）
echo "[Long-term Memory] doobidoo にこのプロジェクトの知見が保存されている可能性があります。"
echo "[Long-term Memory] 必要に応じて mcp__doobidoo__memory_search で検索してください。"
echo ""

# --- 退避ファイルの発見（read-only） ---
# 1) 厳密 sid 一致を最優先（この会話系譜の「自分の」ファイル）。曖昧さが無いので 1 件提示。
# 2) 無ければ非 consumed 候補を mtime 降順で「すべて」列挙（最新 1 件のみだと自分の古い
#    pre-clear ファイルが並走セッションの新しいファイルに隠れる・un-gcu corr-2）。
#    原因（sid 変化 / sid 未解決 / 自セッション未書込 + 並走ファイル）は区別不能なので
#    断定せず「可能性」として正直に提示する（docs-1 / un-gcu corr-1: changeset 自身が
#    session_id 変化を uncertain と明記しているため確定原因を出さない）。
if [ -f "$WORKING_MEMORY_FILE" ]; then
    echo "[Working Memory] 退避された作業状態があります（read-only ポインタ）: $WORKING_MEMORY_FILE"
    echo "[Working Memory] /clear で文脈をリセットしました。続きをやるなら、このファイルを Read して作業状態を復元してください。"
    echo "[Working Memory] （このフックは復元を自動注入しません。読むかどうかはあなたの判断です。）"
    echo ""
else
    _wm_list="$(_collect_working_memory "$WORKING_MEMORY_DIR")"
    if [ -n "$_wm_list" ]; then
        echo "[Working Memory] 現セッション名義（$WORKING_MEMORY_FILE）の退避ファイルは見つかりませんでした。"
        echo "[Working Memory] ※ 以下は別セッション由来、または /clear で session_id が変わった自セッションの退避ファイルの可能性があります（区別不能・mtime 降順）:"
        _wm_n=0
        while IFS= read -r _wm_f; do
            [ -z "$_wm_f" ] && continue
            _wm_n=$((_wm_n + 1))
            [ "$_wm_n" -le 10 ] && echo "  - $_wm_f"
        done <<WM_EOF
$_wm_list
WM_EOF
        [ "$_wm_n" -gt 10 ] && echo "  …他 $((_wm_n - 10)) 件"
        echo "[Working Memory] 内容を確認のうえ、続きなら該当ファイルを Read してください。"
        echo "[Working Memory] （このフックは復元を自動注入しません。読むかどうかはあなたの判断です。）"
        echo ""
        unset _wm_n _wm_f
    fi
    unset _wm_list
fi

echo "=== [ready-compaction/SessionStart:clear] ここまで ==="
exit 0
