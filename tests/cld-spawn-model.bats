#!/usr/bin/env bats
# cld-spawn-model.bats - --model オプションの unit tests
#
# --model オプション伝播のテスト
#
# Scenarios covered:
#   - --model オプションを指定: 生成された LAUNCHER に `cld --model sonnet` が含まれる
#   - --model オプションなし: 生成された LAUNCHER に `--model` フラグが含まれない
#
# Edge cases:
#   - --model に空文字を渡した場合のエラー処理
#   - --model と --env-file の組み合わせ

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
CLD_SPAWN="$SCRIPT_DIR/cld-spawn"

# ---------------------------------------------------------------------------
# セットアップ
#
# cld-spawn は tmux に依存するため以下をスタブ化する:
#   - tmux          : 何もしない stub（exit 0）
#   - flock         : ロック取得を即成功させる stub
#   - session-comm.sh: inject-file 呼び出しを無効化
#   - session-name.sh: generate_window_name / find_existing_window をスタブ
#   - mktemp        : LAUNCHER パスを固定して内容検証を可能にする
# ---------------------------------------------------------------------------

setup() {
    SANDBOX="$(mktemp -d)"
    export LAUNCHER_PATH="$SANDBOX/launcher.sh"
    export FAKE_BIN="$SANDBOX/bin"
    mkdir -p "$FAKE_BIN"

    # --- tmux stub ---
    cat > "$FAKE_BIN/tmux" <<'TMUX_STUB'
#!/bin/bash
case "${1:-}" in
    list-windows)
        echo "${WINDOW_NAME_STUB:-cld-spawn-test}"
        ;;
    display-message)
        echo "main"
        ;;
esac
exit 0
TMUX_STUB
    chmod +x "$FAKE_BIN/tmux"

    # --- mktemp stub: LAUNCHER パスを固定 ---
    cat > "$FAKE_BIN/mktemp" <<MKTEMP_STUB
#!/bin/bash
if [[ "\$*" == *"cld-spawn-XXXXXX.sh"* ]]; then
    touch "${LAUNCHER_PATH}"
    echo "${LAUNCHER_PATH}"
else
    /usr/bin/mktemp "\$@"
fi
MKTEMP_STUB
    chmod +x "$FAKE_BIN/mktemp"

    # --- flock stub ---
    cat > "$FAKE_BIN/flock" <<'FLOCK_STUB'
#!/bin/bash
exit 0
FLOCK_STUB
    chmod +x "$FAKE_BIN/flock"

    # --- スタブスクリプトディレクトリ ---
    export STUB_SCRIPTS="$SANDBOX/scripts"
    mkdir -p "$STUB_SCRIPTS"

    # session-name.sh: generate_window_name / find_existing_window をスタブ
    cat > "$STUB_SCRIPTS/session-name.sh" <<'SESSION_STUB'
generate_window_name() { echo "cld-spawn-test"; }
find_existing_window()  { echo ""; }
SESSION_STUB

    # window-manifest.sh: source されても安全な空スタブ
    touch "$STUB_SCRIPTS/window-manifest.sh"

    # lib/session-env.sh: cld-spawn が source する namespace 定義（実体をコピー）
    mkdir -p "$STUB_SCRIPTS/lib"
    cp "$SCRIPT_DIR/lib/session-env.sh" "$STUB_SCRIPTS/lib/session-env.sh"

    # session-comm.sh: inject-file 呼び出しを無効化
    cat > "$STUB_SCRIPTS/session-comm.sh" <<'COMM_STUB'
#!/bin/bash
exit 0
COMM_STUB
    chmod +x "$STUB_SCRIPTS/session-comm.sh"

    # cld stub（LAUNCHER 内の cld 実行を無害化）
    cat > "$FAKE_BIN/cld-stub" <<'CLD_STUB'
#!/bin/bash
exit 0
CLD_STUB
    chmod +x "$FAKE_BIN/cld-stub"
    export CLD_PATH="$FAKE_BIN/cld-stub"

    # cld-spawn 本体をスタブスクリプトディレクトリにコピー
    cp "$CLD_SPAWN" "$STUB_SCRIPTS/cld-spawn"
    chmod +x "$STUB_SCRIPTS/cld-spawn"

    # HOME を SANDBOX 内に設定（state ディレクトリ作成を安全に）
    export HOME="$SANDBOX/home"
    mkdir -p "$HOME/.local/state/claude-session"

    # TMUX 環境変数: cld-spawn の tmux チェックをパスさせる
    export TMUX="fake-tmux-socket,12345,0"

    export PATH="$FAKE_BIN:$PATH"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

# ---------------------------------------------------------------------------
# _run_spawn: スタブ環境で cld-spawn を実行し LAUNCHER 内容を取得する
#
# 実行後グローバル変数:
#   $status           - 終了コード（bats run が設定）
#   $LAUNCHER_CONTENT - 生成された LAUNCHER スクリプトの内容
# ---------------------------------------------------------------------------
_run_spawn() {
    run bash "$STUB_SCRIPTS/cld-spawn" "$@"
    LAUNCHER_CONTENT=""
    if [[ -f "$LAUNCHER_PATH" ]]; then
        LAUNCHER_CONTENT="$(cat "$LAUNCHER_PATH")"
    fi
}

# ===========================================================================
# Requirement: cld-spawn --model オプション
# ===========================================================================

# ---------------------------------------------------------------------------
# Scenario: --model オプションを指定
# WHEN cld-spawn --model sonnet を呼び出す
# THEN 生成されたランチャースクリプトに `cld --model sonnet` が含まれる
# ---------------------------------------------------------------------------

@test "model-option: --model オプションがコマンドラインパーサーに存在する" {
    # --model を指定しても 'unknown option' エラーにならないことを確認
    _run_spawn --model sonnet
    [[ "$output" != *"不明なオプション"* ]] \
        || fail "--model option not recognized by cld-spawn"
    [[ "$output" != *"unknown option"* ]] \
        || fail "--model option not recognized by cld-spawn"
}

@test "model-option: --model sonnet 指定時に正常終了する" {
    _run_spawn --model sonnet
    [[ "$status" -eq 0 ]] \
        || fail "cld-spawn --model sonnet should exit 0, got $status. Output: $output"
}

@test "model-option: --model sonnet 指定時に LAUNCHER が生成される" {
    _run_spawn --model sonnet
    [[ -n "$LAUNCHER_CONTENT" ]] \
        || fail "LAUNCHER script was not generated when --model sonnet specified"
}

@test "model-option: --model sonnet 指定時に LAUNCHER に 'cld --model sonnet' が含まれる" {
    # WHEN: cld-spawn --model sonnet を呼び出す
    _run_spawn --model sonnet
    # THEN: 生成された LAUNCHER スクリプトに cld --model sonnet が含まれる
    [[ "$LAUNCHER_CONTENT" == *"--model sonnet"* ]] \
        || fail "LAUNCHER does not contain '--model sonnet'. Content: $LAUNCHER_CONTENT"
}

@test "model-option: --model haiku 指定時に LAUNCHER に '--model haiku' が含まれる" {
    _run_spawn --model haiku
    [[ "$status" -eq 0 ]] \
        || fail "cld-spawn --model haiku should exit 0, got $status"
    [[ "$LAUNCHER_CONTENT" == *"--model haiku"* ]] \
        || fail "LAUNCHER does not contain '--model haiku'. Content: $LAUNCHER_CONTENT"
}

@test "model-option: --model の値が cld コマンドに引数として渡される" {
    _run_spawn --model opus
    [[ "$LAUNCHER_CONTENT" == *"--model opus"* ]] \
        || fail "LAUNCHER does not pass --model opus to cld. Content: $LAUNCHER_CONTENT"
}

# ---------------------------------------------------------------------------
# Scenario: --model オプションなし
# WHEN cld-spawn を --model なしで呼び出す
# THEN 生成されたランチャースクリプトに --model フラグが含まれず、既存動作と変わらない
# ---------------------------------------------------------------------------

@test "model-option: --model 未指定時に正常終了する" {
    _run_spawn
    [[ "$status" -eq 0 ]] \
        || fail "cld-spawn without --model should exit 0, got $status. Output: $output"
}

@test "model-option: --model 未指定時に LAUNCHER が生成される" {
    _run_spawn
    [[ -n "$LAUNCHER_CONTENT" ]] \
        || fail "LAUNCHER script was not generated when --model not specified"
}

@test "model-option: --model 未指定時に LAUNCHER に '--model' フラグが含まれない" {
    # WHEN: cld-spawn を --model なしで呼び出す
    # 既存の env-file テストと同様に --model オプションなしで起動
    unset CLD_DEFAULT_MODEL 2>/dev/null || true
    _run_spawn
    # THEN: 生成された LAUNCHER スクリプトに --model フラグが含まれない
    [[ "$LAUNCHER_CONTENT" != *"--model"* ]] \
        || fail "LAUNCHER should not contain '--model' when not specified. Content: $LAUNCHER_CONTENT"
}

@test "model-option: --model 未指定時の既存動作が変わらない（cld のみが LAUNCHER に含まれる）" {
    _run_spawn
    # LAUNCHER 内に cld の実行行が存在すること
    [[ -n "$LAUNCHER_CONTENT" ]] \
        || fail "LAUNCHER was not generated"
    # --model フラグがないことを確認
    [[ "$LAUNCHER_CONTENT" != *"--model"* ]] \
        || fail "Unexpected --model in LAUNCHER when not specified"
}

# ===========================================================================
# Edge cases
# ===========================================================================

@test "model-option: --model に空文字を渡した場合はエラーになる" {
    # --model には値が必要なので空文字はエラーとなるべき
    _run_spawn --model ""
    # exit 1 またはエラーメッセージが期待される
    [[ "$status" -ne 0 ]] \
        || [[ "$output" == *"--model"* ]] \
        || fail "Expected error when --model given empty string, got status=$status"
}

@test "model-option: --model と --env-file を組み合わせた場合も正常動作する" {
    local fake_env="$SANDBOX/fake-secrets"
    touch "$fake_env"
    _run_spawn --model sonnet --env-file "$fake_env"
    [[ "$status" -eq 0 ]] \
        || fail "--model and --env-file combination failed: $output"
    # 両方が LAUNCHER に反映される
    [[ "$LAUNCHER_CONTENT" == *"--model sonnet"* ]] \
        || fail "LAUNCHER missing --model sonnet with --env-file. Content: $LAUNCHER_CONTENT"
}

@test "model-option: --model と --cd を組み合わせた場合も正常動作する" {
    _run_spawn --model sonnet --cd "$SANDBOX"
    [[ "$status" -eq 0 ]] \
        || fail "--model and --cd combination failed: $output"
    [[ "$LAUNCHER_CONTENT" == *"--model sonnet"* ]] \
        || fail "LAUNCHER missing --model sonnet with --cd. Content: $LAUNCHER_CONTENT"
}
