#!/usr/bin/env bats
# spawn-bd-id-naming.bats — bd id 連動 spawn 命名（session-name.sh）の unit tests
#
# 対象関数: normalize_bd_id / extract_bd_id / spawn_branch_name / spawn_window_name
# 契約（un-cbi）:
#   - un-xxx 形式 id → worktree=spawn/<id>-<HHMMSS>・window=wt-<id>
#   - #123 数値形式  → wt-123（既存挙動と整合）・spawn/123-<HHMMSS>
#   - id 無し        → 現行フォールバック spawn/<HHMMSS>-<pid>・window 空（呼出側委譲）
#   - -<HHMMSS> 衝突回避サフィックスは維持
#   - 生成名が consumer（fleet-monitor.sh）の完全一致照合で復元できること
# 依存: bats-core のみ
# ---------------------------------------------------------------------------

SESSION_NAME_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)/session-name.sh"

setup() {
  source "$SESSION_NAME_SH"
}

# fleet-monitor.sh の候補 id 抽出規約を再現するヘルパー（consumer 側ロジックの写し）。
#   - window 名:  wt-<id>            → "wt-" を剥がす
#   - worktree:   spawn/<id>-<HHMMSS> 最終セグメント → 末尾 -<数字> を剥がす
# producer が生成した名前から in_progress id を復元できるかの突合に使う。
_consumer_id_from_window() {
  local win="$1"
  [[ "$win" == wt-* ]] || { printf ''; return 0; }
  printf '%s' "${win#wt-}"
}
_consumer_id_from_worktree() {
  # branch/worktree パス（例 spawn/un-cbi-221212）の最終セグメントから末尾 -<数字> を剥がす
  local path="$1" base
  base="${path##*/}"
  printf '%s' "$(sed -E 's/-[0-9]+$//' <<<"$base")"
}

# ---------------------------------------------------------------------------
# normalize_bd_id
# ---------------------------------------------------------------------------

@test "normalize_bd_id: un-cbi はそのまま" {
  run normalize_bd_id "un-cbi"
  [ "$status" -eq 0 ]
  [ "$output" = "un-cbi" ]
}

@test "normalize_bd_id: #123 は先頭 # を剥がして 123" {
  run normalize_bd_id "#123"
  [ "$status" -eq 0 ]
  [ "$output" = "123" ]
}

@test "normalize_bd_id: 前後空白を除去する" {
  run normalize_bd_id "  un-cbi  "
  [ "$status" -eq 0 ]
  [ "$output" = "un-cbi" ]
}

@test "normalize_bd_id: スラッシュを含む id は拒否（path traversal 防止）" {
  run normalize_bd_id "../evil"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "normalize_bd_id: 'a/b' のような path separator を含む id は拒否" {
  run normalize_bd_id "a/b"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "normalize_bd_id: '..' を含む id は拒否（path traversal）" {
  run normalize_bd_id "un-3sh..3"
  [ "$status" -ne 0 ]
}

# 階層 dotted bd id（consumer が完全一致で復元できるため producer も通す）
@test "normalize_bd_id: dotted id un-3sh.3 は許容（内部 '.' は traversal でない）" {
  run normalize_bd_id "un-3sh.3"
  [ "$status" -eq 0 ]
  [ "$output" = "un-3sh.3" ]
}

@test "normalize_bd_id: 多段 dotted id un-3sh.3.2 は許容" {
  run normalize_bd_id "un-3sh.3.2"
  [ "$status" -eq 0 ]
  [ "$output" = "un-3sh.3.2" ]
}

@test "normalize_bd_id: 単純な 'a.b' は許容（traversal ではない）" {
  run normalize_bd_id "a.b"
  [ "$status" -eq 0 ]
  [ "$output" = "a.b" ]
}

@test "normalize_bd_id: 空文字は拒否" {
  run normalize_bd_id ""
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# extract_bd_id
# ---------------------------------------------------------------------------

@test "extract_bd_id: un-xxx 形式をプロンプトから抽出" {
  run extract_bd_id "Worker cell: un-cbi — spawn naming に追従せよ"
  [ "$status" -eq 0 ]
  [ "$output" = "un-cbi" ]
}

@test "extract_bd_id: #123 数値形式を抽出し # を剥がす" {
  run extract_bd_id "fix/issue-291 の #291 を直して"
  [ "$status" -eq 0 ]
  [ "$output" = "291" ]
}

@test "extract_bd_id: #123 は un-xxx より優先される（明示 issue 参照）" {
  run extract_bd_id "un-cbi に関連する #42 を見て"
  [ "$status" -eq 0 ]
  [ "$output" = "42" ]
}

@test "extract_bd_id: id が無ければ非ゼロ終了・空文字" {
  run extract_bd_id "ただのプロンプト本文 with no identifier"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "extract_bd_id: glob 文字を含んでも安全（クラッシュしない）" {
  run extract_bd_id "rm -rf * and un-cbi here"
  [ "$status" -eq 0 ]
  [ "$output" = "un-cbi" ]
}

# dotted 階層 id は '.' 込みで丸ごと捕捉する（'un-3sh' に誤切詰めしない）
@test "extract_bd_id: アンカー付き dotted id を丸ごと抽出（cell: un-3sh.3）" {
  run extract_bd_id "Worker cell: un-3sh.3 — spawn naming に追従せよ"
  [ "$status" -eq 0 ]
  [ "$output" = "un-3sh.3" ]
}

@test "extract_bd_id: bare dotted id un-3sh.3.2 を丸ごと抽出（誤切詰めしない）" {
  run extract_bd_id "un-3sh.3.2 を直して"
  [ "$status" -eq 0 ]
  [ "$output" = "un-3sh.3.2" ]
}

# 明示アンカー優先 — hyphenated 英単語より id を優先する
@test "extract_bd_id: アンカー直後の id を優先（read-only より cell: の id）" {
  run extract_bd_id "use read-only mode for cell: un-cbi please"
  [ "$status" -eq 0 ]
  [ "$output" = "un-cbi" ]
}

# hyphenated 英単語のみのプロンプトは id を返さない（誤検出防止）
@test "extract_bd_id: 'use read-only mode' は id を返さない" {
  run extract_bd_id "use read-only mode"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "extract_bd_id: 'fix the multi-line bug' は id を返さない" {
  run extract_bd_id "fix the multi-line bug"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# 文末句読点を id に取り込まない（wt-un-cbi. ≠ bd id un-cbi の consumer 不一致を防ぐ）
@test "extract_bd_id: 文末ピリオドを剥がす（see un-cbi. → un-cbi）" {
  run extract_bd_id "see un-cbi."
  [ "$status" -eq 0 ]
  [ "$output" = "un-cbi" ]
}

@test "extract_bd_id: アンカー付き id の文末読点を剥がす（cell: un-3sh.3, → un-3sh.3）" {
  run extract_bd_id "cell: un-3sh.3, do the thing"
  [ "$status" -eq 0 ]
  [ "$output" = "un-3sh.3" ]
}

@test "extract_bd_id: #123 の文末ピリオドを剥がす（… #291. → 291）" {
  run extract_bd_id "やって #291."
  [ "$status" -eq 0 ]
  [ "$output" = "291" ]
}

@test "extract_bd_id: dotted id は最終セグメントが英数なので保持（un-3sh.3 → un-3sh.3）" {
  run extract_bd_id "cell: un-3sh.3 done"
  [ "$status" -eq 0 ]
  [ "$output" = "un-3sh.3" ]
}

# ---------------------------------------------------------------------------
# spawn_branch_name
# ---------------------------------------------------------------------------

@test "spawn_branch_name: un-cbi → spawn/un-cbi-<HHMMSS>（HHMMSS 注入）" {
  run spawn_branch_name "un-cbi" "221212"
  [ "$status" -eq 0 ]
  [ "$output" = "spawn/un-cbi-221212" ]
}

@test "spawn_branch_name: #123 → spawn/123-<HHMMSS>（# 正規化）" {
  run spawn_branch_name "#123" "221212"
  [ "$status" -eq 0 ]
  [ "$output" = "spawn/123-221212" ]
}

@test "spawn_branch_name: id 無し → 現行フォールバック spawn/<HHMMSS>-<pid>" {
  run spawn_branch_name "" "221212" "99999"
  [ "$status" -eq 0 ]
  [ "$output" = "spawn/221212-99999" ]
}

@test "spawn_branch_name: 無効 id（スラッシュ）はフォールバックへ退避" {
  run spawn_branch_name "../evil" "221212" "99999"
  [ "$status" -eq 0 ]
  [ "$output" = "spawn/221212-99999" ]
}

@test "spawn_branch_name: HHMMSS サフィックスが常に末尾に付く（衝突回避維持）" {
  run spawn_branch_name "un-cbi" "010203"
  [ "$status" -eq 0 ]
  [[ "$output" =~ -010203$ ]]
}

@test "spawn_branch_name: HHMMSS 未指定でも spawn/<id>-<digits> 形になる" {
  run spawn_branch_name "un-cbi"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^spawn/un-cbi-[0-9]{6}$ ]]
}

@test "spawn_branch_name: dotted id un-3sh.3 → spawn/un-3sh.3-<HHMMSS>" {
  run spawn_branch_name "un-3sh.3" "221212"
  [ "$status" -eq 0 ]
  [ "$output" = "spawn/un-3sh.3-221212" ]
}

# ---------------------------------------------------------------------------
# spawn_window_name
# ---------------------------------------------------------------------------

@test "spawn_window_name: un-cbi → wt-un-cbi" {
  run spawn_window_name "un-cbi"
  [ "$status" -eq 0 ]
  [ "$output" = "wt-un-cbi" ]
}

@test "spawn_window_name: #123 → wt-123（既存挙動と整合）" {
  run spawn_window_name "#123"
  [ "$status" -eq 0 ]
  [ "$output" = "wt-123" ]
}

@test "spawn_window_name: id 無し → 空文字（呼出側フォールバックへ委譲）" {
  run spawn_window_name ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spawn_window_name: 無効 id → 空文字（委譲）" {
  run spawn_window_name "a/b"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spawn_window_name: dotted id un-3sh.3 → wt-un-3sh.3" {
  run spawn_window_name "un-3sh.3"
  [ "$status" -eq 0 ]
  [ "$output" = "wt-un-3sh.3" ]
}

# ---------------------------------------------------------------------------
# consumer（fleet-monitor.sh）との突合 — 完全一致照合で id を復元できること
# ---------------------------------------------------------------------------

@test "consumer 突合: un-cbi の window 名から id を完全一致で復元" {
  local win
  win=$(spawn_window_name "un-cbi")
  [ "$(_consumer_id_from_window "$win")" = "un-cbi" ]
}

@test "consumer 突合: un-cbi の worktree パスから id を完全一致で復元" {
  local branch
  branch=$(spawn_branch_name "un-cbi" "221212")
  # 実 worktree パス（ANCHOR/.worktrees/<branch>）を模す
  local path="/home/x/.worktrees/${branch}"
  [ "$(_consumer_id_from_worktree "$path")" = "un-cbi" ]
}

@test "consumer 突合: #123 の window/worktree いずれからも 123 を復元" {
  local win branch path
  win=$(spawn_window_name "#123")
  branch=$(spawn_branch_name "#123" "221212")
  path="/home/x/.worktrees/${branch}"
  [ "$(_consumer_id_from_window "$win")" = "123" ]
  [ "$(_consumer_id_from_worktree "$path")" = "123" ]
}

@test "consumer 突合: dotted id un-3sh.3 が window/worktree いずれからも完全一致で復元" {
  local win branch path
  win=$(spawn_window_name "un-3sh.3")
  branch=$(spawn_branch_name "un-3sh.3" "221212")
  path="/home/x/.worktrees/${branch}"
  [ "$win" = "wt-un-3sh.3" ]
  [ "$(_consumer_id_from_window "$win")" = "un-3sh.3" ]
  [ "$(_consumer_id_from_worktree "$path")" = "un-3sh.3" ]
}

@test "consumer 突合: id 無しフォールバックは id を復元しない（under-mark 安全側）" {
  local branch path recovered
  branch=$(spawn_branch_name "" "221212" "99999")   # spawn/221212-99999
  path="/home/x/.worktrees/${branch}"
  recovered=$(_consumer_id_from_worktree "$path")     # 221212（HHMMSS）→ 実 issue id と一致しない
  # フォールバック名から復元される候補は HHMMSS 起因の数値であり、bd issue id とは一致しない設計
  [ "$recovered" = "221212" ]
}
