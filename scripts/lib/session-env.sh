#!/usr/bin/env bash
# session-env.sh — namespace / path 解決の SSOT
#
# 各スクリプトが冒頭で source し、state / share ディレクトリ・lock・manifest の
# パスを共有する。すべて環境変数で上書き可能で、デフォルトは中立な
# `claude-session` namespace（特定プロジェクトに依存しない）。
#
# 別プロジェクトに組み込む場合は、呼び出し側で
#   SESSION_STATE_DIR / SESSION_SHARE_DIR 等を export してから起動すれば
# そのプロジェクト固有の namespace に切り替えられる。

SESSION_STATE_DIR="${SESSION_STATE_DIR:-$HOME/.local/state/claude-session}"
SESSION_SHARE_DIR="${SESSION_SHARE_DIR:-$HOME/.local/share/claude-session}"
WINDOW_MANIFEST_FILE="${WINDOW_MANIFEST_FILE:-$SESSION_SHARE_DIR/window-manifest.json}"
SESSION_LOCK_FILE="${SESSION_LOCK_FILE:-$SESSION_STATE_DIR/window-create.lock}"
SESSION_MAP_DIR="${SESSION_MAP_DIR:-$SESSION_STATE_DIR}"

export SESSION_STATE_DIR SESSION_SHARE_DIR WINDOW_MANIFEST_FILE SESSION_LOCK_FILE SESSION_MAP_DIR

# =============================================================================
# ready-compaction: Working Memory（compaction 跨ぎの作業状態退避）パス群
# =============================================================================
# 上の window 状態系（$HOME 配下の namespace）とは性質が異なる。Working Memory は
# 「その作業ディレクトリ固有の会話状態」なので、既定でプロジェクトローカル
# （$PWD 直下の中立名ディレクトリ）に置く。すべて環境変数で上書き可能。
#   - WORKING_MEMORY_DIR           退避ディレクトリ（既定 $PWD/.claude-session）
#   - WORKING_MEMORY_FILE          退避ファイル本体
#   - WORKING_MEMORY_CONSUMED_FILE 復元後の consumed マーク先（削除せず mv）
#   - COMPACTION_ENABLED_MARKER    opt-in マーカー（存在するプロジェクトでのみ hook 発火）
#   - COMPACTION_LOG_FILE          compaction イベントの追記ログ
#
# session-scoped 化（un-gcu）: cwd=anchor の複数セッションが同一退避ファイルを
# 奪い合う衝突（2026-06-09 実害）を構造的に根絶するため、退避ファイル名に
# session id を含める。session id の解決順は WM_SESSION_ID（hook が stdin の
# .session_id から設定／test override）> CLAUDE_CODE_SESSION_ID（bash tool / hook
# 継承 env）> 空。非空なら scoped 名（working-memory.<sid>.md）、空（解決不能 or
# slug 後空）なら legacy 非 scoped 名（working-memory.md）へフォールバックする
# （非 Claude Code 文脈・明示 override のための後方互換）。
#   - marker / log は session-scoped にしない: opt-in はプロジェクト単位の共有概念。
#   - 既存 legacy ファイルの自動移行はしない（coexistence）。移行は 2 セッションが
#     同一 legacy を奪い合う衝突を再導入する。退避ファイルは lifecycle=temporary
#     （1 effort スコープ）なので、upgrade 直後の旧ファイル orphan は最大 1 サイクルの
#     carry-forward 損失で自己回復する。設計根拠は architecture/compaction-memory-model.md。
WORKING_MEMORY_DIR="${WORKING_MEMORY_DIR:-$PWD/.claude-session}"

# --- session id 解決＋slug 化（pure-bash・subprocess 不使用） ---
# slug: [A-Za-z0-9-] 以外を除去（`..` / `/` を構造排除＝path traversal 不能）し 64 文字上限。
_wm_sid="${WM_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
_wm_sid="${_wm_sid//[^A-Za-z0-9-]/}"
_wm_sid="${_wm_sid:0:64}"
if [ -n "$_wm_sid" ]; then
    _wm_default_file="$WORKING_MEMORY_DIR/working-memory.$_wm_sid.md"
    _wm_default_consumed="$WORKING_MEMORY_DIR/working-memory.$_wm_sid.consumed.md"
else
    _wm_default_file="$WORKING_MEMORY_DIR/working-memory.md"
    _wm_default_consumed="$WORKING_MEMORY_DIR/working-memory.consumed.md"
fi

WORKING_MEMORY_FILE="${WORKING_MEMORY_FILE:-$_wm_default_file}"
WORKING_MEMORY_CONSUMED_FILE="${WORKING_MEMORY_CONSUMED_FILE:-$_wm_default_consumed}"
COMPACTION_ENABLED_MARKER="${COMPACTION_ENABLED_MARKER:-$WORKING_MEMORY_DIR/.compaction-enabled}"
COMPACTION_LOG_FILE="${COMPACTION_LOG_FILE:-$WORKING_MEMORY_DIR/compaction-log.txt}"
# 解決済み session id を可観測性のため export（空＝legacy 非 scoped 経路）
WORKING_MEMORY_SESSION_ID="$_wm_sid"
unset _wm_sid _wm_default_file _wm_default_consumed

export WORKING_MEMORY_DIR WORKING_MEMORY_FILE WORKING_MEMORY_CONSUMED_FILE
export COMPACTION_ENABLED_MARKER COMPACTION_LOG_FILE WORKING_MEMORY_SESSION_ID

# =============================================================================
# ready-compaction Phase-2: hard 強制（enforce）policy / marker パス群
# =============================================================================
# Working Memory と同じくプロジェクトローカル（$PWD/.claude-session 配下）。
# policy ファイルの存在が opt-in（不在/空 → hook は no-op=allow）。環境変数で上書き可能。
#   - ENFORCE_POLICY_FILE  人間が ratify した gate 定義（/session:enforce が生成）
#   - ENFORCE_MARKER_DIR   操作インスタンス marker の格納先（unlock helper が生シェルで touch）
#   - ENFORCE_SHA_TIMEOUT  sha_keyed gate の SHA 導出 1 呼び出しあたりの上限秒（block 経路限定）
ENFORCE_POLICY_FILE="${ENFORCE_POLICY_FILE:-$WORKING_MEMORY_DIR/enforce-policy.json}"
ENFORCE_MARKER_DIR="${ENFORCE_MARKER_DIR:-$WORKING_MEMORY_DIR/enforce-markers}"
ENFORCE_SHA_TIMEOUT="${ENFORCE_SHA_TIMEOUT:-5}"

export ENFORCE_POLICY_FILE ENFORCE_MARKER_DIR ENFORCE_SHA_TIMEOUT
