#!/usr/bin/env bash
# path-validate.sh — SUPERVISOR_DIR パストラバーサル防御 (Issue #1165)
#
# Usage: source path-validate.sh && validate_supervisor_dir <path>
# On success: prints canonical path to stdout, returns 0
# On failure: returns 2

validate_supervisor_dir() {
    local raw_path="$1"

    # 空文字チェック
    if [[ -z "$raw_path" ]]; then
        return 2
    fi

    # .. セグメント含有チェック（raw 入力で拒否）
    if [[ "$raw_path" == *".."* ]]; then
        return 2
    fi

    # 正規化（シンボリックリンク解決 + canonicalize-missing で存在不要）
    # python3 fallback; 両方不在の場合は reject (Issue #1165 AC2)
    local canonical_path
    if command -v realpath >/dev/null 2>&1; then
        canonical_path=$(realpath -m "$raw_path" 2>/dev/null) || return 2
    elif command -v python3 >/dev/null 2>&1; then
        canonical_path=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$raw_path" 2>/dev/null) || return 2
    else
        return 2
    fi

    # whitelist: HOME / PWD / TMPDIR 配下のみ許可
    local home_dir="${HOME:-}"
    local pwd_dir="${PWD:-}"
    local tmp_dir="${TMPDIR:-/tmp}"

    local accepted=false
    [[ -n "$home_dir" && "$canonical_path" == "$home_dir/"* ]] && accepted=true
    [[ -n "$pwd_dir" && "$canonical_path" == "$pwd_dir/"* ]] && accepted=true
    [[ "$canonical_path" == "$tmp_dir/"* ]] && accepted=true

    if $accepted; then
        echo "$canonical_path"
        return 0
    fi

    return 2
}
