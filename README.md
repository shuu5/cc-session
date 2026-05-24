# cc-session

汎用 Claude Code セッション管理プラグイン。tmux ウィンドウ上の Claude Code セッションを **spawn / observe / fork** し、状態を検出する。

## 機能

| スキル | 説明 |
|--------|------|
| `/session:spawn` | 新しい tmux ウィンドウで Claude Code を起動（コンテキスト非継承、`--worktree` 対応） |
| `/session:observe` | tmux ウィンドウ/ペインの出力をキャプチャし AI 要約（`--loop` で定期監視） |
| `/session:fork` | 現在のセッションを fork（会話履歴を継承して並行実行） |

## インストール

```
/plugin marketplace add shuu5/cc-session
/plugin install session@cc-session
```

private repo の場合は `gh auth login` 済み、または `GITHUB_TOKEN` / `GH_TOKEN` が必要。

## 必要環境

- `tmux`（セッションは tmux ウィンドウ内で動作）
- `claude`（Claude Code CLI）
- `jq`
- `systemd-run`（任意。あればメモリ制限付き scope で起動、無ければ直接起動）

## namespace（環境変数で上書き可能）

状態・ロック・manifest は既定で `~/.local/{state,share}/claude-session/` 配下に作成される。`SESSION_STATE_DIR` / `SESSION_SHARE_DIR` / `WINDOW_MANIFEST_FILE` / `SESSION_LOCK_FILE` で変更できる。詳細は `CLAUDE.md` を参照。

## 高度な使い方: observe daemon の自律再起動

`cld-observe-any-launcher` を SessionStart hook から呼ぶと、observer セッションの crash 後に自動再起動できる（`EVENT_DIR` で event ファイル出力先を指定）。

```jsonc
// ~/.claude/settings.json
{
  "hooks": {
    "SessionStart": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "pgrep -f 'cld-observe-any$' >/dev/null 2>&1 || bash <plugin-dir>/scripts/cld-observe-any-launcher --window <監視ウィンドウ名>"
      }]
    }]
  }
}
```

## セキュリティ注記

`cld` / `cld-spawn` で起動するセッションは自動実行を前提に `claude --dangerously-skip-permissions` で起動する。信頼できる環境でのみ使用すること。

## テスト

```bash
bats tests/
```

## ライセンス

(未設定)
