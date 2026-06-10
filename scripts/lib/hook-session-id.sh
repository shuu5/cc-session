#!/usr/bin/env bash
# hook-session-id.sh — hook stdin JSON から session_id を抽出する純ヘルパー
#
# 全 hook の stdin JSON には session_id が必ず含まれる（documented・全 hook 共通
# フィールド: session_id / transcript_path / cwd / hook_event_name / permission_mode）。
# /compact 跨ぎでも同一 session_id を保持する。よって hook はこの stdin の session_id を
# session-scoped な Working Memory パス解決の一次ソースにする（CLAUDE_CODE_SESSION_ID の
# hook subprocess env 継承は undocumented＝不確実なため、env は session-env.sh 内の
# 二次フォールバックに留める／defense-in-depth）。
#
# 抽出パターンは確立済みの scripts/claude-session-save.sh（jq -r '.session_id // empty'）に倣う。
# jq 不在環境のため sed フォールバックも用意する（hook は壊さない＝抽出不能なら無出力）。
#
# 設計方針: 純関数のみ（副作用なし、stdout 生成）。多重 source ガード付き。

[ -n "${_HOOK_SESSION_ID_SH_SOURCED:-}" ] && return 0
_HOOK_SESSION_ID_SH_SOURCED=1

# hook_extract_session_id
#   stdin の hook JSON から .session_id を抽出し stdout へ出す。
#   - stdin が tty（インタラクティブ実行・パイプ無し）なら即 return 0（read による
#     ブロックを回避＝対話端末で誤って source して呼んでもハングさせない）。
#   - 非 tty なら全 stdin を読み、jq があれば .session_id を、無ければ sed で抽出。
#   - 抽出不能（session_id 欠落・空 JSON 等）なら無出力。
hook_extract_session_id() {
    # tty に繋がっている（パイプされていない）なら読まずに即返す
    [ -t 0 ] && return 0

    local input sid
    input="$(cat)"
    [ -z "$input" ] && return 0

    if command -v jq >/dev/null 2>&1; then
        sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
    else
        # jq 不在フォールバック: "session_id": "..." の最初の値を引く
        sid="$(printf '%s' "$input" \
            | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            | head -n1)"
    fi

    [ -n "$sid" ] && printf '%s' "$sid"
    return 0
}
