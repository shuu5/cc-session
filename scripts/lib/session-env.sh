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
