#!/usr/bin/env bats
# cld-plugin-exclude.bats - cld の plugin 除外機構（CLD_PLUGIN_EXCLUDE / .cld-exclude）の unit tests
#
# Scenarios covered:
#   - 除外指定なし: 全 plugin が --plugin-dir で渡される（既存挙動の回帰）
#   - env CLD_PLUGIN_EXCLUDE（単一/カンマ区切り/空白区切り）で除外される
#   - $PLUGINS_BASE/.cld-exclude ファイル（1 行 1 名・# コメント・空行）で除外される
#   - env とファイルの合算 denylist
#   - 存在しない plugin 名を除外指定してもエラーにならない
#   - basename 完全一致（部分一致で別 plugin を巻き込まない）
#
# スタブ方針:
#   - claude stub が受け取った引数を 1 行 1 引数で出力する（--plugin-dir 検証用）
#   - systemd-run stub は自身のオプションを読み飛ばし 'claude' 以降を exec する
#     （実 systemd 不要・どちらの起動経路でも claude stub に到達する）
#   - HOME を SANDBOX 内に差し替え、fake plugin ディレクトリ群を配置する

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
CLD="$SCRIPT_DIR/cld"

setup() {
    SANDBOX="$(mktemp -d)"
    FAKE_BIN="$SANDBOX/bin"
    mkdir -p "$FAKE_BIN"

    # claude stub: 受け取った引数を 1 行 1 引数で出力（--plugin-dir 検証用）
    cat > "$FAKE_BIN/claude" <<'CLAUDE_STUB'
#!/bin/bash
printf '%s\n' "$@"
CLAUDE_STUB
    chmod +x "$FAKE_BIN/claude"

    # systemd-run stub: 自身のオプション（--user --scope -p ... --setenv=...）を読み飛ばし、
    # 最初の 'claude' トークン以降をそのまま exec する（決定論・実 systemd 不要）
    cat > "$FAKE_BIN/systemd-run" <<'SDRUN_STUB'
#!/bin/bash
while [[ $# -gt 0 && "$1" != claude ]]; do shift; done
exec "$@"
SDRUN_STUB
    chmod +x "$FAKE_BIN/systemd-run"

    # HOME 差し替え + fake plugins
    export HOME="$SANDBOX/home"
    PLUGINS="$HOME/.claude/plugins"
    for p in alpha alphabet folio; do
        mkdir -p "$PLUGINS/$p/.claude-plugin"
        echo '{}' > "$PLUGINS/$p/.claude-plugin/plugin.json"
    done
    # plugin.json を持たないディレクトリ（検出対象外の回帰確認用）
    mkdir -p "$PLUGINS/not-a-plugin"

    export PATH="$FAKE_BIN:$PATH"

    unset CLD_PLUGIN_EXCLUDE || true
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

# _run_cld: スタブ環境で cld を実行（claude stub が引数一覧を出力する）
_run_cld() {
    run bash "$CLD"
}

# _has_plugin <name>: 出力に該当 plugin の --plugin-dir パスが含まれるか
_has_plugin() {
    [[ "$output" == *"/.claude/plugins/$1/"* ]]
}

@test "exclude: 除外指定なしで全 plugin が渡される（回帰）" {
    _run_cld
    [ "$status" -eq 0 ]
    _has_plugin alpha
    _has_plugin alphabet
    _has_plugin folio
}

@test "exclude: plugin.json の無いディレクトリは検出されない（回帰）" {
    _run_cld
    [[ "$output" != *"not-a-plugin"* ]]
}

@test "exclude: CLD_PLUGIN_EXCLUDE=folio で folio のみ除外される" {
    CLD_PLUGIN_EXCLUDE=folio _run_cld
    [ "$status" -eq 0 ]
    _has_plugin alpha
    _has_plugin alphabet
    ! _has_plugin folio
}

@test "exclude: CLD_PLUGIN_EXCLUDE のカンマ区切りで複数除外される" {
    CLD_PLUGIN_EXCLUDE="folio,alpha" _run_cld
    [ "$status" -eq 0 ]
    ! _has_plugin folio
    _has_plugin alphabet
    [[ "$output" != *"/.claude/plugins/alpha/"* ]]
}

@test "exclude: CLD_PLUGIN_EXCLUDE の空白区切りで複数除外される" {
    CLD_PLUGIN_EXCLUDE="folio alpha" _run_cld
    [ "$status" -eq 0 ]
    ! _has_plugin folio
    [[ "$output" != *"/.claude/plugins/alpha/"* ]]
    _has_plugin alphabet
}

@test "exclude: 除外は basename 完全一致（alpha 除外で alphabet は残る）" {
    CLD_PLUGIN_EXCLUDE=alpha _run_cld
    [ "$status" -eq 0 ]
    [[ "$output" != *"/.claude/plugins/alpha/"* ]]
    _has_plugin alphabet
}

@test "exclude: .cld-exclude ファイル（コメント・空行込み）で除外される" {
    cat > "$HOME/.claude/plugins/.cld-exclude" <<'EOF'
# 重量 dev plugin は worker へ注入しない
folio

alpha  # 行末コメント
EOF
    _run_cld
    [ "$status" -eq 0 ]
    ! _has_plugin folio
    [[ "$output" != *"/.claude/plugins/alpha/"* ]]
    _has_plugin alphabet
}

@test "exclude: env と .cld-exclude の合算 denylist になる" {
    echo "folio" > "$HOME/.claude/plugins/.cld-exclude"
    CLD_PLUGIN_EXCLUDE=alpha _run_cld
    [ "$status" -eq 0 ]
    ! _has_plugin folio
    [[ "$output" != *"/.claude/plugins/alpha/"* ]]
    _has_plugin alphabet
}

@test "exclude: 存在しない plugin 名の除外指定はエラーにならない" {
    CLD_PLUGIN_EXCLUDE=nonexistent _run_cld
    [ "$status" -eq 0 ]
    _has_plugin alpha
    _has_plugin alphabet
    _has_plugin folio
}

@test "exclude: 空の .cld-exclude ファイルは無害（全 plugin 残る）" {
    : > "$HOME/.claude/plugins/.cld-exclude"
    _run_cld
    [ "$status" -eq 0 ]
    _has_plugin alpha
    _has_plugin alphabet
    _has_plugin folio
}

@test "exclude: glob 文字入りの env 値が cwd のファイル名へ展開されない（review 反映）" {
    # cwd に plugin 名と同名のファイルを置き、'*' が pathname 展開されないことを確認
    WORKDIR="$SANDBOX/work"
    mkdir -p "$WORKDIR"
    touch "$WORKDIR/alpha"
    cd "$WORKDIR"
    CLD_PLUGIN_EXCLUDE='*' _run_cld
    [ "$status" -eq 0 ]
    # '*' はリテラル扱い＝どの plugin にも一致しない（alpha が cwd 展開で除外されないこと）
    _has_plugin alpha
    _has_plugin alphabet
    _has_plugin folio
}

@test "exclude: 読取り不可の .cld-exclude で launcher が abort しない（review 反映）" {
    echo "folio" > "$HOME/.claude/plugins/.cld-exclude"
    chmod 000 "$HOME/.claude/plugins/.cld-exclude"
    _run_cld
    [ "$status" -eq 0 ]
    # 除外は無効（読めないため）だが claude は起動し、警告が出る
    _has_plugin folio
    [[ "$output" == *"plugin 除外は無効"* ]]
    chmod 644 "$HOME/.claude/plugins/.cld-exclude"
}

@test "exclude: .cld-exclude がディレクトリでも launcher が abort しない（round-2 反映）" {
    rm -f "$HOME/.claude/plugins/.cld-exclude"
    mkdir -p "$HOME/.claude/plugins/.cld-exclude"
    _run_cld
    [ "$status" -eq 0 ]
    _has_plugin alpha
    _has_plugin folio
    [[ "$output" == *"正規ファイルでない"* ]]
}

@test "exclude: .cld-exclude が FIFO でも launcher が hang/abort しない（round-2 反映）" {
    rm -rf "$HOME/.claude/plugins/.cld-exclude"
    mkfifo "$HOME/.claude/plugins/.cld-exclude"
    # FIFO を read すると writer 待ちで hang するため、timeout で hang しないことも保証する
    run timeout 5 bash "$CLD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/.claude/plugins/folio/"* ]]
    [[ "$output" == *"正規ファイルでない"* ]]
}
