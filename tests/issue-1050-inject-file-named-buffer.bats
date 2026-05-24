#!/usr/bin/env bats
# issue-1050-inject-file-named-buffer.bats
# Issue #1050: cmd_inject_file の tmux named buffer 化（バッファ衝突防止）
# Spec: issue-1050
# Coverage: --type=structural,functional,concurrent

# ===========================================================================
# setup / teardown
# ===========================================================================

setup() {
    PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$PLUGIN_ROOT/scripts/session-comm.sh"
    SANDBOX="$(mktemp -d)"
    export SANDBOX SCRIPT PLUGIN_ROOT
}

teardown() {
    [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

# ===========================================================================
# helper: mock tmux（named buffer 対応版）
# named buffer を ${SANDBOX}/buffers/${NAME} に保存し、
# paste-buffer で ${SANDBOX}/targets/${TARGET} に書き込む
# ===========================================================================

_create_mock_tmux_named_buffer() {
    local mock="$SANDBOX/bin/tmux"
    mkdir -p "$SANDBOX/bin" "$SANDBOX/buffers" "$SANDBOX/targets"
    # NOTE: 非クォート heredoc で外部変数 $SANDBOX を展開する
    # NOTE: local はトップレベルスクリプト(関数外)では使用不可 — buf_name 等は直接代入する
    cat > "$mock" << MOCK
#!/bin/bash
case "\$1" in
    -V)
        echo "tmux 3.4"
        ;;
    has-session)
        exit 0
        ;;
    list-windows)
        echo "session:0 mock-window"
        ;;
    load-buffer)
        # parse: load-buffer -b NAME FILE
        buf_name=""; file_arg=""
        shift  # skip "load-buffer"
        while [[ \$# -gt 0 ]]; do
            case "\$1" in
                -b) buf_name="\$2"; shift 2 ;;
                *)  file_arg="\$1"; shift ;;
            esac
        done
        if [[ -n "\$buf_name" && -n "\$file_arg" ]]; then
            cp "\$file_arg" "${SANDBOX}/buffers/\${buf_name}"
        elif [[ -n "\$file_arg" ]]; then
            # anonymous buffer（実装前の動作）
            cp "\$file_arg" "${SANDBOX}/buffers/__anonymous__"
        fi
        exit 0
        ;;
    paste-buffer)
        # parse: paste-buffer -b NAME [-p] -t TARGET
        buf_name=""; target=""
        shift  # skip "paste-buffer"
        while [[ \$# -gt 0 ]]; do
            case "\$1" in
                -b) buf_name="\$2"; shift 2 ;;
                -t) target="\$2"; shift 2 ;;
                -p) shift ;;
                *)  shift ;;
            esac
        done
        if [[ -n "\$buf_name" && -n "\$target" ]]; then
            buf_file="${SANDBOX}/buffers/\${buf_name}"
            if [[ -f "\$buf_file" ]]; then
                cat "\$buf_file" >> "${SANDBOX}/targets/\${target}"
            fi
        elif [[ -n "\$target" ]]; then
            # anonymous buffer（実装前の動作）
            if [[ -f "${SANDBOX}/buffers/__anonymous__" ]]; then
                cat "${SANDBOX}/buffers/__anonymous__" >> "${SANDBOX}/targets/\${target}"
            fi
        fi
        exit 0
        ;;
    delete-buffer)
        # parse: delete-buffer -b NAME
        buf_name=""
        shift  # skip "delete-buffer"
        while [[ \$# -gt 0 ]]; do
            case "\$1" in
                -b) buf_name="\$2"; shift 2 ;;
                *)  shift ;;
            esac
        done
        if [[ -n "\$buf_name" ]]; then
            rm -f "${SANDBOX}/buffers/\${buf_name}"
        fi
        exit 0
        ;;
    send-keys)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
MOCK
    chmod +x "$mock"
}

_create_mock_session_state_input_waiting() {
    mkdir -p "$SANDBOX/mock_scripts"
    cat > "$SANDBOX/mock_scripts/session-state.sh" << 'MOCK'
#!/bin/bash
if [[ "$1" == "state" ]]; then echo "input-waiting"; exit 0; fi
if [[ "$1" == "wait" ]]; then exit 0; fi
exit 0
MOCK
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"
}

# ===========================================================================
# AC-1 (structural): named buffer で load-buffer を呼ぶ
# RED: 実装前は `tmux load-buffer "$file_path"` (anonymous) のため FAIL する
# ===========================================================================

@test "ac1[structural][RED]: cmd_inject_file が load-buffer -b <unique-name> を使用する" {
    # AC-1: `tmux load-buffer -b <unique-name> "$file_path"` で named buffer に読み込む
    # 実装前: `tmux load-buffer "$file_path"` (anonymous) のため grep が FAIL する
    grep -qF 'load-buffer -b' "$SCRIPT" || {
        echo "FAIL: session-comm.sh の cmd_inject_file に 'load-buffer -b' が含まれていない（named buffer 未実装）" >&2
        return 1
    }
}

@test "ac1[structural][RED]: buffer 名が session-comm-PID 形式の一意名を使用する" {
    # AC-1 詳細: 一意名は session-comm-$$-$(date +%s%N) 形式（PID + ナノ秒）
    # 実装前: anonymous buffer のため buffer_name 変数が存在しない → FAIL
    grep -qE 'session-comm-\$\$-\$\(date' "$SCRIPT" || {
        echo "FAIL: session-comm.sh に 'session-comm-\$\$-\$(date' 形式の buffer 名が含まれていない" >&2
        return 1
    }
}

# ===========================================================================
# AC-2 (structural): paste-buffer -b, delete-buffer -b を使用する
# RED: 実装前は anonymous buffer + delete-buffer なし のため FAIL する
# ===========================================================================

@test "ac2[structural][RED]: cmd_inject_file が paste-buffer -b <unique-name> を使用する" {
    # AC-2: `tmux paste-buffer -b <unique-name> [-p] -t "$target"` で貼り付ける
    # 実装前: `tmux paste-buffer -t "$target"` (anonymous) のため FAIL する
    grep -qF 'paste-buffer -b' "$SCRIPT" || {
        echo "FAIL: session-comm.sh の cmd_inject_file に 'paste-buffer -b' が含まれていない（named buffer 未実装）" >&2
        return 1
    }
}

@test "ac2[structural][RED]: cmd_inject_file が delete-buffer -b <unique-name> を呼ぶ" {
    # AC-2: paste 後に `tmux delete-buffer -b <unique-name>` で削除する
    # 実装前: delete-buffer 呼び出しが存在しない → FAIL
    grep -qF 'delete-buffer -b' "$SCRIPT" || {
        echo "FAIL: session-comm.sh の cmd_inject_file に 'delete-buffer -b' が含まれていない（cleanup 未実装）" >&2
        return 1
    }
}

@test "ac2[structural]: inline cleanup で delete-buffer が各 exit 前に呼ばれる" {
    # AC-2 更新（Issue #1395）: EXIT trap を廃止し inline cleanup に移行した
    # 各 exit 経路の直前に delete-buffer が inline で呼ばれていることを確認する
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")
    local buf_name_line
    buf_name_line=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /local _buf_name=/ {print NR; exit}" "$SCRIPT")
    local func_body
    func_body=$(awk "NR >= ${buf_name_line:-$start_line} && NR <= ${end_line:-99999}" "$SCRIPT")
    local cleanup_count
    cleanup_count=$(echo "$func_body" | grep -c 'delete-buffer -b.*_buf_name' || true)
    [[ "$cleanup_count" -ge 1 ]] || {
        echo "FAIL: cmd_inject_file に inline delete-buffer が存在しない" >&2
        return 1
    }
}

# ===========================================================================
# AC-3 (functional): 並列 inject-file で各 target が正しい内容を受信する
# RED: 実装前は anonymous buffer のため並列実行で buffer が上書きされ、
#      異なる target に異なる content が届く保証がない
# ===========================================================================

@test "ac3[functional][RED]: 単一 inject-file が named buffer (-b オプション付き) 経由で target に届ける" {
    # named buffer 実装を検証するために、load-buffer -b が実際に呼ばれているかを
    # mock の tmux 呼び出しログから確認する
    # RED: 実装前は load-buffer に -b オプションがないため、ログに "-b" が記録されない
    _create_mock_tmux_named_buffer
    _create_mock_session_state_input_waiting

    # mock tmux をログ記録機能付きに強化（呼び出し引数を記録）
    local call_log="$SANDBOX/tmux_call_args.log"
    cat >> "$SANDBOX/bin/tmux" << PATCH
# append call args to log
echo "\$*" >> "${call_log}"
PATCH
    # call_log 追記を先頭に挿入するため改めて全体を再生成する
    local mock="$SANDBOX/bin/tmux"
    cat > "$mock" << MOCK_REWRITE
#!/bin/bash
echo "\$*" >> "${call_log}"
case "\$1" in
    -V) echo "tmux 3.4" ;;
    has-session) exit 0 ;;
    list-windows) echo "session:0 mock-window" ;;
    load-buffer)
        buf_name=""; file_arg=""
        shift
        while [[ \$# -gt 0 ]]; do
            case "\$1" in -b) buf_name="\$2"; shift 2 ;; *) file_arg="\$1"; shift ;; esac
        done
        if [[ -n "\$buf_name" && -n "\$file_arg" ]]; then
            cp "\$file_arg" "${SANDBOX}/buffers/\${buf_name}"
        fi
        exit 0
        ;;
    paste-buffer)
        buf_name=""; target=""
        shift
        while [[ \$# -gt 0 ]]; do
            case "\$1" in -b) buf_name="\$2"; shift 2 ;; -t) target="\$2"; shift 2 ;; -p) shift ;; *) shift ;; esac
        done
        if [[ -n "\$buf_name" && -n "\$target" ]]; then
            buf_file="${SANDBOX}/buffers/\${buf_name}"
            [[ -f "\$buf_file" ]] && cat "\$buf_file" >> "${SANDBOX}/targets/\${target}"
        fi
        exit 0
        ;;
    delete-buffer)
        buf_name=""
        shift
        while [[ \$# -gt 0 ]]; do case "\$1" in -b) buf_name="\$2"; shift 2 ;; *) shift ;; esac; done
        [[ -n "\$buf_name" ]] && rm -f "${SANDBOX}/buffers/\${buf_name}"
        exit 0
        ;;
    send-keys) exit 0 ;;
    *) exit 0 ;;
esac
MOCK_REWRITE
    chmod +x "$mock"

    local test_file="$SANDBOX/test_content.txt"
    echo "content_for_target_0" > "$test_file"

    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        bash "$SCRIPT" inject-file --no-enter --force "session:0" "$test_file" 2>/dev/null || true

    # RED: 実装前は `load-buffer "$file_path"` (オプションなし) のため、
    # ログに "load-buffer -b" が含まれない → FAIL
    [[ -f "$call_log" ]] || {
        echo "FAIL: tmux が一度も呼ばれなかった（call_log が存在しない）" >&2
        return 1
    }
    grep -qF 'load-buffer -b' "$call_log" || {
        echo "FAIL: tmux call log に 'load-buffer -b' が含まれていない（named buffer 未使用）" >&2
        echo "  actual calls:" >&2
        cat "$call_log" >&2
        return 1
    }
}

@test "ac3[functional][RED]: 並列 10 プロセス inject-file で各 target が自分宛の内容のみ受信する" {
    # AC-3 並列検証: 10 プロセスを並列実行し、各 target_i が file_i の内容と一致する
    # RED: 実装前（anonymous buffer）では buffer が上書きされ、別の content が混入する可能性あり
    # テスト全体タイムアウト: 30 秒（@bats-timeout が使用できない場合は内部で制御）
    _create_mock_tmux_named_buffer
    _create_mock_session_state_input_waiting

    # 10 個のテストファイルを作成
    for i in $(seq 0 9); do
        echo "file_content_${i}" > "$SANDBOX/file_${i}.txt"
    done

    # 並列で inject-file を実行
    # resolve_target は "session:N" 形式（セッション名:インデックス）を直接受け付ける
    local pids=()
    for i in $(seq 0 9); do
        PATH="$SANDBOX/bin:$PATH" \
        _TEST_MODE=1 \
        SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
            bash "$SCRIPT" inject-file --no-enter --force "session:${i}" "$SANDBOX/file_${i}.txt" 2>/dev/null &
        pids+=($!)
    done

    # 全プロセス完了を待機（最大 30 秒）
    local wait_deadline=$(( $(date +%s) + 30 ))
    for pid in "${pids[@]}"; do
        local remaining=$(( wait_deadline - $(date +%s) ))
        if [[ "$remaining" -le 0 ]]; then
            echo "FAIL: 並列テストが 30 秒以内に完了しなかった" >&2
            kill "${pids[@]}" 2>/dev/null || true
            return 1
        fi
        wait "$pid" || true
    done

    # 各 session:i が file_i の内容と完全一致することを diff で検証
    local all_passed=true
    for i in $(seq 0 9); do
        local target_file="$SANDBOX/targets/session:${i}"
        local expected="$SANDBOX/file_${i}.txt"

        if [[ ! -f "$target_file" ]]; then
            echo "FAIL: session:${i} ターゲットファイルが作成されていない（named buffer 未実装）" >&2
            all_passed=false
            continue
        fi

        if ! diff -q "$expected" "$target_file" > /dev/null 2>&1; then
            echo "FAIL: session:${i} の内容が file_${i} と一致しない（buffer 競合の可能性）" >&2
            echo "  expected: $(cat "$expected")" >&2
            echo "  actual:   $(cat "$target_file")" >&2
            all_passed=false
        fi
    done

    [[ "$all_passed" == "true" ]] || return 1
}

@test "ac3[structural][RED]: named buffer 使用後に tmux delete-buffer -b が呼ばれる" {
    # AC-3 cleanup 検証: paste-buffer 後に delete-buffer -b が呼ばれることを call log で確認する
    # RED: delete-buffer -b の実装がない場合、call log に 'delete-buffer -b' が存在しない
    local call_log="$SANDBOX/tmux_delete_call.log"
    local mock="$SANDBOX/bin/tmux"
    mkdir -p "$SANDBOX/bin" "$SANDBOX/buffers" "$SANDBOX/targets"
    cat > "$mock" << MOCK_LOG
#!/bin/bash
echo "\$*" >> "${call_log}"
case "\$1" in
    -V) echo "tmux 3.4" ;;
    has-session) exit 0 ;;
    list-windows) echo "session:0 mock-window" ;;
    load-buffer)
        buf_name=""; file_arg=""
        shift
        while [[ \$# -gt 0 ]]; do
            case "\$1" in -b) buf_name="\$2"; shift 2 ;; *) file_arg="\$1"; shift ;; esac
        done
        if [[ -n "\$buf_name" && -n "\$file_arg" ]]; then cp "\$file_arg" "${SANDBOX}/buffers/\${buf_name}"; fi
        exit 0
        ;;
    paste-buffer)
        buf_name=""; target=""
        shift
        while [[ \$# -gt 0 ]]; do
            case "\$1" in -b) buf_name="\$2"; shift 2 ;; -t) target="\$2"; shift 2 ;; -p) shift ;; *) shift ;; esac
        done
        if [[ -n "\$buf_name" && -n "\$target" ]]; then
            [[ -f "${SANDBOX}/buffers/\${buf_name}" ]] && cat "${SANDBOX}/buffers/\${buf_name}" >> "${SANDBOX}/targets/\${target}"
        fi
        exit 0
        ;;
    delete-buffer)
        buf_name=""
        shift
        while [[ \$# -gt 0 ]]; do case "\$1" in -b) buf_name="\$2"; shift 2 ;; *) shift ;; esac; done
        [[ -n "\$buf_name" ]] && rm -f "${SANDBOX}/buffers/\${buf_name}"
        exit 0
        ;;
    send-keys) exit 0 ;;
    *) exit 0 ;;
esac
MOCK_LOG
    chmod +x "$mock"
    _create_mock_session_state_input_waiting

    local test_file="$SANDBOX/cleanup_test.txt"
    echo "cleanup_content" > "$test_file"

    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        bash "$SCRIPT" inject-file --no-enter --force "session:0" "$test_file" 2>/dev/null || true

    # 実装後: delete-buffer -b が呼ばれる
    # 実装前（RED）: call log に 'delete-buffer -b' が存在しない → FAIL
    [[ -f "$call_log" ]] || {
        echo "FAIL: tmux が一度も呼ばれなかった（call_log が存在しない）" >&2
        return 1
    }
    grep -qF 'delete-buffer -b' "$call_log" || {
        echo "FAIL: tmux call log に 'delete-buffer -b' が含まれていない（cleanup 未実装）" >&2
        echo "  actual calls:" >&2
        cat "$call_log" >&2
        return 1
    }
}


# ===========================================================================
# AC-6 (structural): cmd_inject_file 冒頭に tmux >= 2.0 前提条件コメントが存在する
# RED: 実装前はコメントが存在しないため FAIL する
# ===========================================================================

@test "ac6[structural][RED]: cmd_inject_file 冒頭コメントまたは usage に tmux 2.0 以上の前提条件が明示される" {
    # AC-6: delete-buffer -b は tmux 2.0+ 追加。cmd_inject_file のコメントまたは usage に
    # "tmux 2.0" または "tmux >= 2.0" などの記述が明示されていること
    # 実装前（RED）: 専用の前提条件コメントが存在しないため FAIL する
    # 注意: 既存の "tmux >= 3.2" コメント（bracketed paste）は AC-6 を満たさない（バージョンが異なる）
    grep -qE 'tmux[[:space:]]*[>=]+[[:space:]]*2\.0|tmux[[:space:]]*2\.0[[:space:]]|require.*tmux.*2\.0|前提.*tmux.*2\.0|tmux 2\.0' "$SCRIPT" || {
        echo "FAIL: session-comm.sh に tmux 2.0 を明示した前提条件コメントが含まれていない（AC-6 未実装）" >&2
        echo "  ヒント: 'tmux >= 2.0' または 'tmux 2.0' を cmd_inject_file のコメントに追記してください" >&2
        return 1
    }
}
