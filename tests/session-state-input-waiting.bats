#!/usr/bin/env bats
# session-state-input-waiting.bats - detect_state() input-waiting 判定テスト
# Issue #486: approval UI / AskUserQuestion パターンの input-waiting 検出
# tmux 依存なし（モックアプローチ）

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
SESSION_STATE_SCRIPT="$SCRIPT_DIR/session-state.sh"

setup() {
    TMPFILE="$(mktemp)"
}

teardown() {
    [[ -n "$TMPFILE" && -f "$TMPFILE" ]] && rm -f "$TMPFILE"
}

# ---------------------------------------------------------------------------
# ヘルパー: capture-pane 内容をモックして detect_state を実行
# ---------------------------------------------------------------------------
# tmux list-panes → claude プロセス模倣（has_claude=true パスを使用）
# tmux capture-pane → TMPFILE の内容を返す
run_detect_state_with_capture() {
    local capture_content="$1"
    printf '%s\n' "$capture_content" > "$TMPFILE"

    run bash <<EOF
tmux() {
    case "\$1" in
        list-panes)
            # pane_cmd=claude, pane_dead=0, pane_id=%0, pane_path=/home/test
            printf 'claude\t0\t%%0\t/home/test\n'
            ;;
        capture-pane)
            cat "$TMPFILE"
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux
source "$SESSION_STATE_SCRIPT"
detect_state 'test-session:0'
EOF
}

# ---------------------------------------------------------------------------
# Scenario: Claude Code 選択 UI (approval UI)
# Enter to select · ↑/↓ to navigate · Esc to cancel が末尾にある場合
# ---------------------------------------------------------------------------
@test "detect_state: Claude Code 選択 UI (Enter to select) → input-waiting" {
    run_detect_state_with_capture \
"❯ 1. 承認して実行
     Phase 1 を開始。3 Worker を並列起動し orchestrator に委譲
  2. キャンセル

Enter to select · ↑/↓ to navigate · Esc to cancel"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

@test "detect_state: approval UI の選択肢行 (❯) が tail-5 の中間にある → input-waiting" {
    run_detect_state_with_capture \
"❯ 1. 承認して実行
  2. キャンセル
Enter to select · ↑/↓ to navigate"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

# ---------------------------------------------------------------------------
# Scenario: 日本語 AskUserQuestion
# ---------------------------------------------------------------------------
@test "detect_state: 日本語 承認しますか prompt → input-waiting" {
    run_detect_state_with_capture \
"この操作を実行します。
承認しますか？ [y/N]"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

@test "detect_state: 日本語 確認しますか prompt → input-waiting" {
    run_detect_state_with_capture \
"変更を適用します。
確認しますか？"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

# ---------------------------------------------------------------------------
# Scenario: 英語 y/N / Do you want to
# ---------------------------------------------------------------------------
@test "detect_state: [y/N] prompt → input-waiting" {
    run_detect_state_with_capture \
"Do you want to proceed?
[y/N]"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

@test "detect_state: Do you want to prompt → input-waiting" {
    run_detect_state_with_capture \
"Do you want to apply these changes?"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

@test "detect_state: Waiting for user input → input-waiting" {
    run_detect_state_with_capture \
"Waiting for user input..."
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

# ---------------------------------------------------------------------------
# Scenario: 従来の ❯ 末尾パターン（既存挙動の維持）
# ---------------------------------------------------------------------------
@test "detect_state: 従来の ❯ 末尾プロンプト → input-waiting (後方互換)" {
    run_detect_state_with_capture \
"Completed previous task.
❯ "
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

# ---------------------------------------------------------------------------
# Scenario: processing 中（誤検知なし）
# ---------------------------------------------------------------------------
@test "detect_state: Thinking... のみ → processing (誤検知なし)" {
    run_detect_state_with_capture \
"Thinking...
⠋ Processing request"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

@test "detect_state: Working... のみ → processing" {
    run_detect_state_with_capture \
"Working on the task...
  Analyzing code"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

@test "detect_state: 空の出力 → processing" {
    run_detect_state_with_capture ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

# ---------------------------------------------------------------------------
# Scenario: [Y/n] バリアント
# ---------------------------------------------------------------------------
@test "detect_state: [Y/n] prompt → input-waiting" {
    run_detect_state_with_capture \
"Install the package? [Y/n]"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

# ---------------------------------------------------------------------------
# Issue #708: "esc to interrupt" / "bypass permissions" の誤検知・検出テスト
# ---------------------------------------------------------------------------
@test "detect_state: esc to interrupt のみ表示 → processing (false positive 再現)" {
    run_detect_state_with_capture \
"esc to interrupt"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

@test "detect_state: bypass permissions のみ表示 → input-waiting" {
    run_detect_state_with_capture \
"bypass permissions"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

@test "detect_state: esc to interrupt + Thinking 表示 → processing" {
    run_detect_state_with_capture \
"Thinking...
esc to interrupt"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

@test "detect_state: bypass permissions + esc to interrupt 同時表示 → input-waiting (bypass 優先)" {
    run_detect_state_with_capture \
"bypass permissions · esc to interrupt"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}
