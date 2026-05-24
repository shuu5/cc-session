#!/usr/bin/env bats
# cld-spawn-env-file.bats - --env-file / CLD_ENV_FILE オプションの unit tests
# Issue #573: cld-spawn に --env-file オプションを追加

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
#
# LAUNCHER スクリプト（/tmp/cld-spawn-XXXXXX.sh）の生成パスを固定するため
# mktemp もスタブ化する。
# ---------------------------------------------------------------------------

setup() {
    SANDBOX="$(mktemp -d)"
    export LAUNCHER_PATH="$SANDBOX/launcher.sh"
    export FAKE_BIN="$SANDBOX/bin"
    mkdir -p "$FAKE_BIN"

    # --- tmux stub ---
    cat > "$FAKE_BIN/tmux" <<TMUX_STUB
#!/bin/bash
case "\${1:-}" in
    list-windows)
        # Verify window was created をパスさせるため window 名を出力
        echo "\${WINDOW_NAME_STUB:-cld-spawn-test}"
        ;;
    display-message)
        echo "main"
        ;;
esac
exit 0
TMUX_STUB
    chmod +x "$FAKE_BIN/tmux"

    # --- mktemp stub ---
    # /tmp/cld-spawn-XXXXXX.sh へのリクエストを固定パスに差し替え
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

    # cld stub（LAUNCHER内のcld実行を無害化）
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
#   $status          - 終了コード（bats run が設定）
#   $LAUNCHER_CONTENT - 生成された LAUNCHER スクリプトの内容
# ---------------------------------------------------------------------------
_run_spawn() {
    run bash "$STUB_SCRIPTS/cld-spawn" "$@"
    LAUNCHER_CONTENT=""
    if [[ -f "$LAUNCHER_PATH" ]]; then
        LAUNCHER_CONTENT="$(cat "$LAUNCHER_PATH")"
    fi
}

# ---------------------------------------------------------------------------
# Scenario 1: --env-file で env file を指定して起動
# WHEN: cld-spawn --env-file ~/.secrets を実行する
# THEN: 生成された LAUNCHER スクリプトに source 行と 2>/dev/null || true が含まれる
# ---------------------------------------------------------------------------
@test "env-file: --env-file ~/.secrets で LAUNCHER に source 行が含まれる" {
    _run_spawn --env-file ~/.secrets
    [[ "$status" -eq 0 ]]
    [[ -n "$LAUNCHER_CONTENT" ]]
    # source または . コマンドで .secrets が指定されている
    [[ "$LAUNCHER_CONTENT" =~ (source|[[:space:]]\.).*\.secrets ]]
    # ファイルが存在しない場合も継続するため || true が付いている
    [[ "$LAUNCHER_CONTENT" == *"2>/dev/null || true"* ]]
}

# ---------------------------------------------------------------------------
# Scenario 2: --env-file にチルダパスを指定
# WHEN: cld-spawn --env-file ~/path/to/secrets のように ~ を含むパスを指定する
# THEN: ~ が $HOME に展開され、正しいパスが参照される
# ---------------------------------------------------------------------------
@test "env-file: チルダパスが \$HOME に展開される" {
    _run_spawn --env-file ~/path/to/secrets
    [[ "$status" -eq 0 ]]
    [[ -n "$LAUNCHER_CONTENT" ]]
    # チルダが ~ のまま残らず $HOME の実パスが使われている
    [[ "$LAUNCHER_CONTENT" != *"~/path/to/secrets"* ]]
    # 展開後のパスが含まれている
    [[ "$LAUNCHER_CONTENT" == *"${HOME}/path/to/secrets"* ]] || \
        [[ "$LAUNCHER_CONTENT" == *"path/to/secrets"* ]]
}

# ---------------------------------------------------------------------------
# Scenario 3: env file が存在しない場合
# WHEN: 指定した --env-file のパスにファイルが存在しない
# THEN: エラーを発生させず、既存の起動フローが継続される（2>/dev/null || true）
# ---------------------------------------------------------------------------
@test "env-file: env file が存在しなくても LAUNCHER 生成が正常終了する" {
    local nonexistent_path="$SANDBOX/nonexistent-secrets"
    # ファイルが存在しないことを確認
    [[ ! -f "$nonexistent_path" ]]
    _run_spawn --env-file "$nonexistent_path"
    # exit 0 で正常終了する（存在チェックでエラーにならない）
    [[ "$status" -eq 0 ]]
    [[ -n "$LAUNCHER_CONTENT" ]]
    # LAUNCHER に 2>/dev/null || true が含まれ、存在しないファイルでも安全に処理される
    [[ "$LAUNCHER_CONTENT" == *"2>/dev/null || true"* ]]
}

# ---------------------------------------------------------------------------
# Scenario 4: CLD_ENV_FILE 環境変数による自動ソース
# WHEN: CLD_ENV_FILE=~/.secrets が設定された状態で cld-spawn を実行する（--env-file 未指定）
# THEN: ~/.secrets が Worker セッションで自動ソースされる
# ---------------------------------------------------------------------------
@test "env-file: CLD_ENV_FILE 設定時に --env-file 未指定でも source 行が含まれる" {
    export CLD_ENV_FILE="${HOME}/.secrets"
    _run_spawn
    [[ "$status" -eq 0 ]]
    [[ -n "$LAUNCHER_CONTENT" ]]
    # CLD_ENV_FILE で指定したファイルの source 行が含まれる
    [[ "$LAUNCHER_CONTENT" =~ (source|[[:space:]]\.).*\.secrets ]]
    [[ "$LAUNCHER_CONTENT" == *"2>/dev/null || true"* ]]
    unset CLD_ENV_FILE
}

# ---------------------------------------------------------------------------
# Scenario 5: --env-file も CLD_ENV_FILE も未設定の場合
# WHEN: --env-file 引数も CLD_ENV_FILE 環境変数も未指定で cld-spawn を実行する
# THEN: ~/.cld-env をデフォルトとして LAUNCHER に source 行が追加される
# ---------------------------------------------------------------------------
@test "env-file: --env-file も CLD_ENV_FILE も未設定なら ~/.cld-env をデフォルトとして LAUNCHER に source 行が含まれる" {
    unset CLD_ENV_FILE 2>/dev/null || true
    _run_spawn
    [[ "$status" -eq 0 ]]
    [[ -n "$LAUNCHER_CONTENT" ]]
    # ~/.cld-env をデフォルトとして source 行が LAUNCHER に含まれる
    # （存在しない場合は 2>/dev/null で無視される）
    local env_source_lines
    env_source_lines=$(printf '%s\n' "$LAUNCHER_CONTENT" \
        | grep -E '^(source |[[:space:]]*\. )' \
        | grep -v '^#!/' \
        || true)
    [[ -n "$env_source_lines" ]]
    echo "$env_source_lines" | grep -q '\.cld-env'
}
