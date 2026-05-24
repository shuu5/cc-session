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
WORKING_MEMORY_DIR="${WORKING_MEMORY_DIR:-$PWD/.claude-session}"
WORKING_MEMORY_FILE="${WORKING_MEMORY_FILE:-$WORKING_MEMORY_DIR/working-memory.md}"
WORKING_MEMORY_CONSUMED_FILE="${WORKING_MEMORY_CONSUMED_FILE:-$WORKING_MEMORY_DIR/working-memory.consumed.md}"
COMPACTION_ENABLED_MARKER="${COMPACTION_ENABLED_MARKER:-$WORKING_MEMORY_DIR/.compaction-enabled}"
COMPACTION_LOG_FILE="${COMPACTION_LOG_FILE:-$WORKING_MEMORY_DIR/compaction-log.txt}"

export WORKING_MEMORY_DIR WORKING_MEMORY_FILE WORKING_MEMORY_CONSUMED_FILE
export COMPACTION_ENABLED_MARKER COMPACTION_LOG_FILE
