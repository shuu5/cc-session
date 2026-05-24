#!/usr/bin/env bats
# path-validate.bats — validate_supervisor_dir() unit tests
# Issue #1165: SUPERVISOR_DIR パストラバーサル防御
# RED フェーズ — path-validate.sh 実装前は全テストが fail する

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
PATH_VALIDATE_SH="$SCRIPT_DIR/lib/path-validate.sh"

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    # symlink: $TMPDIR_TEST/sym -> /etc
    ln -s /etc "$TMPDIR_TEST/sym"
}

teardown() {
    [[ -n "${TMPDIR_TEST:-}" && -d "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# AC3(#1165): valid_home — $HOME 配下の path は accept (exit 0)
# RED: path-validate.sh 未実装のため source が失敗し fail する
# ---------------------------------------------------------------------------
@test "AC3(#1165): valid_home — HOME 配下の path は accept する (exit 0)" {
    # RED: path-validate.sh 未実装のため fail する
    run bash -c "source '$PATH_VALIDATE_SH' && validate_supervisor_dir '$HOME/foo/.supervisor'"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC3(#1165): valid_pwd — $PWD 配下の path は accept (exit 0)
# RED: path-validate.sh 未実装のため fail する
# ---------------------------------------------------------------------------
@test "AC3(#1165): valid_pwd — PWD 配下の path は accept する (exit 0)" {
    # RED: path-validate.sh 未実装のため fail する
    run bash -c "source '$PATH_VALIDATE_SH' && validate_supervisor_dir '$PWD/.supervisor'"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC3(#1165): valid_tmpdir — TMPDIR 配下の path は accept (exit 0)
# RED: path-validate.sh 未実装のため fail する
# ---------------------------------------------------------------------------
@test "AC3(#1165): valid_tmpdir — TMPDIR 配下の path は accept する (exit 0)" {
    # RED: path-validate.sh 未実装のため fail する
    local tmpbase="${TMPDIR:-/tmp}"
    run bash -c "source '$PATH_VALIDATE_SH' && validate_supervisor_dir '${tmpbase}/x/.supervisor'"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2(#1165): valid_canonical_missing — 存在しない $HOME 配下の path も accept (exit 0)
# GNU realpath --canonicalize-missing で正規化するため存在しなくても許可される
# RED: path-validate.sh 未実装のため fail する
# ---------------------------------------------------------------------------
@test "AC2(#1165): valid_canonical_missing — HOME 配下の存在しない path も accept する (exit 0)" {
    # RED: path-validate.sh 未実装のため fail する
    run bash -c "source '$PATH_VALIDATE_SH' && validate_supervisor_dir '$HOME/non-existent/.supervisor'"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC3(#1165): reject_dotdot — /tmp/../etc は reject (exit != 0)
# raw 入力に .. セグメント含有 → reject
# RED: path-validate.sh 未実装のため fail する
# ---------------------------------------------------------------------------
@test "AC3(#1165): reject_dotdot — /tmp/../etc は reject する (exit != 0)" {
    # RED: path-validate.sh 未実装のため source が失敗しこのテスト自体が fail する
    source "$PATH_VALIDATE_SH"
    run validate_supervisor_dir '/tmp/../etc'
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC3(#1165): reject_relative_dotdot — ../../etc/passwd は reject (exit != 0)
# raw 入力に .. セグメント含有 → reject
# RED: path-validate.sh 未実装のため fail する
# ---------------------------------------------------------------------------
@test "AC3(#1165): reject_relative_dotdot — ../../etc/passwd は reject する (exit != 0)" {
    # RED: path-validate.sh 未実装のため source が失敗しこのテスト自体が fail する
    source "$PATH_VALIDATE_SH"
    run validate_supervisor_dir '../../etc/passwd'
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC3(#1165): reject_outside_whitelist — /etc/foo は whitelist 外 → reject (exit != 0)
# 正規化後に $HOME/ / $PWD/ / ${TMPDIR:-/tmp}/ のいずれにも該当しない
# RED: path-validate.sh 未実装のため fail する
# ---------------------------------------------------------------------------
@test "AC3(#1165): reject_outside_whitelist — /etc/foo は whitelist 外のため reject する (exit != 0)" {
    # RED: path-validate.sh 未実装のため source が失敗しこのテスト自体が fail する
    source "$PATH_VALIDATE_SH"
    run validate_supervisor_dir '/etc/foo'
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC3(#1165): reject_empty — 空文字は reject (exit != 0)
# RED: path-validate.sh 未実装のため fail する
# ---------------------------------------------------------------------------
@test "AC3(#1165): reject_empty — 空文字は reject する (exit != 0)" {
    # RED: path-validate.sh 未実装のため source が失敗しこのテスト自体が fail する
    source "$PATH_VALIDATE_SH"
    run validate_supervisor_dir ''
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# AC3(#1165): reject_symlink_escape — symlink -> /etc は reject (exit != 0)
# 正規化後に whitelist 外の path に解決される symlink は reject
# RED: path-validate.sh 未実装のため fail する
# ---------------------------------------------------------------------------
@test "AC3(#1165): reject_symlink_escape — /etc へのシンボリックリンクは reject する (exit != 0)" {
    # RED: path-validate.sh 未実装のため source が失敗しこのテスト自体が fail する
    # setup() で $TMPDIR_TEST/sym -> /etc が作成されている
    source "$PATH_VALIDATE_SH"
    run validate_supervisor_dir "$TMPDIR_TEST/sym"
    [ "$status" -ne 0 ]
}
