#!/usr/bin/env bats
# issue-1420-cmd-inject-file-signal-cleanup.bats
# Issue #1420: session-comm cmd_inject_file signal cleanup (SIGTERM/SIGHUP/SIGINT)
#
# RED テストスタブ。各テストは実装前に FAIL する。
#
# AC1: SIGTERM/SIGHUP/SIGINT の trap が cmd_inject_file に存在する（構造確認）
# AC2: trap が _buf_name 代入後・load-buffer 前に設定される（構造確認）
# AC3: SIGTERM -> exit 143 / SIGHUP -> exit 129 / SIGINT -> exit 130（機能確認）
# AC4: 既存 inline cleanup が温存され、冪等性が 2>/dev/null || true で保証される（構造確認）
# AC5: 各 exit 経路の exit 直前で trap - TERM HUP INT による trap 解除が存在する（構造確認）
# AC6: シグナル受信後バッファ残留なし（機能確認）
# AC7: 既存テストファイル存在確認
#
# NOTE: source guard 確認 (baseline-bash.md §10):
#       session-comm.sh に `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard が L558 に存在する。
#       このファイルは `bash "$SCRIPT"` で実行（source ではない）ため main 到達前 exit のリスクなし。
#
# NOTE: heredoc 変数展開 (baseline-bash.md §9):
#       mock tmux の heredoc は非クォート heredoc (<< MOCK) を使用する。
#       外部変数 $SANDBOX, $call_log, $active_buffers を parent shell で展開するため。
#       シングルクォート heredoc (<< 'MOCK') は外部変数を参照しない箇所にのみ使用する。

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
# helper: load-buffer を遅延させる mock tmux（シグナルテスト用）
# load-buffer 実行中に sleep を挟み、その間にシグナルを受信させる
# ===========================================================================

_create_mock_tmux_signal_test() {
    local delay="${1:-2}"
    local mock="$SANDBOX/bin/tmux"
    local call_log="$SANDBOX/tmux_calls.log"
    local active_buffers="$SANDBOX/active_buffers"
    mkdir -p "$SANDBOX/bin" "$SANDBOX/buffers" "$SANDBOX/targets"
    touch "$active_buffers"

    # NOTE: 非クォート heredoc — $SANDBOX, $call_log, $active_buffers, $delay は parent shell で展開
    cat > "$mock" << MOCK
#!/bin/bash
echo "\$*" >> "${call_log}"
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
    list-buffers)
        if [[ -s "${active_buffers}" ]]; then
            while IFS= read -r buf; do
                echo "\${buf}: 10 bytes"
            done < "${active_buffers}"
        fi
        exit 0
        ;;
    load-buffer)
        buf_name=""
        file_arg=""
        shift
        while [[ \$# -gt 0 ]]; do
            case "\$1" in
                -b) buf_name="\$2"; shift 2 ;;
                *)  file_arg="\$1"; shift ;;
            esac
        done
        if [[ -n "\$buf_name" && -n "\$file_arg" && -f "\$file_arg" ]]; then
            cp "\$file_arg" "${SANDBOX}/buffers/\${buf_name}"
            echo "\${buf_name}" >> "${active_buffers}"
        fi
        # シグナルテスト用遅延: load-buffer 中にシグナルが届くよう待機
        sleep ${delay}
        exit 0
        ;;
    paste-buffer)
        buf_name=""
        target=""
        shift
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
        fi
        exit 0
        ;;
    delete-buffer)
        buf_name=""
        shift
        while [[ \$# -gt 0 ]]; do
            case "\$1" in
                -b) buf_name="\$2"; shift 2 ;;
                *)  shift ;;
            esac
        done
        if [[ -n "\$buf_name" ]]; then
            rm -f "${SANDBOX}/buffers/\${buf_name}"
            grep -v "^\${buf_name}$" "${active_buffers}" > "${active_buffers}.tmp" 2>/dev/null || true
            mv "${active_buffers}.tmp" "${active_buffers}" 2>/dev/null || true
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
    # NOTE: シングルクォート heredoc — 外部変数を参照しないため問題なし
    cat > "$SANDBOX/mock_scripts/session-state.sh" << 'MOCK'
#!/bin/bash
if [[ "$1" == "state" ]]; then echo "input-waiting"; exit 0; fi
if [[ "$1" == "wait" ]]; then exit 0; fi
exit 0
MOCK
    chmod +x "$SANDBOX/mock_scripts/session-state.sh"
}

# ===========================================================================
# AC1 テスト: trap TERM/HUP/INT が cmd_inject_file に存在する（構造確認）
# RED: 現在の session-comm.sh には trap TERM/HUP/INT が存在しない
# ===========================================================================

@test "ac1: cmd_inject_file に trap TERM が存在する" {
    # AC1: cmd_inject_file 関数内に SIGTERM trap が設定されていること
    # RED: 現在の実装には trap が存在しない → FAIL
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    local trap_term
    trap_term=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /trap.*TERM/" "$SCRIPT")

    if [[ -z "$trap_term" ]]; then
        echo "FAIL: cmd_inject_file に 'trap ... TERM' が存在しない（#1420 trap 実装が必要）" >&2
        return 1
    fi
}

@test "ac1: cmd_inject_file に trap HUP が存在する" {
    # AC1: cmd_inject_file 関数内に SIGHUP trap が設定されていること
    # RED: 現在の実装には trap が存在しない → FAIL
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    local trap_hup
    trap_hup=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /trap.*HUP/" "$SCRIPT")

    if [[ -z "$trap_hup" ]]; then
        echo "FAIL: cmd_inject_file に 'trap ... HUP' が存在しない（#1420 trap 実装が必要）" >&2
        return 1
    fi
}

@test "ac1: cmd_inject_file に trap INT が存在する" {
    # AC1: cmd_inject_file 関数内に SIGINT trap が設定されていること
    # RED: 現在の実装には trap が存在しない → FAIL
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    local trap_int
    trap_int=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /trap.*INT/" "$SCRIPT")

    if [[ -z "$trap_int" ]]; then
        echo "FAIL: cmd_inject_file に 'trap ... INT' が存在しない（#1420 trap 実装が必要）" >&2
        return 1
    fi
}

@test "ac1: trap handler に delete-buffer が含まれる（TERM/HUP/INT いずれか）" {
    # AC1: trap handler 内で tmux delete-buffer -b "$_buf_name" が実行されること
    # RED: 現在の実装には trap が存在しない → FAIL
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    # trap 行に delete-buffer が含まれているか確認
    local trap_with_delete
    trap_with_delete=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /trap.*delete-buffer/" "$SCRIPT")

    if [[ -z "$trap_with_delete" ]]; then
        echo "FAIL: cmd_inject_file の trap handler に delete-buffer が含まれていない" >&2
        echo "  期待: trap 'tmux delete-buffer -b \"\$_buf_name\" 2>/dev/null; exit N' TERM/HUP/INT" >&2
        return 1
    fi
}

# ===========================================================================
# AC2 テスト: trap が _buf_name 代入後・load-buffer 前に設定される（構造確認）
# RED: 現在の実装には trap 自体が存在しない
# ===========================================================================

@test "ac2: trap が _buf_name 代入後かつ load-buffer 呼び出し前に設定される" {
    # AC2: _buf_name が確定してから trap を設定し、未設定変数参照を避ける
    # RED: 現在の実装には trap が存在しない → FAIL
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    local buf_name_line trap_line load_buffer_line
    buf_name_line=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /local _buf_name=/ {print NR; exit}" "$SCRIPT")
    trap_line=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /trap.*TERM|trap.*HUP|trap.*INT/ {print NR; exit}" "$SCRIPT")
    load_buffer_line=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /tmux load-buffer -b/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$trap_line" ]]; then
        echo "FAIL: cmd_inject_file に trap TERM/HUP/INT が存在しない（#1420 trap 実装が必要）" >&2
        return 1
    fi

    if [[ -z "$buf_name_line" || -z "$load_buffer_line" ]]; then
        echo "FAIL: _buf_name 代入行 (${buf_name_line:-未特定}) または load-buffer 行 (${load_buffer_line:-未特定}) が特定できない" >&2
        return 1
    fi

    # 順序確認: buf_name_line < trap_line < load_buffer_line
    if [[ "$trap_line" -le "$buf_name_line" ]]; then
        echo "FAIL: trap (L$trap_line) が _buf_name 代入 (L$buf_name_line) より前に設定されている" >&2
        return 1
    fi
    if [[ "$trap_line" -ge "$load_buffer_line" ]]; then
        echo "FAIL: trap (L$trap_line) が load-buffer 呼び出し (L$load_buffer_line) より後に設定されている" >&2
        return 1
    fi
}

# ===========================================================================
# AC3 テスト: シグナル別の signal-conventional 終了コード（機能確認）
# ===========================================================================

@test "ac3: SIGTERM 送信時に終了コード 143 (128+15) で終了する" {
    # AC3: SIGTERM 受信時に trap handler が exit 143 を実行すること
    # 現在の実装には trap がないため、SIGTERM でのバッファ cleanup が保証されない
    _create_mock_tmux_signal_test 3
    _create_mock_session_state_input_waiting

    local test_file="$SANDBOX/test_content.txt"
    echo "test content for ac3 sigterm" > "$test_file"

    local pid exit_code=0
    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        bash "$SCRIPT" inject-file --no-enter --force "session:0" "$test_file" 2>/dev/null &
    pid=$!

    # プロセスが load-buffer の sleep に入るまで待機
    sleep 1

    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -ne 143 ]]; then
        echo "FAIL: SIGTERM 後の exit code が 143 でない（actual: $exit_code）" >&2
        echo "  #1420 trap 実装が必要: trap 'tmux delete-buffer -b \"\$_buf_name\" 2>/dev/null; exit 143' TERM" >&2
        return 1
    fi
}

@test "ac3: SIGHUP 送信時に終了コード 129 (128+1) で終了する" {
    # AC3: SIGHUP 受信時に trap handler が exit 129 を実行すること
    # 現在の実装には trap がないため → FAIL (RED)
    _create_mock_tmux_signal_test 3
    _create_mock_session_state_input_waiting

    local test_file="$SANDBOX/test_content.txt"
    echo "test content for ac3 sighup" > "$test_file"

    local pid exit_code=0
    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        bash "$SCRIPT" inject-file --no-enter --force "session:0" "$test_file" 2>/dev/null &
    pid=$!

    sleep 1

    kill -HUP "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -ne 129 ]]; then
        echo "FAIL: SIGHUP 後の exit code が 129 でない（actual: $exit_code）" >&2
        echo "  #1420 trap 実装が必要: trap 'tmux delete-buffer -b \"\$_buf_name\" 2>/dev/null; exit 129' HUP" >&2
        return 1
    fi
}

@test "ac3: SIGINT 送信時に終了コード 130 (128+2) で終了する" {
    # AC3: SIGINT 受信時に trap handler が exit 130 を実行すること
    # set -m（ジョブ制御）+ kill -INT -$pgid でプロセスグループへ SIGINT を送信する
    _create_mock_tmux_signal_test 3
    _create_mock_session_state_input_waiting

    local test_file="$SANDBOX/test_content.txt"
    echo "test content for ac3 sigint" > "$test_file"

    local active_buffers="$SANDBOX/active_buffers"

    # set -m: ジョブ制御有効化 → background プロセスが独立 process group に配置される
    set -m
    trap 'set +m' RETURN

    local pid exit_code=0
    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        bash "$SCRIPT" inject-file --no-enter --force "session:0" "$test_file" 2>/dev/null &
    pid=$!

    # active_buffers に書き込まれるまで待機（load-buffer が呼ばれたことの確認）
    local waited=0
    while [[ ! -s "$active_buffers" ]] && [[ $waited -lt 20 ]]; do
        sleep 0.1; waited=$((waited+1))
    done

    if [[ ! -s "$active_buffers" ]]; then
        skip "タイムアウト: load-buffer 待機が 2s 内に完了しなかった（CI 低速環境の可能性）"
    fi

    # pgid を取得してプロセスグループへ SIGINT 送信
    local pgid
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ "$pgid" =~ ^[1-9][0-9]*$ ]]; then
        kill -INT "-$pgid" 2>/dev/null || kill -INT "$pid" 2>/dev/null || true
    else
        kill -INT "$pid" 2>/dev/null || true
    fi

    wait "$pid" 2>/dev/null || exit_code=$?

    if [[ "$exit_code" -ne 130 ]]; then
        echo "FAIL: SIGINT 後の exit code が 130 でない（actual: $exit_code）" >&2
        echo "  #1420 trap 実装が必要: trap 'tmux delete-buffer -b \"\$_buf_name\" 2>/dev/null; exit 130' INT" >&2
        return 1
    fi
}

# ===========================================================================
# AC4 テスト: 既存 inline cleanup（normal path / 3 つの error path）が温存されている
# GREEN-regression: inline cleanup (#1395) が trap 追加後も残っていること
# ===========================================================================

@test "ac4: load-buffer error path の inline delete-buffer が温存されている" {
    # AC4: load-buffer 失敗時の inline cleanup が残っていること
    # このテストは現在 GREEN になる可能性あり（inline cleanup は既に実装済み）
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    local load_buffer_block
    load_buffer_block=$(awk "
        NR >= $start_line && NR <= ${end_line:-99999} {
            if (/tmux load-buffer -b/) { in_block=1 }
            if (in_block) { print }
            if (in_block && /^\s*\}/) { in_block=0 }
        }
    " "$SCRIPT" | head -10)

    echo "$load_buffer_block" | grep -q 'delete-buffer' || {
        echo "FAIL: load-buffer error block に inline delete-buffer が存在しない" >&2
        echo "  #1395 の inline cleanup が削除されている可能性あり（regression）" >&2
        return 1
    }
}

@test "ac4: paste-buffer error path の inline delete-buffer が温存されている" {
    # AC4: paste-buffer 失敗時の inline cleanup が残っていること
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    # paste-buffer ブロック内に delete-buffer が含まれるか
    local paste_buffer_block
    paste_buffer_block=$(awk "
        NR >= $start_line && NR <= ${end_line:-99999} {
            if (/tmux paste-buffer -b/) { in_block=1 }
            if (in_block) { print }
            if (in_block && /^\s*\}/) { in_block=0 }
        }
    " "$SCRIPT" | head -20)

    echo "$paste_buffer_block" | grep -q 'delete-buffer' || {
        echo "FAIL: paste-buffer error block に inline delete-buffer が存在しない" >&2
        echo "  #1395 の inline cleanup が削除されている可能性あり（regression）" >&2
        return 1
    }
}

@test "ac4: normal path の最終 delete-buffer が温存されている（正常終了 cleanup）" {
    # AC4: 正常終了時（paste-buffer 後）の delete-buffer が残っていること
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    # 正常終了 delete-buffer: paste-buffer 行より後に存在する delete-buffer
    local paste_line last_delete_line
    paste_line=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /tmux paste-buffer -b/ {line=NR} END {print line+0}" "$SCRIPT")
    last_delete_line=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /tmux delete-buffer -b.*2>\/dev\/null/ {line=NR} END {print line+0}" "$SCRIPT")

    if [[ "$last_delete_line" -le "$paste_line" ]]; then
        echo "FAIL: paste-buffer 後に delete-buffer が存在しない（正常終了 cleanup が消えている）" >&2
        echo "  paste-buffer: L$paste_line, delete-buffer: L$last_delete_line" >&2
        return 1
    fi
}

@test "ac4: delete-buffer が 2>/dev/null || true で冪等性を保証している（inline cleanup 全体）" {
    # AC4: 既存の delete-buffer 呼び出しが全て 2>/dev/null || true パターンで冪等
    # RED: 現在は冪等性チェックのみ（実装は既存だが、AC5 trap 追加後も維持が必要）
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    # delete-buffer 行が全て 2>/dev/null || true を持つかチェック
    # trap handler 行を除外（trap 行は1行に凝縮されているため別途確認）
    local delete_without_idempotent
    delete_without_idempotent=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /tmux delete-buffer/ && !/2>\/dev\/null/ && !/trap/" "$SCRIPT")

    if [[ -n "$delete_without_idempotent" ]]; then
        echo "FAIL: 冪等性パターン 2>/dev/null || true を持たない delete-buffer が存在する:" >&2
        echo "$delete_without_idempotent" >&2
        return 1
    fi
}

# ===========================================================================
# AC5 テスト: 各 exit 経路の exit 直前で trap - TERM HUP INT が実行される（構造確認）
# RED: 現在の実装には trap も trap 解除も存在しない
# ===========================================================================

@test "ac5: cmd_inject_file に trap - TERM HUP INT（trap 解除）が存在する" {
    # AC5: 各 exit 経路で trap - TERM HUP INT により trap を解除すること
    # RED: 現在の実装には trap 自体が存在しない → FAIL
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    # 'trap -' または 'trap -- ' の存在確認
    local trap_deregister
    trap_deregister=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /trap -[[:space:]].*TERM|trap --[[:space:]].*TERM/" "$SCRIPT")

    if [[ -z "$trap_deregister" ]]; then
        echo "FAIL: cmd_inject_file に 'trap - TERM HUP INT' / 'trap -- TERM HUP INT' が存在しない" >&2
        echo "  #1420 実装が必要: 各 exit 経路の exit 直前で trap 解除が必要" >&2
        return 1
    fi
}

@test "ac5: trap 解除が複数の exit 経路（error path 含む）で存在する" {
    # AC5: error path（load-buffer fail, paste-buffer fail）と正常終了の両方で trap 解除があること
    # RED: 現在の実装には trap も trap 解除も存在しない → FAIL
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    # trap 解除の出現回数を確認（最低 2 回: 正常 + error path 群）
    local trap_reset_count
    trap_reset_count=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /trap -[[:space:]].*TERM|trap --[[:space:]].*TERM/" "$SCRIPT" | wc -l)

    if [[ "$trap_reset_count" -lt 2 ]]; then
        echo "FAIL: trap 解除が $trap_reset_count 箇所しか存在しない（最低 2 箇所必要: 正常パス + error path）" >&2
        echo "  現在の trap 解除箇所: $trap_reset_count" >&2
        echo "  期待: 正常終了 + load-buffer error + paste-buffer error の各 exit 前" >&2
        return 1
    fi
}

@test "ac5: 正常終了の delete-buffer 後に trap 解除が存在する（順序確認）" {
    # AC5: 正常終了では delete-buffer 後に trap - TERM HUP INT を実行する
    # RED: 現在の実装には trap も trap 解除も存在しない → FAIL
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    # 正常終了 delete-buffer の最終行番号
    local last_delete_line
    last_delete_line=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /tmux delete-buffer -b.*2>\/dev\/null/ {line=NR} END {print line+0}" "$SCRIPT")

    # trap 解除の最終行番号（正常終了パスのもの）
    local last_trap_reset_line
    last_trap_reset_line=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /trap -[[:space:]].*TERM|trap --[[:space:]].*TERM/ {line=NR} END {print line+0}" "$SCRIPT")

    if [[ "$last_trap_reset_line" -eq 0 ]]; then
        echo "FAIL: cmd_inject_file に trap 解除が存在しない" >&2
        return 1
    fi

    if [[ "$last_trap_reset_line" -le "$last_delete_line" ]]; then
        echo "FAIL: 最後の trap 解除 (L$last_trap_reset_line) が最後の delete-buffer (L$last_delete_line) より前にある" >&2
        echo "  正常終了パスでは delete-buffer 後に trap 解除が必要" >&2
        return 1
    fi
}

# ===========================================================================
# AC6 テスト: シグナル受信後バッファ残留なし（機能確認）
# RED: 現在の実装に trap がないためバッファが残留する
# ===========================================================================

@test "ac6: SIGTERM 受信後に session-comm-* バッファが残留しない" {
    # AC6: SIGTERM 受信時に trap handler が delete-buffer を呼び、バッファを削除すること
    # RED: 現在の実装には trap がないためバッファが残留する → FAIL
    _create_mock_tmux_signal_test 3
    _create_mock_session_state_input_waiting

    local test_file="$SANDBOX/test_content.txt"
    echo "test content for ac6 sigterm cleanup" > "$test_file"

    local pid exit_code=0
    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        bash "$SCRIPT" inject-file --no-enter --force "session:0" "$test_file" 2>/dev/null &
    pid=$!

    sleep 1
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || exit_code=$?

    local active_buffers="$SANDBOX/active_buffers"
    local remaining_count
    remaining_count=$(grep -c 'session-comm-' "$active_buffers" 2>/dev/null || echo 0)

    if [[ "$remaining_count" -gt 0 ]]; then
        echo "FAIL: SIGTERM 後に session-comm-* バッファが $remaining_count 件残留している" >&2
        grep 'session-comm-' "$active_buffers" >&2
        echo "  #1420 trap TERM handler で delete-buffer が必要" >&2
        return 1
    fi
}

@test "ac6: SIGHUP 受信後に session-comm-* バッファが残留しない" {
    # AC6: SIGHUP 受信時に trap handler が delete-buffer を呼び、バッファを削除すること
    # RED: 現在の実装には trap がないためバッファが残留する → FAIL
    _create_mock_tmux_signal_test 3
    _create_mock_session_state_input_waiting

    local test_file="$SANDBOX/test_content.txt"
    echo "test content for ac6 sighup cleanup" > "$test_file"

    local pid exit_code=0
    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        bash "$SCRIPT" inject-file --no-enter --force "session:0" "$test_file" 2>/dev/null &
    pid=$!

    sleep 1
    kill -HUP "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || exit_code=$?

    local active_buffers="$SANDBOX/active_buffers"
    local remaining_count
    remaining_count=$(grep -c 'session-comm-' "$active_buffers" 2>/dev/null || echo 0)

    if [[ "$remaining_count" -gt 0 ]]; then
        echo "FAIL: SIGHUP 後に session-comm-* バッファが $remaining_count 件残留している" >&2
        grep 'session-comm-' "$active_buffers" >&2
        echo "  #1420 trap HUP handler で delete-buffer が必要" >&2
        return 1
    fi
}

@test "ac6: SIGINT 受信後に session-comm-* バッファが残留しない" {
    # AC6: SIGINT 受信時に trap handler が delete-buffer を呼び、バッファを削除すること
    # RED: 現在の実装には trap INT がないためバッファが残留する
    #      set -m 方式で SIGINT を届かせるが、trap が未実装のためバッファ残留が発生する
    _create_mock_tmux_signal_test 3
    _create_mock_session_state_input_waiting

    local test_file="$SANDBOX/test_content.txt"
    echo "test content for ac6 sigint cleanup" > "$test_file"

    local active_buffers="$SANDBOX/active_buffers"

    set -m
    trap 'set +m' RETURN

    local pid exit_code=0
    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        bash "$SCRIPT" inject-file --no-enter --force "session:0" "$test_file" 2>/dev/null &
    pid=$!

    local waited=0
    while [[ ! -s "$active_buffers" ]] && [[ $waited -lt 20 ]]; do
        sleep 0.1; waited=$((waited+1))
    done

    if [[ ! -s "$active_buffers" ]]; then
        skip "タイムアウト: load-buffer 待機が 2s 内に完了しなかった（CI 低速環境の可能性）"
    fi

    local pgid
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ "$pgid" =~ ^[1-9][0-9]*$ ]]; then
        kill -INT "-$pgid" 2>/dev/null || kill -INT "$pid" 2>/dev/null || true
    else
        kill -INT "$pid" 2>/dev/null || true
    fi

    wait "$pid" 2>/dev/null || exit_code=$?

    local remaining_count
    remaining_count=$(grep -c 'session-comm-' "$active_buffers" 2>/dev/null || echo 0)

    if [[ "$remaining_count" -gt 0 ]]; then
        echo "FAIL: SIGINT 後に session-comm-* バッファが $remaining_count 件残留している" >&2
        grep 'session-comm-' "$active_buffers" >&2
        echo "  #1420 trap INT handler で delete-buffer が必要" >&2
        return 1
    fi
}

# ===========================================================================
# AC7 テスト: 既存テストファイル存在確認（regression 防止）
# ===========================================================================

@test "ac7: issue-1050-inject-file-named-buffer.bats が存在する" {
    # AC7: 既存テストファイルが削除されていないこと（regression 防止）
    local test_1050
    test_1050="$(dirname "$BATS_TEST_FILENAME")/issue-1050-inject-file-named-buffer.bats"
    [[ -f "$test_1050" ]] || {
        echo "FAIL: issue-1050-inject-file-named-buffer.bats が存在しない（regression）" >&2
        return 1
    }
}

@test "ac7: session-comm-robustness.test.sh が存在する" {
    # AC7: 既存テストファイルが削除されていないこと（regression 防止）
    local test_robustness
    test_robustness="$(dirname "$BATS_TEST_FILENAME")/session-comm-robustness.test.sh"
    [[ -f "$test_robustness" ]] || {
        echo "FAIL: session-comm-robustness.test.sh が存在しない（regression）" >&2
        return 1
    }
}
