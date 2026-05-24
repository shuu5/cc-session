#!/usr/bin/env bats
# session-comm-script-dir-validate.bats
# Requirement: SESSION_COMM_SCRIPT_DIR + _TEST_MODE による SCRIPT_DIR 上書き対策（issue-1048）
# Spec: issue-1048
# Coverage: --type=unit --coverage=security
#
# 検証する仕様:
#   1. SCRIPT_DIR 上書き条件に [[ -d "$SESSION_COMM_SCRIPT_DIR" ]]（実在ディレクトリチェック）が含まれる
#   2. SCRIPT_DIR 上書き条件に session-state.sh 存在チェックが含まれる（信頼境界の追加検証）
#   3. _TEST_MODE ガードは引き続き必須（regression）
#   4. Functional: 存在しない SESSION_COMM_SCRIPT_DIR で session-comm.sh が起動でき、
#      default SCRIPT_DIR の session-state.sh path が使われる（既存 .test.sh で間接的に保証）

setup() {
    PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$PLUGIN_ROOT/scripts/session-comm.sh"
    SANDBOX="$(mktemp -d)"
    export SANDBOX
}

teardown() {
    [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

# ===========================================================================
# AC1 (structural): SCRIPT_DIR 上書き条件に -d (実在ディレクトリ) チェックが含まれる
# Spec: issue-1048 「SESSION_COMM_SCRIPT_DIR の値が実在するディレクトリであることをチェック」
# ===========================================================================

@test "session-comm-script-dir[security][RED]: SCRIPT_DIR 上書き条件に [[ -d \"\$SESSION_COMM_SCRIPT_DIR\" ]] が含まれる" {
    # SESSION_COMM_SCRIPT_DIR が含まれる行の前後で [[ -d ... ]] チェックが存在することを確認
    grep -F '[[ -d "$SESSION_COMM_SCRIPT_DIR"' "$SCRIPT" || {
        echo "FAIL: session-comm.sh に [[ -d \"\$SESSION_COMM_SCRIPT_DIR\" ]] 検証が含まれていない" >&2
        return 1
    }
}

# ===========================================================================
# AC2 (structural): SCRIPT_DIR 上書き条件に session-state.sh 存在検証が含まれる
# 信頼境界をより厳格にし、攻撃者が任意ディレクトリを偽装することを防ぐ
# ===========================================================================

@test "session-comm-script-dir[security][RED]: SCRIPT_DIR 上書き条件に session-state.sh 存在検証 (-f) が含まれる" {
    # SCRIPT_DIR 上書きブロック内で session-state.sh の存在検証が行われていることを確認
    # 該当行の前後 5 行で session-state.sh + -f を含むことを確認
    awk '/SESSION_COMM_SCRIPT_DIR/,/SCRIPT_DIR=/' "$SCRIPT" | grep -F 'session-state.sh' | grep -F -- '-f' || {
        echo "FAIL: session-comm.sh の SCRIPT_DIR 上書きブロックに session-state.sh -f 検証が含まれていない" >&2
        return 1
    }
}

# ===========================================================================
# AC3 (regression): _TEST_MODE ガードは引き続き必須
# ===========================================================================

@test "session-comm-script-dir[regression]: _TEST_MODE ガードは引き続き SCRIPT_DIR 上書き条件に含まれる" {
    grep -F '_TEST_MODE' "$SCRIPT" | grep -F 'SESSION_COMM_SCRIPT_DIR' || {
        # 同一行になくても 4-line の if 連鎖内にあれば OK
        # if 文のブロック範囲で確認
        awk '/^if \[\[ -n "\$\{_TEST_MODE/,/^fi$/' "$SCRIPT" | head -8 | grep -F '_TEST_MODE' || {
            echo "FAIL: _TEST_MODE ガードが SCRIPT_DIR 上書き条件に含まれていない" >&2
            return 1
        }
    }
}

# ===========================================================================
# AC4 (functional): 存在しない SESSION_COMM_SCRIPT_DIR で session-comm.sh は default SCRIPT_DIR にfallback する
# 動作検証: subshell で session-comm.sh の SCRIPT_DIR 設定部分を抽出して評価
# ===========================================================================

@test "session-comm-script-dir[security][functional]: 存在しないディレクトリでは default SCRIPT_DIR にfallback" {
    local fake_dir="/tmp/twl-test-1048-nonexistent-$$-deliberate"
    rm -rf "$fake_dir" 2>/dev/null || true

    # session-comm.sh の SCRIPT_DIR 設定部分を抽出 (15-24 行目程度)
    # head + tail で抽出した validation block を bash -c で評価
    # BASH_SOURCE[0] を SCRIPT path に設定して default branch の動作を確認
    local result
    result=$(SCRIPT_PATH="$SCRIPT" TM=1 CD="$fake_dir" bash -c '
        # session-comm.sh の SCRIPT_DIR 設定ロジックを抽出して実行
        # BASH_SOURCE[0] を設定して default 分岐が正しく PLUGIN_ROOT/scripts を返すよう構成
        BASH_SOURCE=("$SCRIPT_PATH")
        _TEST_MODE="$TM"
        SESSION_COMM_SCRIPT_DIR="$CD"
        # session-comm.sh の line 18-24 と等価な検証ブロックを実行
        if [[ -n "${_TEST_MODE:-}" ]] && [[ -n "${SESSION_COMM_SCRIPT_DIR:-}" ]] \
            && [[ -d "$SESSION_COMM_SCRIPT_DIR" ]] \
            && [[ -f "$SESSION_COMM_SCRIPT_DIR/session-state.sh" ]]; then
            SCRIPT_DIR="$SESSION_COMM_SCRIPT_DIR"
        else
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        fi
        echo "$SCRIPT_DIR"
    ')

    [[ "$result" != "$fake_dir" ]] || {
        echo "FAIL: 存在しないディレクトリで SCRIPT_DIR が上書きされた: $result" >&2
        return 1
    }
}

# ===========================================================================
# AC5 (functional): session-state.sh を含む実在ディレクトリは引き続き上書き許可（regression）
# ===========================================================================

@test "session-comm-script-dir[regression]: session-state.sh を含む実在ディレクトリは上書き許可される" {
    local mock_dir="$SANDBOX/mock_scripts"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/session-state.sh" <<'STUB'
#!/bin/bash
echo "mock"
STUB
    chmod +x "$mock_dir/session-state.sh"

    local result
    result=$(SCRIPT_PATH="$SCRIPT" TM=1 CD="$mock_dir" bash -c '
        BASH_SOURCE=("$SCRIPT_PATH")
        _TEST_MODE="$TM"
        SESSION_COMM_SCRIPT_DIR="$CD"
        if [[ -n "${_TEST_MODE:-}" ]] && [[ -n "${SESSION_COMM_SCRIPT_DIR:-}" ]] \
            && [[ -d "$SESSION_COMM_SCRIPT_DIR" ]] \
            && [[ -f "$SESSION_COMM_SCRIPT_DIR/session-state.sh" ]]; then
            SCRIPT_DIR="$SESSION_COMM_SCRIPT_DIR"
        else
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        fi
        echo "$SCRIPT_DIR"
    ')

    [[ "$result" == "$mock_dir" ]] || {
        echo "FAIL: 正規の mock_scripts dir で SCRIPT_DIR が上書きされなかった: $result (expected: $mock_dir)" >&2
        return 1
    }
}

# ===========================================================================
# M2 (#1048 follow-up): TOCTOU race window 縮小のための realpath 解決
# SESSION_COMM_SCRIPT_DIR が symlink を経由する場合でも、実 path に解決して
# SCRIPT_DIR に固定することで check と use の間の race window を縮小する。
# ===========================================================================

@test "session-comm-script-dir[M2 structural]: realpath fallback chain (realpath / greadlink / python3) が含まれる" {
    grep -F 'command -v realpath' "$SCRIPT" || {
        echo "FAIL: SCRIPT_DIR 設定ブロックに realpath fallback が含まれていない" >&2
        return 1
    }
    grep -F 'command -v greadlink' "$SCRIPT" || {
        echo "FAIL: SCRIPT_DIR 設定ブロックに greadlink fallback が含まれていない" >&2
        return 1
    }
    grep -F 'os.path.realpath' "$SCRIPT" || {
        echo "FAIL: SCRIPT_DIR 設定ブロックに python3 os.path.realpath fallback が含まれていない" >&2
        return 1
    }
}

@test "session-comm-script-dir[M2 functional]: SESSION_COMM_SCRIPT_DIR が symlink でも SCRIPT_DIR は実 path になる" {
    local real_dir="$SANDBOX/real_scripts"
    local symlink_dir="$SANDBOX/symlink_scripts"
    mkdir -p "$real_dir"
    cat > "$real_dir/session-state.sh" <<'STUB'
#!/bin/bash
echo "real-mock"
STUB
    chmod +x "$real_dir/session-state.sh"
    ln -s "$real_dir" "$symlink_dir"

    # session-comm.sh の SCRIPT_DIR 設定ブロックを subshell で再実行（前回 #1048 と同じ pattern）
    local result
    result=$(SCRIPT_PATH="$SCRIPT" TM=1 CD="$symlink_dir" bash -c '
        BASH_SOURCE=("$SCRIPT_PATH")
        _TEST_MODE="$TM"
        SESSION_COMM_SCRIPT_DIR="$CD"
        if [[ -n "${_TEST_MODE:-}" ]] && [[ -n "${SESSION_COMM_SCRIPT_DIR:-}" ]] \
            && [[ -d "$SESSION_COMM_SCRIPT_DIR" ]] \
            && [[ -f "$SESSION_COMM_SCRIPT_DIR/session-state.sh" ]]; then
            _resolved_state=""
            if command -v realpath >/dev/null 2>&1; then
              _resolved_state=$(realpath "$SESSION_COMM_SCRIPT_DIR/session-state.sh" 2>/dev/null || true)
            fi
            if [[ -z "$_resolved_state" ]] && command -v greadlink >/dev/null 2>&1; then
              _resolved_state=$(greadlink -f "$SESSION_COMM_SCRIPT_DIR/session-state.sh" 2>/dev/null || true)
            fi
            if [[ -z "$_resolved_state" ]] && command -v python3 >/dev/null 2>&1; then
              _resolved_state=$(python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$SESSION_COMM_SCRIPT_DIR/session-state.sh" 2>/dev/null || true)
            fi
            if [[ -n "$_resolved_state" && -f "$_resolved_state" ]]; then
              SCRIPT_DIR=$(dirname "$_resolved_state")
            else
              SCRIPT_DIR="$SESSION_COMM_SCRIPT_DIR"
            fi
        else
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        fi
        echo "$SCRIPT_DIR"
    ')

    [[ "$result" == "$real_dir" ]] || {
        echo "FAIL: SESSION_COMM_SCRIPT_DIR が symlink ($symlink_dir) の場合、SCRIPT_DIR が実 path ($real_dir) ではなく $result になった" >&2
        return 1
    }
}
