#!/usr/bin/env bats
# lib-tmux-resolve.bats — plugins/session/scripts/lib/tmux-resolve.sh のテスト
# Issue #1142: AC-4（RED テスト生成）/ Issue #1218: AC-4-3b（uniqueness）+ GREEN 化
#
# 設計:
#   - lib/tmux-resolve.sh が存在しない状態では source に失敗し、全テストが fail する（RED フェーズ）
#   - 実装後 GREEN になる
#   - tmux は shell function override によりモック（既存 cld-observe-any.bats 慣習に従う）
#
# tmux-resolve.sh が実装すべきインターフェース:
#   _resolve_window_target <window_name>
#     stdout: "session:index"（例: "main:3"）
#     exit 0: 一意に解決
#     exit 1: 不在（stderr: "window not found: <window_name>"）
#     exit 1: 複数一致（stderr: "ambiguous: multiple sessions have window <window_name>"）
#
#   _kill_window_safe <window_name>
#     exit 0: _resolve 成功 → tmux kill-window -t <target> を実行
#     exit 1: _resolve 失敗 → kill は呼ばない + stderr に理由をログ

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
LIB_PATH="$SCRIPT_DIR/lib/tmux-resolve.sh"

# ---------------------------------------------------------------------------
# AC-4-1: 正常解決
#   tmux mock が `main:3 wt-target` を返す
#   → _resolve_window_target wt-target の stdout が `main:3`、exit 0
# ---------------------------------------------------------------------------
@test "AC4-1: 正常解決 — tmux mock が main:3 wt-target 返却 → stdout main:3 + exit 0" {
    # RED: lib/tmux-resolve.sh が存在しないため source 失敗で fail する
    run bash <<EOF
tmux() {
    case "\$1" in
        list-windows)
            printf 'main:3 wt-target\n'
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux

source "$LIB_PATH"
_resolve_window_target "wt-target"
EOF

    [[ "$status" -eq 0 ]]
    [[ "$output" == "main:3" ]]
}

# ---------------------------------------------------------------------------
# AC-4-2: 不在ケース
#   tmux mock が空文字を返す
#   → exit 1 + stderr に "window not found: wt-target"
# ---------------------------------------------------------------------------
@test "AC4-2: 不在 — tmux mock が空文字返却 → exit 1 + stderr に 'window not found: wt-target'" {
    # RED: lib/tmux-resolve.sh が存在しないため source 失敗で fail する
    STDERR_FILE="$(mktemp)"
    run bash <<EOF
exec 2>"$STDERR_FILE"
tmux() {
    case "\$1" in
        list-windows)
            printf ''
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux

source "$LIB_PATH"
_resolve_window_target "wt-target"
EOF

    stderr_content=$(cat "$STDERR_FILE")
    rm -f "$STDERR_FILE"

    [[ "$status" -eq 1 ]]
    echo "$stderr_content" | grep -q "window not found: wt-target"
}

# ---------------------------------------------------------------------------
# AC-4-3: ambiguous ケース
#   tmux mock が `s1:0 wt-target` と `s2:0 wt-target` の 2 行を返す
#   → exit 1（最初の match を返す貪欲挙動は禁止）
#   → stderr に "ambiguous: multiple sessions have window wt-target"
# ---------------------------------------------------------------------------
@test "AC4-3: ambiguous — 複数セッションに同名 window → exit 1 + stderr 'ambiguous'" {
    # RED: lib/tmux-resolve.sh が存在しないため source 失敗で fail する
    STDERR_FILE="$(mktemp)"
    run bash <<EOF
exec 2>"$STDERR_FILE"
tmux() {
    case "\$1" in
        list-windows)
            printf 's1:0 wt-target\ns2:0 wt-target\n'
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux

source "$LIB_PATH"
_resolve_window_target "wt-target"
EOF

    stderr_content=$(cat "$STDERR_FILE")
    rm -f "$STDERR_FILE"

    [[ "$status" -eq 1 ]]
    echo "$stderr_content" | grep -q "ambiguous: multiple sessions have window wt-target"
}

# ---------------------------------------------------------------------------
# AC-4-4a: kill_window_safe 正常系
#   _resolve_window_target が成功 → kill-window stub が 1 回だけ呼ばれる
# ---------------------------------------------------------------------------
@test "AC4-4a: kill_window_safe 正常 — _resolve 成功 → kill-window が 1 回呼出される" {
    # RED: lib/tmux-resolve.sh が存在しないため source 失敗で fail する
    KILL_COUNT_FILE="$(mktemp)"
    echo 0 > "$KILL_COUNT_FILE"

    run bash <<EOF
KILL_COUNT_FILE="$KILL_COUNT_FILE"

tmux() {
    case "\$1" in
        list-windows)
            printf 'main:3 wt-target\n'
            return 0
            ;;
        kill-window)
            count=\$(cat "\$KILL_COUNT_FILE")
            echo \$((count + 1)) > "\$KILL_COUNT_FILE"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux

source "$LIB_PATH"
_kill_window_safe "wt-target"
EOF

    kill_count=$(cat "$KILL_COUNT_FILE")
    rm -f "$KILL_COUNT_FILE"

    [[ "$status" -eq 0 ]]
    [[ "$kill_count" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# AC-4-4b: kill_window_safe 不在系
#   _resolve_window_target が失敗（空） → kill-window は 0 回 + stderr に log
# ---------------------------------------------------------------------------
@test "AC4-4b: kill_window_safe 不在 — _resolve 失敗 → kill stub 0 回 + stderr に log" {
    # RED: lib/tmux-resolve.sh が存在しないため source 失敗で fail する
    KILL_COUNT_FILE="$(mktemp)"
    echo 0 > "$KILL_COUNT_FILE"
    STDERR_FILE="$(mktemp)"

    run bash <<EOF
exec 2>"$STDERR_FILE"
KILL_COUNT_FILE="$KILL_COUNT_FILE"

tmux() {
    case "\$1" in
        list-windows)
            printf ''
            return 0
            ;;
        kill-window)
            count=\$(cat "\$KILL_COUNT_FILE")
            echo \$((count + 1)) > "\$KILL_COUNT_FILE"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux

source "$LIB_PATH"
_kill_window_safe "wt-target"
EOF

    kill_count=$(cat "$KILL_COUNT_FILE")
    stderr_content=$(cat "$STDERR_FILE")
    rm -f "$KILL_COUNT_FILE" "$STDERR_FILE"

    # 実装後の期待:
    #   exit 1（Issue AC-2: _resolve_window_target の exit code を伝播。not-found → exit 1）
    #   kill_count == 0
    #   stderr_content に "wt-target" を含む log
    # RED フェーズ（lib 未実装）では source 失敗で status が非 0 になる
    [[ "$status" -eq 1 ]]
    [[ "$kill_count" -eq 0 ]]
    echo "$stderr_content" | grep -q "wt-target"
}

# ---------------------------------------------------------------------------
# AC-4-3b: same-session uniqueness edge case（AC6）
#   同一 session 内に同名 window が複数存在する場合も fail-loud する
#   tmux list-windows -a で `main:0 wt-target\nmain:1 wt-target` を返す mock
#   → exit 1 + stderr に "ambiguous" または unique 保証違反を示すメッセージ
#
#   AC4-3（複数 session 同名）との違い:
#     AC4-3 では "s1:0 wt-target\ns2:0 wt-target"（異なる session）
#     AC4-3b では "main:0 wt-target\nmain:1 wt-target"（同一 session 内）
# ---------------------------------------------------------------------------
@test "AC4-3b: same-session uniqueness — 同一 session 内に同名 window が複数 → exit 1 + stderr に uniqueness 違反 (AC6)" {
    # RED: lib/tmux-resolve.sh が存在しないため source 失敗で fail する
    # 実装後: 同一 session 内の同名 window も ambiguous として fail-loud する
    STDERR_FILE="$(mktemp)"
    run bash <<EOF
exec 2>"$STDERR_FILE"
tmux() {
    case "\$1" in
        list-windows)
            # 同一 session "main" に index 0 と index 1 で同名 window が存在
            printf 'main:0 wt-target\nmain:1 wt-target\n'
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux

source "$LIB_PATH"
_resolve_window_target "wt-target"
EOF

    stderr_content=$(cat "$STDERR_FILE")
    rm -f "$STDERR_FILE"

    # 期待: exit 1（unique 保証違反 → fail-loud）
    [[ "$status" -eq 1 ]]
    # stderr に ambiguous または uniqueness 違反を示すメッセージが含まれること
    # （"ambiguous: multiple" または同等のエラーメッセージ）
    echo "$stderr_content" | grep -qiE "ambiguous|multiple|unique|duplicate"
}
