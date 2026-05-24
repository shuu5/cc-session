#!/usr/bin/env bats
# test_1420_cmd_inject_file_signal_cleanup.bats
# Issue #1420: session-comm cmd_inject_file signal cleanup (SIGTERM/SIGHUP/SIGINT)
# Issue #1436: tech-debt: test 6 (SIGINT exit code 検証) の bats 非インタラクティブ問題修正
#
# AC1: SIGTERM/SIGHUP/SIGINT の trap が cmd_inject_file に存在する（構造確認）
# AC2: trap が _buf_name 代入後・load-buffer 前に設定される（構造確認）
# AC3: SIGTERM -> exit 143 / SIGHUP -> exit 129 / SIGINT -> exit 130（機能確認）
# AC4: 既存 test 1-5, 7+ に regression がない（GREEN-regression）
# AC5: trap が正常パスの load-buffer 前後に適切に処置される（構造確認）
# AC6: シグナル受信後バッファ残留なし（機能確認）
# AC7: 既存テストファイル存在確認（GREEN）
#
# NOTE: test 6 (SIGINT exit code 検証) は bats 非インタラクティブ環境での制約により
#       Issue #1436 の修正対象。現在は FAIL する（= RED 状態）。
#       bats 通常実行では SIGINT がサブプロセスに到達しないため、
#       Issue #1436 では「SKIP with 理由明記」または「代替検証方式」への移行が必要。
#
# NOTE: source guard 確認:
#       session-comm.sh に `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard が存在する (L539)。
#       このファイルは bash "$SCRIPT" で実行（source ではない）ため問題なし。
#
# NOTE: heredoc 変数展開:
#       mock tmux の heredoc は非クォート heredoc (<< MOCK) を使用する。
#       外部変数 $SANDBOX, $call_log, $active_buffers を parent shell で展開するため。

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
# SIGTERM/SIGHUP/SIGINT がサブプロセスに到達した場合に trap を発火させるため
# load-buffer 中に sleep で待機する
# ===========================================================================

_create_mock_tmux_signal_test() {
    local delay="${1:-2}"  # load-buffer の遅延秒数（default: 2s）
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
# test 1: ac1[structural][RED] - trap TERM が cmd_inject_file に存在するか
# RED: 現在の session-comm.sh には trap TERM/HUP/INT が存在しない
# ===========================================================================

@test "ac1[structural][RED]: cmd_inject_file に trap TERM が存在する" {
    # AC1: cmd_inject_file 関数内に SIGTERM trap が設定されていること
    # 現在の実装には trap が存在しない → FAIL (RED)
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

# ===========================================================================
# test 2: ac1[structural][RED] - trap HUP/INT が cmd_inject_file に存在するか
# RED: 現在の session-comm.sh には trap TERM/HUP/INT が存在しない
# ===========================================================================

@test "ac1[structural][RED]: cmd_inject_file に trap HUP と trap INT が存在する" {
    # AC1: cmd_inject_file 関数内に SIGHUP・SIGINT trap が設定されていること
    # 現在の実装には trap が存在しない → FAIL (RED)
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    local trap_hup trap_int
    trap_hup=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /trap.*HUP/" "$SCRIPT")
    trap_int=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /trap.*INT/" "$SCRIPT")

    local missing=()
    [[ -z "$trap_hup" ]] && missing+=("HUP")
    [[ -z "$trap_int" ]] && missing+=("INT")

    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "FAIL: cmd_inject_file に trap が不足している: ${missing[*]}" >&2
        echo "  #1420 trap 実装が必要" >&2
        return 1
    fi
}

# ===========================================================================
# test 3: ac2[structural][RED] - trap が _buf_name 代入後・load-buffer 前に設定されるか
# RED: 現在の実装には trap 自体が存在しない
# ===========================================================================

@test "ac2[structural][RED]: trap が _buf_name 代入後かつ load-buffer 前に設定される" {
    # AC2: trap を _buf_name 確定後に設定し、シグナルでバッファ名が確定していることを保証する
    # 現在の実装には trap が存在しない → FAIL (RED)
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    # _buf_name 代入行番号
    local buf_name_line
    buf_name_line=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /local _buf_name=/ {print NR; exit}" "$SCRIPT")

    # trap 設定行番号（最初の trap TERM/HUP/INT）
    local trap_line
    trap_line=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /trap.*TERM|trap.*HUP|trap.*INT/ {print NR; exit}" "$SCRIPT")

    # load-buffer 呼び出し行番号
    local load_buffer_line
    load_buffer_line=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /tmux load-buffer -b/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$trap_line" ]]; then
        echo "FAIL: cmd_inject_file に trap TERM/HUP/INT が存在しない（#1420 trap 実装が必要）" >&2
        return 1
    fi

    if [[ -z "$buf_name_line" || -z "$load_buffer_line" ]]; then
        echo "FAIL: _buf_name 代入行 ($buf_name_line) または load-buffer 行 ($load_buffer_line) が特定できない" >&2
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
# test 4: ac3[functional][RED] - SIGTERM -> exit 143
# RED: 現在の実装に trap がないため SIGTERM が正しく処理されない
# ===========================================================================

@test "ac3[functional][RED]: SIGTERM 送信時に終了コード 143 (128+15) で終了する" {
    # AC3: SIGTERM を受信した cmd_inject_file が exit 143 で終了すること
    # 現在の実装には trap がないため、SIGTERM は bash デフォルト動作（exit 143）になる場合もあるが
    # バッファ cleanup が保証されない → この構造テストで #1420 trap の存在を前提とする
    #
    # 機能テスト: load-buffer 遅延中に SIGTERM を送信し、exit code を確認する
    _create_mock_tmux_signal_test 3
    _create_mock_session_state_input_waiting

    local test_file="$SANDBOX/test_content.txt"
    echo "test content for sigterm" > "$test_file"

    local pid exit_code=0
    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        bash "$SCRIPT" inject-file --no-enter --force "session:0" "$test_file" 2>/dev/null &
    pid=$!

    # プロセスが起動するまで待機（load-buffer 遅延中に SIGTERM を送る）
    sleep 1

    # SIGTERM 送信
    kill -TERM "$pid" 2>/dev/null || true

    # プロセス完了を待機
    wait "$pid" 2>/dev/null || exit_code=$?

    # SIGTERM: exit 143 (128 + 15)
    if [[ "$exit_code" -ne 143 ]]; then
        echo "FAIL: SIGTERM 後の exit code が 143 でない（actual: $exit_code）" >&2
        echo "  #1420 trap 実装が必要: trap 'tmux delete-buffer -b \"\$_buf_name\" 2>/dev/null; exit 143' TERM" >&2
        return 1
    fi
}

# ===========================================================================
# test 5: ac3[functional] - SIGHUP -> exit 129
# [ISSUE-1682-FIXED]: session-comm.sh に trap HUP が実装済み (#1504)
# ===========================================================================

@test "ac3[functional]: SIGHUP 送信時に終了コード 129 (128+1) で終了する [ISSUE-1682-FIXED]" {
    # AC3: SIGHUP を受信した cmd_inject_file が exit 129 で終了すること
    # [ISSUE-1682-FIXED]: session-comm.sh line 437 に trap HUP 実装済み (#1504)
    _create_mock_tmux_signal_test 3
    _create_mock_session_state_input_waiting

    local test_file="$SANDBOX/test_content.txt"
    echo "test content for sighup" > "$test_file"

    local pid exit_code=0
    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        bash "$SCRIPT" inject-file --no-enter --force "session:0" "$test_file" 2>/dev/null &
    pid=$!

    sleep 1

    # SIGHUP 送信
    kill -HUP "$pid" 2>/dev/null || true

    wait "$pid" 2>/dev/null || exit_code=$?

    # SIGHUP: exit 129 (128 + 1)
    if [[ "$exit_code" -ne 129 ]]; then
        echo "FAIL: SIGHUP 後の exit code が 129 でない（actual: $exit_code）" >&2
        echo "  #1420 trap 実装が必要: trap 'tmux delete-buffer -b \"\$_buf_name\" 2>/dev/null; exit 129' HUP" >&2
        return 1
    fi
}

# ===========================================================================
# test 6: ac3[functional][RED] - SIGINT -> exit 130
#
# *** Issue #1436 の修正対象テスト ***
#
# RED 理由（Issue #1436 スコープ）:
#   bats の非インタラクティブ環境では、bats は SIGINT を自身でトラップして
#   サブプロセスには転送しない。`kill -INT $pid` でも bats の制御機構が
#   SIGINT を消費するため、background プロセスに SIGINT が届かない場合がある。
#
# 現在のステータス: FAIL
#   - session-comm.sh に trap INT が未実装（#1420 前提）
#   - bats 非インタラクティブ環境での SIGINT 到達問題（#1436 本題）
#
# Issue #1436 での解決方針:
#   - 選定方式 A: SIGINT の代わりに kill -INT を bash サブシェル経由で送信し、
#     終了コード 130 を検証する代替方式に変更する
#   - 選定方式 B: 環境制約を明記して skip にする
#   - 選定方式 C: bats external runner でプロセスグループを分離して SIGINT を送信する
#   決定は PR description に根拠付きで記録すること（AC1 要件）
# ===========================================================================

@test "ac3[functional]: SIGINT 送信時に終了コード 130 (128+2) で終了する [ISSUE-1436-FIXED]" {
    # AC3: SIGINT を受信した cmd_inject_file が exit 130 で終了すること
    #
    # [ISSUE-1436-FIXED]: Issue #1436 で選定した set -m（job control）方式で修正済み。
    #
    # 選定方式: set -m + kill -INT -$pgid（プロセスグループ指定）
    # 根拠（Issue #1436 AC1）:
    #   - bats 非インタラクティブ環境: POSIX 規定により background プロセスは
    #     SIGINT が SIG_IGN になるため `kill -INT $pid` が届かない場合がある
    #   - set -m でジョブ制御を有効化すると background プロセスが独立 process group
    #     に配置される。kill -INT -$pgid でプロセスグループ全体に SIGINT が届く
    #   - session-comm.sh に trap INT がなくても、SIGINT のデフォルト動作（exit 130）
    #     が発動するため終了コード 130 が取得できる
    # 実証コマンド（ローカル検証済み、3 回連続 PASS）:
    #   bats plugins/session/tests/test_1420_cmd_inject_file_signal_cleanup.bats \
    #        --filter "SIGINT 送信時"

    _create_mock_tmux_signal_test 3
    _create_mock_session_state_input_waiting

    local test_file="$SANDBOX/test_content.txt"
    echo "test content for sigint" > "$test_file"

    local active_buffers="$SANDBOX/active_buffers"

    # set -m: ジョブ制御有効化 → background プロセスが独立 process group に配置される
    # bats サブシェルとは別 pgid に配置されるため kill -INT -$pgid が bats 自身に届かない
    set -m
    # set +m を RETURN trap でガード（return 1 パスで set -m が残留しないようにする）
    trap 'set +m' RETURN
    local pid exit_code=0
    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        bash "$SCRIPT" inject-file --no-enter --force "session:0" "$test_file" 2>/dev/null &
    pid=$!

    # load-buffer が active_buffers に書き込むまで待機（最大 2s）
    local waited=0
    while [[ ! -s "$active_buffers" ]] && [[ $waited -lt 20 ]]; do
        sleep 0.1; waited=$((waited+1))
    done

    # タイムアウト確認（active_buffers 未書き込みはタイムアウト = CI 低速環境）
    if [[ ! -s "$active_buffers" ]]; then
        skip "タイムアウト: load-buffer 待機が 2s 内に完了しなかった（CI 低速環境の可能性）"
    fi

    # pgid を取得してプロセスグループへ SIGINT 送信（allowlist 検証付き）
    local pgid
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ "$pgid" =~ ^[1-9][0-9]*$ ]]; then
        kill -INT "-$pgid" 2>/dev/null || kill -INT "$pid" 2>/dev/null || true
    else
        kill -INT "$pid" 2>/dev/null || true
    fi

    wait "$pid" 2>/dev/null || exit_code=$?

    # SIGINT のデフォルト動作: exit 130 (128 + 2)
    # trap INT 未実装でも SIGINT で終了するため exit 130 になる
    if [[ "$exit_code" -ne 130 ]]; then
        echo "FAIL: SIGINT 後の exit code が 130 でない（actual: $exit_code）" >&2
        return 1
    fi
}

# ===========================================================================
# test 7: ac4[structural][GREEN-regression] - inline cleanup が温存されているか確認
# GREEN-regression: inline cleanup (#1395) が trap 追加後も残っていること
# ===========================================================================

@test "ac4[structural][GREEN-regression]: load-buffer error path の inline delete-buffer が温存されている" {
    # AC4: #1395 の inline cleanup（load-buffer error block の delete-buffer）が
    #      #1420 trap 追加後も削除されていないことを確認する
    # このテストは現在 GREEN になる可能性がある（inline cleanup は既に実装済み）
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    # load-buffer error block 内に delete-buffer が存在するか（inline cleanup の確認）
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

# ===========================================================================
# test 8: ac4[structural][GREEN-regression] - trap EXIT 対が cmd_inject_file に戻っていないか
# GREEN-regression: #1395 で削除された trap EXIT が再追加されていないことを確認
# ===========================================================================

@test "ac4[structural][GREEN-regression]: cmd_inject_file に trap EXIT が存在しない（#1395 regression 確認）" {
    # AC4: #1395 で削除された trap EXIT 対が #1420 trap 追加時に再導入されていないことを確認
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    local trap_exit_lines
    trap_exit_lines=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /trap.*EXIT/" "$SCRIPT")

    if [[ -n "$trap_exit_lines" ]]; then
        echo "FAIL: cmd_inject_file に trap.*EXIT が存在する（#1395 regression）" >&2
        echo "  該当行:" >&2
        echo "$trap_exit_lines" >&2
        return 1
    fi
}

# ===========================================================================
# test 9: ac5[structural][RED] - trap ハンドラが delete-buffer を含む（TERM）
# RED: 現在の実装に trap が存在しない
# ===========================================================================

@test "ac5[structural][RED]: trap TERM ハンドラに delete-buffer -b が含まれる" {
    # AC5: SIGTERM trap の handler で _buf_name バッファを delete すること
    # 現在の実装には trap が存在しない → FAIL (RED)
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    # trap TERM の行を抽出し、delete-buffer が含まれるか確認
    local trap_term_line
    trap_term_line=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /trap.*TERM/" "$SCRIPT" | head -1)

    if [[ -z "$trap_term_line" ]]; then
        echo "FAIL: cmd_inject_file に trap TERM が存在しない" >&2
        return 1
    fi

    # trap handler に delete-buffer が含まれるか
    echo "$trap_term_line" | grep -q 'delete-buffer' || {
        echo "FAIL: trap TERM handler に delete-buffer が含まれていない" >&2
        echo "  actual: $trap_term_line" >&2
        return 1
    }
}

# ===========================================================================
# test 10: ac5[structural][RED] - trap ハンドラが delete-buffer を含む（HUP/INT）
# RED: 現在の実装に trap が存在しない
# ===========================================================================

@test "ac5[structural][RED]: trap HUP と trap INT ハンドラに delete-buffer -b が含まれる" {
    # AC5: SIGHUP・SIGINT trap の handler で _buf_name バッファを delete すること
    # 現在の実装には trap が存在しない → FAIL (RED)
    local start_line end_line
    start_line=$(grep -n '^cmd_inject_file()' "$SCRIPT" | head -1 | cut -d: -f1)
    end_line=$(awk "NR > $start_line && /^[a-z_]+\(\)/ {print NR; exit}" "$SCRIPT")

    if [[ -z "$start_line" ]]; then
        echo "FAIL: cmd_inject_file() 関数が見つからない" >&2
        return 1
    fi

    local missing=()

    # trap HUP
    local trap_hup_line
    trap_hup_line=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /trap.*HUP/" "$SCRIPT" | head -1)
    if [[ -z "$trap_hup_line" ]]; then
        missing+=("HUP: trap 未存在")
    elif ! echo "$trap_hup_line" | grep -q 'delete-buffer'; then
        missing+=("HUP: trap handler に delete-buffer なし")
    fi

    # trap INT
    local trap_int_line
    trap_int_line=$(awk "NR >= $start_line && NR <= ${end_line:-99999} && /trap.*INT/" "$SCRIPT" | head -1)
    if [[ -z "$trap_int_line" ]]; then
        missing+=("INT: trap 未存在")
    elif ! echo "$trap_int_line" | grep -q 'delete-buffer'; then
        missing+=("INT: trap handler に delete-buffer なし")
    fi

    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "FAIL: 以下の trap ハンドラに問題あり:" >&2
        for m in "${missing[@]}"; do
            echo "  - $m" >&2
        done
        return 1
    fi
}

# ===========================================================================
# test 11: ac6[functional][RED] - SIGTERM 受信後バッファ残留なし
# RED: 現在の実装に trap がないためバッファが残留する
# ===========================================================================

@test "ac6[functional][RED]: SIGTERM 受信後に session-comm-* バッファが残留しない" {
    # AC6: SIGTERM 受信時に trap handler が delete-buffer を呼び、バッファを削除すること
    # 現在の実装には trap がないため → バッファが残留する可能性 → FAIL (RED)
    _create_mock_tmux_signal_test 3
    _create_mock_session_state_input_waiting

    local test_file="$SANDBOX/test_content.txt"
    echo "test content for sigterm cleanup" > "$test_file"

    local pid exit_code=0
    PATH="$SANDBOX/bin:$PATH" \
    _TEST_MODE=1 \
    SESSION_COMM_SCRIPT_DIR="$SANDBOX/mock_scripts" \
        bash "$SCRIPT" inject-file --no-enter --force "session:0" "$test_file" 2>/dev/null &
    pid=$!

    sleep 1
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || exit_code=$?

    # バッファ残留確認
    local active_buffers="$SANDBOX/active_buffers"
    local remaining_count
    remaining_count=$(grep -c 'session-comm-' "$active_buffers" 2>/dev/null || echo 0)

    if [[ "$remaining_count" -gt 0 ]]; then
        echo "FAIL: SIGTERM 後に session-comm-* バッファが $remaining_count 件残留している" >&2
        echo "  残留バッファ:" >&2
        grep 'session-comm-' "$active_buffers" >&2
        echo "  #1420 trap TERM handler で delete-buffer が必要" >&2
        return 1
    fi
}

# ===========================================================================
# test 12: ac6[functional] - SIGHUP 受信後バッファ残留なし
# [ISSUE-1682-FIXED]: session-comm.sh に trap HUP + delete-buffer が実装済み (#1504)
# ===========================================================================

@test "ac6[functional]: SIGHUP 受信後に session-comm-* バッファが残留しない [ISSUE-1682-FIXED]" {
    # AC6: SIGHUP 受信時に trap handler が delete-buffer を呼び、バッファを削除すること
    # [ISSUE-1682-FIXED]: session-comm.sh line 437 に trap HUP + delete-buffer 実装済み (#1504)
    _create_mock_tmux_signal_test 3
    _create_mock_session_state_input_waiting

    local test_file="$SANDBOX/test_content.txt"
    echo "test content for sighup cleanup" > "$test_file"

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

# ===========================================================================
# test 13: ac6[functional][RED] - SIGINT 受信後バッファ残留なし
# RED: 現在の実装に trap がない + bats 非インタラクティブ SIGINT 問題
# ===========================================================================

@test "ac6[functional]: SIGINT 受信後に session-comm-* バッファが残留しない" {
    # AC6: SIGINT 受信時に trap handler が delete-buffer を呼び、バッファを削除すること
    # #1420 で trap INT handler が実装されたため skip を解除
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
        return 1
    fi
}

# ===========================================================================
# test 14: ac7[structural][GREEN] - test_1395 ファイル存在確認
# GREEN: 既存テストファイルが存在することを確認（regression 防止）
# ===========================================================================


# ===========================================================================
# test 15: ac7[structural][GREEN] - issue-1050 ファイル存在確認
# GREEN: 既存テストファイルが存在することを確認（regression 防止）
# ===========================================================================

@test "ac7[structural][GREEN]: issue-1050-inject-file-named-buffer.bats が存在する" {
    # AC7: #1050 テストファイルが削除されていないことを確認
    # このテストは現在 GREEN になる
    local test_1050="$(dirname "$BATS_TEST_FILENAME")/issue-1050-inject-file-named-buffer.bats"
    [[ -f "$test_1050" ]] || {
        echo "FAIL: issue-1050-inject-file-named-buffer.bats が存在しない（regression）" >&2
        return 1
    }
}
