#!/usr/bin/env bash
# enforce-policy.sh — hard 強制（enforce）policy フォーマット/マッチ/marker 導出の SSOT
#
# ready-compaction Phase-2 の「hard 強制層」の中核ライブラリ。
# PreToolUse(Bash) hook（scripts/hooks/pretooluse-enforce.sh）と unlock helper（enforce-unlock）の
# 両方がこれを source し、**同一の marker 名導出**へ収束する（hook が探す名前と人間が作る名前の
# ドリフトを原理的にゼロにする）。設計根拠は architecture/ready-compaction-redesign.md §9.6。
#
# 設計方針:
#   - 純関数中心・副作用なし・stdout 生成（多重 source ガード付き）。
#   - marker は **読み取り判定のみ**（stat）。**作成するコードパスを持たない**（C-4b: 認可は人間の
#     生シェルだけ＝LLM が自己認可できないことが hard 性の実体）。
#   - 外部コマンド（gh 等）は ep_marker_sha_suffix だけに隔離。hook は「sha_keyed gate に一致し
#     かつ marker 不在で block 経路に入ったとき」だけ呼ぶ（低遅延 PreToolUse の現実）。
#   - 判定不能（jq 不在 / JSON 破損 / version 超過 / SHA 導出失敗 / subject 不明）は **fail-closed**
#     に倒す（allow にしない）。強制の縮退規約は C-6（scoped）。
#   - コマンドマッチの誤爆対策は git-destructive-guard.sh 流儀（tr -s 空白正規化 + # 以降除去）を踏襲。

[ -n "${_ENFORCE_POLICY_SH_SOURCED:-}" ] && return 0
_ENFORCE_POLICY_SH_SOURCED=1

# パス SSOT（ENFORCE_POLICY_FILE / ENFORCE_MARKER_DIR / ENFORCE_SHA_TIMEOUT）を連鎖 source。
_EP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./session-env.sh
source "$_EP_LIB_DIR/session-env.sh" 2>/dev/null || true
# session-env.sh だけが欠落しても set -u 下で unbound にならぬよう安全デフォルトへ再フォールバック
# （これが無いと health が空出力 → hook の case 素通り → 危険操作 allow という fail-open になる）。
: "${WORKING_MEMORY_DIR:=$PWD/.claude-session}"
: "${ENFORCE_POLICY_FILE:=$WORKING_MEMORY_DIR/enforce-policy.json}"
: "${ENFORCE_MARKER_DIR:=$WORKING_MEMORY_DIR/enforce-markers}"
: "${ENFORCE_SHA_TIMEOUT:=5}"
export WORKING_MEMORY_DIR ENFORCE_POLICY_FILE ENFORCE_MARKER_DIR ENFORCE_SHA_TIMEOUT

# --- SSOT 定数（export） ---
# lib が解釈できる最大 policy version。これを超える version は badversion → fail-closed。
ENFORCE_POLICY_VERSION_MAX=1
# C-6 内蔵 danger list（policy 非依存・純 ERE）。policy 読込不能時の scoped fail-closed で使う。
# policy 例の gate 語彙（pr-merge / git-push / deploy）と同期させること（tests で回帰検出）。
# 境界は (^|[^[:alnum:]_-]) … ([^[:alnum:]_-]|$) ＝ 絶対パス(/usr/bin/gh)・引用符ラップ('terraform apply')・
# 区切り(;・&&)前置でも捕捉。( +[^ ]+)* で間のフラグ/サブコマンド(git -C / kubectl --context)を吸収する。
ENFORCE_BUILTIN_DANGER_REGEX='(^|[^[:alnum:]_-])gh( +[^ ]+)* +pr +merge([^[:alnum:]_-]|$)|(^|[^[:alnum:]_-])git( +[^ ]+)* +push([^[:alnum:]_-]|$)|(^|[^[:alnum:]_-])git( +[^ ]+)* +merge([^[:alnum:]_-]|$)|(^|[^[:alnum:]_-])(kubectl|helm)( +[^ ]+)* +(apply|install|upgrade)([^[:alnum:]_-]|$)|(^|[^[:alnum:]_-])terraform( +[^ ]+)* +apply([^[:alnum:]_-]|$)|(^|[^[:alnum:]_-])serverless( +[^ ]+)* +deploy([^[:alnum:]_-]|$)'
export ENFORCE_POLICY_VERSION_MAX ENFORCE_BUILTIN_DANGER_REGEX

# ep_policy_file
#   stdout: policy ファイルの解決パス。exit 0。パス参照の唯一の入口。
ep_policy_file() { printf '%s' "$ENFORCE_POLICY_FILE"; }

# ep_policy_health
#   stdout 1 語: absent | off | active | corrupt | nojq | badversion。exit 0。
#     absent     = ファイル不在 or 空（C-5 opt-in 不成立 → allow）
#     off        = enforce != true（policy 在りでも明示無効化 → allow）
#     active     = 正常稼働
#     corrupt    = JSON 不正 / schema 不一致 / gate id 不正（→ fail-closed scoped）
#     nojq       = jq 不在（→ fail-closed scoped）
#     badversion = version > VERSION_MAX（→ fail-closed scoped）
#   hook はこの 1 語で step1/step5 を分岐する。jq は 1 回だけ呼ぶ（hot path 配慮）。
ep_policy_health() {
    local f="$ENFORCE_POLICY_FILE"
    [ -s "$f" ] || { echo absent; return 0; }
    command -v jq >/dev/null 2>&1 || { echo nojq; return 0; }
    local probe
    probe=$(jq -r '
        if (.schema != "cc-session/enforce-policy") then "corrupt"
        elif ((.version // 0) | type) != "number" then "corrupt"
        elif ((.gates // []) | map(.id) | any(. == null or (test("^[a-z0-9-]+$") | not))) then "corrupt"
        elif ((.version // 0) > '"$ENFORCE_POLICY_VERSION_MAX"') then "badversion"
        elif (.enforce != true) then "off"
        else "active" end
    ' "$f" 2>/dev/null) || { echo corrupt; return 0; }
    [ -n "$probe" ] || { echo corrupt; return 0; }
    if [ "$probe" = "active" ]; then
        # 全 gate の ERE（any_re / subject_re / sha_validate_re）が実際にコンパイルできるか検証する。
        # 無効 ERE は [[ =~ ]] で決して真にならず gate が「黙って無効化」され危険操作を allow に倒す。
        # これを corrupt 化して C-6（builtin danger への scoped fail-closed）へ落とす。
        local re
        while IFS= read -r re; do
            [ -z "$re" ] && continue
            # ★検証は実マッチと同一エンジン（bash [[ =~ ]]）で行う。grep -qE とは ERE 方言が異なり
            #   先頭量化子 `*x` 等で発散する（grep は valid 扱い→gate が黙って失効する fail-open）。
            #   bash の =~ はコンパイル不能を rc=2 で返すので、それを corrupt 判定に使う。
            ( [[ "probe" =~ $re ]] ) 2>/dev/null
            [ $? -eq 2 ] && { echo corrupt; return 0; }
        done < <(jq -r '.gates[]? | (.match.any_re[]?, .key.subject_re[]?, (.key.sha_validate_re // empty))' "$f" 2>/dev/null)
    fi
    echo "$probe"
}

# ep_normalize <raw_command>
#   stdout: 空白正規化（tr -s '[:space:]' ' '＝タブ・連続スペース・改行を単一スペースへ）した文字列。exit 0。
#   ★コメント（# 以降）は **除去しない**。git-destructive-guard.sh の危険判定が NORM＝コメント保持で
#   行うのに倣う。除去すると `echo "#" && git push` のように先頭 `#` 以降の実コマンド（&&/;/改行で実行
#   される push/merge/deploy）を判定文字列から落とし、marker 不要・自己認可不要で全 gate を 1 文字で
#   回避できてしまう（fail-open）。保持側に倒すと `ls # gh pr merge` 等を過剰 block しうるが安全側。
ep_normalize() {
    local s
    # クォート/エスケープ難読化の de-obfuscate: " ' \ を除去（g'i't push → git push 等を捕捉）。
    s=$(printf '%s' "$1" | tr -d '\042\047\134')
    # 語分割難読化対策: ${IFS} / $IFS をスペースへ（git${IFS}push → git push）。
    s=${s//\$\{IFS\}/ }
    s=${s//\$IFS/ }
    printf '%s' "$s" | tr -s '[:space:]' ' '
    # 注意（残存・脅威モデル外）: 変数間接 `m=push; git $m` やコマンド置換 $(...) は実行なしには
    # 解決できず本マッチャでは捕捉できない。これはグローバル git-destructive-guard.sh と共通の
    # regex-on-command-string の原理的限界で、本層は「沈黙の・偶発的な自己認可の防止」を目的とする
    # （決然と回避する LLM は脅威モデル外＝§9.6 C-4b・§9.7 参照）。
}

# ep_match_gate <normalized_command>
#   全 gate を順に評価し、最初に一致した gate id を stdout + exit 0。一致無し → 空 + exit 1。
#   一致条件: match.all（全トークンが部分一致＝AND）かつ match.any_re（いずれかの ERE が一致＝OR。
#   any_re が無ければ all のみで判定）。jq は 1 回だけ呼び、結果を bash 側でストリーム評価する。
ep_match_gate() {
    local norm="$1"
    local gid="" all_ok=1 any_present=0 any_ok=0
    _ep_gate_hits() { [ -n "$gid" ] && [ "$all_ok" -eq 1 ] && { [ "$any_present" -eq 0 ] || [ "$any_ok" -eq 1 ]; }; }
    local kind val
    while IFS=$'\t' read -r kind val; do
        case "$kind" in
            GATE)
                if _ep_gate_hits; then printf '%s' "$gid"; unset -f _ep_gate_hits; return 0; fi
                gid="$val"; all_ok=1; any_present=0; any_ok=0 ;;
            ALL)
                case "$norm" in *"$val"*) ;; *) all_ok=0 ;; esac ;;
            ANY)
                any_present=1
                if [ "$any_ok" -eq 0 ] && [[ "$norm" =~ $val ]]; then any_ok=1; fi ;;
        esac
    done < <(jq -r '.gates[] | "GATE\t\(.id)", (.match.all[]? | "ALL\t\(.)"), (.match.any_re[]? | "ANY\t\(.)")' "$ENFORCE_POLICY_FILE" 2>/dev/null)
    if _ep_gate_hits; then printf '%s' "$gid"; unset -f _ep_gate_hits; return 0; fi
    unset -f _ep_gate_hits
    return 1
}

# ep_gate_field <gate_id> <jq_path>
#   指定 gate の任意フィールドを stdout（例 .description / .key.sha_keyed）。値が空/null なら空。
#   jq_path は lib 内部からのみ渡る（ユーザー入力ではない）ため文字列補間で安全。
ep_gate_field() {
    local gid="$1" path="$2"
    jq -r --arg id "$gid" ".gates[] | select(.id==\$id) | ($path) // empty" "$ENFORCE_POLICY_FILE" 2>/dev/null
}

# _ep_slug <text>  marker 名に使える安全形へ（英数 . _ - のみ残し、他は - に。連続 - を圧縮し端を除去）
_ep_slug() {
    printf '%s' "$1" | LC_ALL=C tr -c '[:alnum:]._-' '-' | tr -s '-' | sed 's/^-//; s/-$//'
}

# _ep_cmd_hash <normalized_command>  正規化コマンド全体の sha256 先頭 8 文字
_ep_cmd_hash() {
    printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-8
}

# ep_extract_subject <gate_id> <normalized_command>
#   key.subject_re（ERE・capture group 1 が対象）を順に試し、最初にマッチした group 1 を stdout。
#   全滅時は key.subject_fallback を適用:
#     deny（既定）  → 何も出さず exit 4（hook が必ず block を維持＝危険操作を黙って通さない）
#     literal:<s>   → <s> を stdout + exit 0
#     command-hash  → 正規化コマンドの sha8 を stdout + exit 0
#   外部コマンドは呼ばない。
ep_extract_subject() {
    local gid="$1" norm="$2" re sub
    while IFS= read -r re; do
        [ -z "$re" ] && continue
        if [[ "$norm" =~ $re ]] && [ -n "${BASH_REMATCH[1]:-}" ]; then
            printf '%s' "${BASH_REMATCH[1]}"; return 0
        fi
    done < <(ep_gate_field "$gid" '.key.subject_re[]?')
    local fb
    fb=$(ep_gate_field "$gid" '.key.subject_fallback')
    case "$fb" in
        ''|deny)       return 4 ;;
        literal:*)     printf '%s' "${fb#literal:}"; return 0 ;;
        command-hash)  _ep_cmd_hash "$norm"; return 0 ;;
        *)             return 4 ;;
    esac
}

# ep_marker_base <gate_id> <normalized_command>
#   SHA 抜きの決定論部分を stdout。strategy で分岐:
#     token        → "<gate_id>-<subject_prefix>-<slug(subject)>"
#     command-hash → "<gate_id>-<subject_prefix>-<sha8(normalized)>"
#   subject が deny のとき exit 4（fail-closed トリガ）。外部コマンドは呼ばない。
ep_marker_base() {
    local gid="$1" norm="$2" strategy prefix subject
    strategy=$(ep_gate_field "$gid" '.key.strategy')
    prefix=$(ep_gate_field "$gid" '.key.subject_prefix')
    case "$strategy" in
        command-hash)
            subject=$(_ep_cmd_hash "$norm") ;;
        token|'')
            subject=$(ep_extract_subject "$gid" "$norm") || return 4
            subject=$(_ep_slug "$subject") ;;
        *) return 4 ;;
    esac
    printf '%s-%s-%s' "$gid" "$prefix" "$subject"
}

# ep_marker_sha_suffix <gate_id> <raw_subject>
#   key.sha_keyed=false/未設定 → 空文字 + exit 0（外部コマンドを呼ばない＝軽量経路）。
#   key.sha_keyed=true         → key.sha_cmd の {subject} を検証済み raw_subject で置換し、
#     timeout ${ENFORCE_SHA_TIMEOUT}s で argv 実行（eval 不使用＝injection 回避）。出力を
#     sha_validate_re で検証し、先頭 sha_len 文字を "-sha-<n>" として stdout + exit 0。
#   導出失敗（コマンド不在 / timeout / 非0終了 / 空 / validate 不一致 / subject 不正）→ 空 + exit 3。
#   ★外部コマンドはこの関数だけに隔離する。
ep_marker_sha_suffix() {
    local gid="$1" subject="$2" sha_keyed
    sha_keyed=$(ep_gate_field "$gid" '.key.sha_keyed')
    [ "$sha_keyed" = "true" ] || { printf ''; return 0; }
    # argv に埋め込む subject を検証（shell/argv injection 面の縮小。先頭ダッシュ禁止＝option-injection 抑止）
    printf '%s' "$subject" | grep -qE '^[0-9A-Za-z._/][0-9A-Za-z._/-]*$' || return 3
    local -a argv=()
    local part
    while IFS= read -r part; do
        argv+=("${part//\{subject\}/$subject}")
    done < <(ep_gate_field "$gid" '.key.sha_cmd[]?')
    [ "${#argv[@]}" -gt 0 ] || return 3
    local out
    out=$(timeout "${ENFORCE_SHA_TIMEOUT:-5}" "${argv[@]}" 2>/dev/null) || return 3
    out=$(printf '%s' "$out" | head -n1)
    [ -n "$out" ] || return 3
    local vre slen
    vre=$(ep_gate_field "$gid" '.key.sha_validate_re')
    if [ -n "$vre" ] && ! [[ "$out" =~ $vre ]]; then return 3; fi
    slen=$(ep_gate_field "$gid" '.key.sha_len')
    case "$slen" in ''|*[!0-9]*) slen=8 ;; esac
    printf -- '-sha-%s' "$(printf '%s' "$out" | cut -c1-"$slen")"
}

# ep_marker_name <gate_id> <normalized_command>
#   最終 marker 名（base + sha_suffix）を stdout。
#   exit 0=成功 / 4=subject deny(fail-closed) / 3=SHA 導出不能(fail-closed)。
#   ★hook（block 判定時）と unlock helper（marker 作成時）が共にこれを呼ぶ＝同名再計算を保証。
ep_marker_name() {
    local gid="$1" norm="$2" base subject suffix rc
    base=$(ep_marker_base "$gid" "$norm"); rc=$?
    [ "$rc" -ne 0 ] && return "$rc"
    subject=$(ep_extract_subject "$gid" "$norm" 2>/dev/null) || subject=""
    suffix=$(ep_marker_sha_suffix "$gid" "$subject"); rc=$?
    [ "$rc" -eq 3 ] && return 3
    printf '%s%s' "$base" "$suffix"
}

# ep_marker_path <marker_name>  marker の絶対パスを stdout
ep_marker_path() { printf '%s/%s' "$ENFORCE_MARKER_DIR" "$1"; }

# ep_gate_ttl <gate_id>
#   有効 TTL 秒を stdout（gate.marker_ttl_sec → default_marker_ttl_sec の順。無ければ空＝無期限）。
ep_gate_ttl() {
    local gid="$1" ttl
    ttl=$(ep_gate_field "$gid" '.marker_ttl_sec')
    if [ -z "$ttl" ]; then
        ttl=$(jq -r '.default_marker_ttl_sec // empty' "$ENFORCE_POLICY_FILE" 2>/dev/null)
    fi
    case "$ttl" in ''|null|*[!0-9]*) printf ''; return 0 ;; esac
    printf '%s' "$ttl"
}

# ep_marker_valid <gate_id> <marker_name>
#   marker が存在し、かつ（TTL 設定時）mtime+ttl >= now なら exit 0、else exit 1。
#   読み取りのみ（作成しない）。期限切れ marker は exit 1（block 相当）。
ep_marker_valid() {
    local gid="$1" name="$2" path ttl now mtime
    path="$ENFORCE_MARKER_DIR/$name"
    [ -e "$path" ] || return 1
    ttl=$(ep_gate_ttl "$gid")
    [ -z "$ttl" ] && return 0
    mtime=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null) || return 1
    [ -n "$mtime" ] || return 1   # mtime 取得不能なら TTL を確認できない → 安全側で block（fail-closed）
    now=$(date +%s)
    [ $((mtime + ttl)) -ge "$now" ]
}

# ep_unlock_command <marker_name>
#   人間が生シェルで叩く実コマンド 1 行（marker を作成）を stdout。lib 自身は touch しない（C-4b）。
ep_unlock_command() {
    printf 'mkdir -p %q && touch %q' "$ENFORCE_MARKER_DIR" "$ENFORCE_MARKER_DIR/$1"
}

# ep_block_message <gate_id> <normalized_command> <marker_name>
#   hook が stderr に流す完成済みブロック文を stdout（description + {subject} 展開した unlock_hint +
#   人間が叩く unlock コマンド + Claude 自己認可不可の注記）。
ep_block_message() {
    local gid="$1" norm="$2" name="$3" desc hint subject
    desc=$(ep_gate_field "$gid" '.description')
    hint=$(ep_gate_field "$gid" '.unlock_hint')
    subject=$(ep_extract_subject "$gid" "$norm" 2>/dev/null) || subject=""
    hint="${hint//"{subject}"/$subject}"
    printf 'DENIED(enforce/%s): %s\n' "$gid" "$desc"
    [ -n "$hint" ] && printf '  %s\n' "$hint"
    printf '  この操作はレビュー gate 未通過です。Claude は自己認可できません（C-4b）。\n'
    printf '  承認する人間が次を生シェルで実行してください（! プレフィックス）:\n'
    printf '    %s\n' "$(ep_unlock_command "$name")"
}

# ep_builtin_danger_match <normalized_command>
#   ENFORCE_BUILTIN_DANGER_REGEX に一致すれば exit 0（block 対象）、else exit 1。
#   policy を読まずに評価できる（policy 破損時の C-6 fail-closed scoped 用）。
ep_builtin_danger_match() {
    [[ "$1" =~ $ENFORCE_BUILTIN_DANGER_REGEX ]]
}
