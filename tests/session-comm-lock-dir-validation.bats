#!/usr/bin/env bats
# session-comm-lock-dir-validation.bats
# Requirement: SESSION_COMM_LOCK_DIR が不在の場合に mkdir -p で自動作成し、
#   作成不可の場合は stderr エラー + exit 1 する（issue-1051）
# Spec: issue-1051
# Coverage: --type=unit --coverage=functional

# ===========================================================================
# setup / teardown
# ===========================================================================

setup() {
    PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$PLUGIN_ROOT/scripts/session-comm.sh"
    SANDBOX="$(mktemp -d)"
    unset _PERM_DENY_PARENT
    export SANDBOX SCRIPT PLUGIN_ROOT
}

teardown() {
    [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    # chmod 000 ディレクトリを残している場合に備えて cleanup
    if [[ -n "${_PERM_DENY_PARENT:-}" && -d "${_PERM_DENY_PARENT:-}" ]]; then
        chmod 755 "$_PERM_DENY_PARENT" 2>/dev/null || true
        rm -rf "$_PERM_DENY_PARENT" 2>/dev/null || true
    fi
}

# ===========================================================================
# AC1 (structural): cmd_inject 内に mkdir -p + Error メッセージガードが存在する
# RED: session-comm.sh に採用案 A の mkdir -p ブロックが未追加の時点で FAIL する
# ===========================================================================

@test "session-comm-lock-dir[structural][RED]: cmd_inject に mkdir -p lock_dir ガードが含まれる" {
    # AC1 の採用案 A: mkdir -p "$lock_dir" 2>/dev/null || { ... } が存在することを確認
    grep -F 'mkdir -p "$lock_dir"' "$SCRIPT" || {
        echo "FAIL: session-comm.sh の cmd_inject に [mkdir -p \"\$lock_dir\"] が含まれていない" >&2
        return 1
    }
}

@test "session-comm-lock-dir[structural][RED]: mkdir -p 失敗時の Error メッセージが含まれる" {
    # エラーメッセージの存在を構造的に確認
    grep -F "is not creatable" "$SCRIPT" | grep -F "SESSION_COMM_LOCK_DIR" || {
        echo "FAIL: session-comm.sh に 'is not creatable' + 'SESSION_COMM_LOCK_DIR' エラーメッセージが含まれていない" >&2
        return 1
    }
}

# ===========================================================================
# AC2-1 (functional): 不存在ディレクトリ → mkdir -p で自動作成 → flock 成功
# RED: mkdir -p ガードが未追加の時点では cmd_inject が lock_dir を作成せず
#      flock で lock_file の親ディレクトリが存在しないため失敗する
#
# 実装方針: cmd_inject の lock_dir validation ブロックのみをサブシェルで再現し、
#   mkdir -p による自動作成が行われることを検証する
# ===========================================================================

@test "session-comm-lock-dir[functional][RED]: 不存在ディレクトリは mkdir -p で自動作成される" {
    local nonexistent_dir="${SANDBOX}/nonexistent_lock_dir_$$"
    rm -rf "$nonexistent_dir" 2>/dev/null || true

    # cmd_inject の lock_dir validation ブロックをサブシェルで再現（session-comm.sh L274-284 と同期保持必要）
    # 実装後は mkdir -p が走り、ディレクトリが作成される
    # 実装前は mkdir -p が存在せず、ディレクトリが作成されない -> FAIL
    local created
    created=$(SESSION_COMM_LOCK_DIR="$nonexistent_dir" bash -c '
        set -euo pipefail
        lock_dir="${SESSION_COMM_LOCK_DIR:-/tmp}"
        if [[ -n "${SESSION_COMM_LOCK_DIR:-}" ]]; then
            if [[ "${SESSION_COMM_LOCK_DIR}" != /* ]] || [[ "${SESSION_COMM_LOCK_DIR}" =~ \.\. ]]; then
                echo "Warning: SESSION_COMM_LOCK_DIR invalid, using /tmp" >&2
                lock_dir="/tmp"
            fi
        fi
        # --- 採用案 A: 実装後に挿入されるブロック ---
        # 実装前はここに mkdir -p が存在しない
        mkdir -p "$lock_dir" 2>/dev/null || {
            echo "Error: SESSION_COMM_LOCK_DIR '"'"'$lock_dir'"'"' is not creatable" >&2
            exit 1
        }
        # -------------------------------------------
        if [[ -d "$lock_dir" ]]; then
            echo "created"
        else
            echo "not_created"
        fi
    ')

    [[ "$created" == "created" ]] || {
        echo "FAIL: SESSION_COMM_LOCK_DIR が不存在のとき mkdir -p で自動作成されなかった" >&2
        return 1
    }

    # session-comm.sh 本体が実際に mkdir -p を呼ぶことを構造確認
    grep -F 'mkdir -p "$lock_dir"' "$SCRIPT" || {
        echo "FAIL: session-comm.sh に mkdir -p \"\$lock_dir\" が存在しない（実装未完了）" >&2
        return 1
    }
}

# ===========================================================================
# AC2-2 (functional): 作成不可ディレクトリ → mkdir -p FAIL → stderr Error + exit 1
# RED: mkdir -p ガードが未追加の時点では exit 1 せず、flock で別のエラーになる
#
# NOTE: root 実行時は chmod 000 を回避できるため skip guard が必要
# ===========================================================================

@test "session-comm-lock-dir[functional][RED]: 作成不可ディレクトリで Error メッセージ + exit 1" {
    # root では chmod 000 が効かないためスキップ
    if [[ "$(id -u)" == "0" ]]; then
        skip "root 実行時は permission denied テストをスキップ"
    fi

    # chmod 000 の親ディレクトリを作成し、その下のサブディレクトリを lock_dir に指定
    local perm_deny_parent="${SANDBOX}/perm_deny_parent_$$"
    export _PERM_DENY_PARENT="$perm_deny_parent"
    mkdir -p "$perm_deny_parent"
    chmod 000 "$perm_deny_parent"
    local perm_deny_sub="${perm_deny_parent}/sub"

    # cmd_inject の lock_dir validation ブロックをサブシェルで再現（session-comm.sh L274-284 と同期保持必要）
    # 実装後は mkdir -p が失敗し、Error メッセージを stderr に出力して exit 1 する
    local stderr_output
    local exit_code=0
    stderr_output=$(SESSION_COMM_LOCK_DIR="$perm_deny_sub" bash -c '
        set -euo pipefail
        lock_dir="${SESSION_COMM_LOCK_DIR:-/tmp}"
        if [[ -n "${SESSION_COMM_LOCK_DIR:-}" ]]; then
            if [[ "${SESSION_COMM_LOCK_DIR}" != /* ]] || [[ "${SESSION_COMM_LOCK_DIR}" =~ \.\. ]]; then
                echo "Warning: SESSION_COMM_LOCK_DIR invalid, using /tmp" >&2
                lock_dir="/tmp"
            fi
        fi
        # --- 採用案 A: 実装後に挿入されるブロック ---
        mkdir -p "$lock_dir" 2>/dev/null || {
            echo "Error: SESSION_COMM_LOCK_DIR '"'"'$lock_dir'"'"' is not creatable" >&2
            exit 1
        }
        # -------------------------------------------
        echo "reached_flock"
    ' 2>&1 >/dev/null) || exit_code=$?

    # cleanup: teardown でも実施するが、ここで権限を戻しておく
    chmod 755 "$perm_deny_parent" 2>/dev/null || true

    [[ "$exit_code" -eq 1 ]] || {
        echo "FAIL: 作成不可 lock_dir で exit code が 1 ではなく ${exit_code} だった" >&2
        return 1
    }

    echo "$stderr_output" | grep -F "is not creatable" || {
        echo "FAIL: stderr に 'is not creatable' メッセージが含まれていない" >&2
        echo "  stderr: $stderr_output" >&2
        return 1
    }

    # session-comm.sh 本体の構造確認（実装未完了なら FAIL）
    grep -F 'mkdir -p "$lock_dir"' "$SCRIPT" || {
        echo "FAIL: session-comm.sh に mkdir -p \"\$lock_dir\" が存在しない（実装未完了）" >&2
        return 1
    }
}

# ===========================================================================
# AC2-3 (regression): 既存ディレクトリ /tmp → 通常動作（mkdir -p は冪等）
# GREEN 期待: mkdir -p は既存ディレクトリに対して no-op で成功する
# 実装前後どちらでも PASS するはずだが、実装後の回帰確認として定義する
#
# NOTE: このテストは cmd_inject の lock_dir validation ブロックを再現して
#   /tmp に対して mkdir -p が冪等であることを確認する（exit 0 を期待）
# ===========================================================================

@test "session-comm-lock-dir[regression]: 既存ディレクトリ /tmp では mkdir -p が冪等で成功する" {
    local exit_code=0
    SESSION_COMM_LOCK_DIR="/tmp" bash -c '
        set -euo pipefail
        lock_dir="${SESSION_COMM_LOCK_DIR:-/tmp}"
        if [[ -n "${SESSION_COMM_LOCK_DIR:-}" ]]; then
            if [[ "${SESSION_COMM_LOCK_DIR}" != /* ]] || [[ "${SESSION_COMM_LOCK_DIR}" =~ \.\. ]]; then
                echo "Warning: SESSION_COMM_LOCK_DIR invalid, using /tmp" >&2
                lock_dir="/tmp"
            fi
        fi
        # 採用案 A: 既存ディレクトリに対しては冪等（no-op）で成功するはず
        mkdir -p "$lock_dir" 2>/dev/null || {
            echo "Error: SESSION_COMM_LOCK_DIR '"'"'$lock_dir'"'"' is not creatable" >&2
            exit 1
        }
        echo "ok"
    ' || exit_code=$?

    [[ "$exit_code" -eq 0 ]] || {
        echo "FAIL: 既存ディレクトリ /tmp で mkdir -p が失敗した（exit $exit_code）" >&2
        return 1
    }
}
