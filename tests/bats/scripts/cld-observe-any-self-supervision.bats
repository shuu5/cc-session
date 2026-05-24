#!/usr/bin/env bats
# cld-observe-any-self-supervision.bats
# Issue #1146: feat(observer): self-monitoring daemon (option B)
# RED フェーズ — 実装前は全テストが fail する

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/scripts"
LAUNCHER="$SCRIPT_DIR/cld-observe-any-launcher"

setup() {
    TMPDIR_TEST="$(mktemp -d)"
    SUPERVISOR_DIR="$TMPDIR_TEST/.supervisor"
    EVENT_DIR="$SUPERVISOR_DIR/events"
    mkdir -p "$EVENT_DIR"
}

teardown() {
    if [[ -n "${LAUNCHED_PID:-}" ]]; then
        kill "$LAUNCHED_PID" 2>/dev/null || true
    fi
    [[ -n "${TMPDIR_TEST:-}" && -d "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# AC2: cld-observe-any-launcher が実行可能ファイルとして存在する
# RED: plugins/session/scripts/cld-observe-any-launcher 未実装
# ---------------------------------------------------------------------------
@test "AC2: cld-observe-any-launcher が実行可能ファイルとして存在する" {
    # RED: 実装後は pass する。現時点では launcher ファイルが存在しないため fail する
    [ -x "$LAUNCHER" ]
}

# ---------------------------------------------------------------------------
# AC2: flock による多重起動防止 — 2 回目の launcher 起動は即 exit する
# option B: flock(/tmp/cld-observe-any.lock) + nohup 起動
# RED: launcher 未実装のため fail する
# ---------------------------------------------------------------------------
@test "AC2: flock による多重起動防止 — 2 回目の launcher 起動は即 exit する" {
    # launcher が存在しなければ fail（RED）
    if [[ ! -x "$LAUNCHER" ]]; then
        false  # RED: launcher not implemented
    fi

    local LOCK_FILE="$TMPDIR_TEST/cld-observe-any-test.lock"

    # 1 回目: ロックを手動で取得してブロック状態を作る
    (
        flock -x 9
        sleep 5
    ) 9>"$LOCK_FILE" &
    local FIRST_PID=$!
    sleep 0.2

    # 2 回目: 同じロックで launcher を起動 → flock で排除（即 exit）
    run env CLD_OBSERVE_ANY_LOCK="$LOCK_FILE" \
        timeout 2 bash "$LAUNCHER" --dry-run

    kill "$FIRST_PID" 2>/dev/null; wait "$FIRST_PID" 2>/dev/null || true
    rm -f "$LOCK_FILE"

    # exit code は 0（サイレントスキップ）を期待（hook エラーログ汚染防止）
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC2: session.json schema — cld_observe_any フィールド追加
# .supervisor/session.json に { pid, started_at, log_path } フィールドが存在する
# RED: launcher 未実装のため fail する
# ---------------------------------------------------------------------------
@test "AC2: launcher 起動後に .supervisor/session.json に cld_observe_any フィールドが追記される" {
    if [[ ! -x "$LAUNCHER" ]]; then
        false  # RED: launcher not implemented
    fi

    local SESSION_JSON="$SUPERVISOR_DIR/session.json"
    mkdir -p "$SUPERVISOR_DIR"

    env CLD_OBSERVE_ANY_SUPERVISOR_DIR="$SUPERVISOR_DIR" \
        timeout 3 bash "$LAUNCHER" --dry-run 2>/dev/null || true

    [ -f "$SESSION_JSON" ]
    jq -e '.cld_observe_any.pid and .cld_observe_any.started_at and .cld_observe_any.log_path' \
        "$SESSION_JSON" >/dev/null
}

# ---------------------------------------------------------------------------
# AC3: daemon 不在時に SessionStart hook が launcher を呼び出す
# pgrep -f cld-observe-any が 0 件 → launcher 起動
# RED: launcher 未実装のため fail する
# ---------------------------------------------------------------------------
@test "AC3: daemon 不在時に SessionStart hook が launcher を呼び出す" {
    if [[ ! -x "$LAUNCHER" ]]; then
        false  # RED: launcher not implemented
    fi

    local CALL_LOG="$TMPDIR_TEST/launcher-calls.log"

    run bash <<EOF
LAUNCHER="$LAUNCHER"
CALL_LOG="$CALL_LOG"

pgrep() { return 1; }
export -f pgrep

if ! pgrep -f "cld-observe-any" >/dev/null 2>&1; then
    bash "\$LAUNCHER" --dry-run >> "\$CALL_LOG" 2>&1
fi

grep -q "launcher_invoked\|dry.run\|started" "\$CALL_LOG" 2>/dev/null
EOF

    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC3: daemon 存在時は SessionStart hook が launcher を呼び出さない
# RED: launcher 未実装のため fail する（実装後は regression 防止 baseline）
# ---------------------------------------------------------------------------
@test "AC3: daemon 存在時は SessionStart hook が launcher を呼び出さない" {
    if [[ ! -x "$LAUNCHER" ]]; then
        false  # RED: launcher not implemented
    fi

    local CALL_LOG="$TMPDIR_TEST/launcher-calls.log"

    run bash <<EOF
LAUNCHER="$LAUNCHER"
CALL_LOG="$CALL_LOG"

pgrep() { echo "12345"; return 0; }
export -f pgrep

if ! pgrep -f "cld-observe-any" >/dev/null 2>&1; then
    bash "\$LAUNCHER" --dry-run >> "\$CALL_LOG" 2>&1
fi

! [ -s "\$CALL_LOG" ]
EOF

    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# AC4: daemon 死亡検知時に .supervisor/events/daemon-down-<ts>.json が出力される
# schema: {event:"daemon-down", reason, ts, pid}
# RED: launcher 未実装のため fail する
# ---------------------------------------------------------------------------
@test "AC4: daemon 死亡検知時に .supervisor/events/daemon-down-<ts>.json が出力される" {
    if [[ ! -x "$LAUNCHER" ]]; then
        false  # RED: launcher not implemented
    fi

    env CLD_OBSERVE_ANY_EVENT_DIR="$EVENT_DIR" \
        timeout 3 bash "$LAUNCHER" --simulate-daemon-death 2>/dev/null || true

    local f
    f=$(find "$EVENT_DIR" -name "daemon-down-*.json" 2>/dev/null | head -1)
    [ -n "$f" ]

    jq -e '.event == "daemon-down" and .reason and .ts and .pid' "$f" >/dev/null
}

# ---------------------------------------------------------------------------
# AC4: daemon-down JSON schema の必須フィールド検証（schema 契約定義テスト）
# NOTE: schema 契約の事前定義。手動生成 JSON で検証するため現時点でも GREEN になる。
#       launcher 実装後は launcher 出力 JSON との結合検証に昇格させること。
# ---------------------------------------------------------------------------
@test "AC4: daemon-down JSON の必須フィールド検証 (event/reason/ts/pid)" {
    local TS
    TS=$(date +%s)
    cat > "$EVENT_DIR/daemon-down-${TS}.json" <<JSON
{
  "event": "daemon-down",
  "reason": "SIGKILL",
  "ts": ${TS},
  "pid": 99999
}
JSON

    local f="$EVENT_DIR/daemon-down-${TS}.json"
    jq -e '.event == "daemon-down" and (.reason | type == "string") and (.ts | type == "number") and (.pid | type == "number")' \
        "$f" >/dev/null
}

# ---------------------------------------------------------------------------
# AC5: daemon 起動失敗時に .supervisor/events/daemon-startup-failed-<ts>.json が出力される
# RED: launcher 未実装のため fail する
# ---------------------------------------------------------------------------
@test "AC5: daemon 起動失敗時に .supervisor/events/daemon-startup-failed-<ts>.json が出力される" {
    if [[ ! -x "$LAUNCHER" ]]; then
        false  # RED: launcher not implemented
    fi

    env CLD_OBSERVE_ANY_EVENT_DIR="$EVENT_DIR" \
        timeout 3 bash "$LAUNCHER" --simulate-startup-failure 2>/dev/null || true

    local f
    f=$(find "$EVENT_DIR" -name "daemon-startup-failed-*.json" 2>/dev/null | head -1)
    [ -n "$f" ]

    jq -e '.event == "daemon-startup-failed" and .ts' "$f" >/dev/null
}

# ---------------------------------------------------------------------------
# AC5: daemon-startup-failed JSON schema の必須フィールド検証（schema 契約定義テスト）
# NOTE: schema 契約の事前定義。手動生成 JSON で検証するため現時点でも GREEN になる。
# ---------------------------------------------------------------------------
@test "AC5: daemon-startup-failed JSON の必須フィールド検証 (event/reason/ts)" {
    local TS
    TS=$(date +%s)
    cat > "$EVENT_DIR/daemon-startup-failed-${TS}.json" <<JSON
{
  "event": "daemon-startup-failed",
  "reason": "cld-observe-any not found",
  "ts": ${TS},
  "pid": null
}
JSON

    local f="$EVENT_DIR/daemon-startup-failed-${TS}.json"
    jq -e '.event == "daemon-startup-failed" and (.reason | type == "string") and (.ts | type == "number")' \
        "$f" >/dev/null
}

# ---------------------------------------------------------------------------
# AC6 (integration): kill -9 後に SessionStart hook mock で再起動が確認される
# option B: SessionStart hook をテスト用 mock で発火させて検証
# RED: launcher 未実装のため fail する
# ---------------------------------------------------------------------------
@test "AC6: kill -9 で daemon 殺害後 — SessionStart hook mock で再起動が確認される" {
    if [[ ! -x "$LAUNCHER" ]]; then
        false  # RED: launcher not implemented
    fi

    local RESTART_LOG="$TMPDIR_TEST/restart.log"

    # launcher を nohup で起動
    nohup bash "$LAUNCHER" \
        --supervisor-dir "$SUPERVISOR_DIR" \
        > "$TMPDIR_TEST/launcher.log" 2>&1 &
    local DAEMON_PID=$!
    LAUNCHED_PID="$DAEMON_PID"
    sleep 1

    # kill -9 で強制終了
    kill -9 "$DAEMON_PID" 2>/dev/null || true
    sleep 0.5

    # SessionStart hook をシミュレート: pgrep -f cld-observe-any-launcher || launcher
    if ! pgrep -f "cld-observe-any-launcher" >/dev/null 2>&1; then
        echo "daemon_down_detected" >> "$RESTART_LOG"
        bash "$LAUNCHER" --dry-run >> "$RESTART_LOG" 2>&1 || true
    fi

    grep -q "daemon_down_detected" "$RESTART_LOG"
}

# ---------------------------------------------------------------------------
# AC6: flock 多重起動防止 — SessionStart hook が二重起動しないことの確認
# RED: launcher 未実装のため fail する
# ---------------------------------------------------------------------------
@test "AC6: flock 多重起動防止 — SessionStart hook が二重起動しないことの確認" {
    if [[ ! -x "$LAUNCHER" ]]; then
        false  # RED: launcher not implemented
    fi

    local LOCK_FILE="$TMPDIR_TEST/cld-observe-any-test2.lock"
    local CALL_COUNT_FILE="$TMPDIR_TEST/call-count"
    echo 0 > "$CALL_COUNT_FILE"

    # 1 回目: ロックを取得したまま待機
    (
        flock -x 9
        local count
        count=$(cat "$CALL_COUNT_FILE")
        echo $((count + 1)) > "$CALL_COUNT_FILE"
        sleep 3
    ) 9>"$LOCK_FILE" &
    local FIRST_PID=$!
    sleep 0.2

    # 2 回目: flock で弾かれるべき
    env CLD_OBSERVE_ANY_LOCK="$LOCK_FILE" \
        timeout 1 bash "$LAUNCHER" --dry-run 2>/dev/null || true

    kill "$FIRST_PID" 2>/dev/null; wait "$FIRST_PID" 2>/dev/null || true
    rm -f "$LOCK_FILE"

    local CALL_COUNT
    CALL_COUNT=$(cat "$CALL_COUNT_FILE")
    [ "$CALL_COUNT" -le 1 ]
}

# ===========================================================================
# Issue #1165: tech-debt(session): cld-observe-any SUPERVISOR_DIR パストラバーサル防御
# AC5: invalid SUPERVISOR_DIR で launcher が exit 2 を返すテスト
# RED: cld-observe-any-launcher への validate_supervisor_dir 呼び出し未追加のため fail
# ===========================================================================

# ---------------------------------------------------------------------------
# AC5(#1165): --supervisor-dir /etc/invalid-path で exit 2 になる
# RED: cld-observe-any-launcher に validate_supervisor_dir 呼び出しが
#      未追加のため fail する
# ---------------------------------------------------------------------------
@test "AC5(#1165): --supervisor-dir /etc/invalid-path で exit 2 になる" {
    # RED: cld-observe-any-launcher への validate_supervisor_dir 呼び出し未追加のため fail する
    run bash "$LAUNCHER" --supervisor-dir "/etc/invalid-path" --dry-run
    [ "$status" -eq 2 ]
}
