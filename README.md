# cc-session

汎用 Claude Code セッション管理プラグイン。tmux ウィンドウ上の Claude Code セッションを **spawn / fork** し、状態を検出する。

## 機能

| スキル | 説明 |
|--------|------|
| `/session:spawn` | 新しい tmux ウィンドウで Claude Code を起動（コンテキスト非継承、`--worktree` 対応）。完了監視はデフォルト ON |
| `/session:fork` | 現在のセッションを fork（会話履歴を継承して並行実行）。完了監視はデフォルト ON |
| `/session:ready-compaction` | `/compact` 前に作業状態を外部化し、フックで圧縮後に自動復元（opt-in） |

spawn/fork は起動後、spawn 元セッションが Claude Code の Monitor / `run_in_background` で完了を監視し報告する（「投げっぱなし」で省略、「監視して」で途中経過も報告）。長時間・常駐の監視やマルチウィンドウ統括はこのプラグインの範囲外。

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

## compaction を生き延びる（ready-compaction）

`/session:ready-compaction` は `/compact`（会話圧縮）で作業状態を失わないための知識外部化スキル。三層記憶モデルで退避・復元する:

- **Long-term Memory**（永続）→ doobidoo MCP に知見を保存
- **Working Memory**（一時）→ `.claude-session/working-memory.md` に退避し、compaction 後にフックが自動復元
- **Compacted Context**（圧縮済み）→ Claude Code 内部（PreCompact がヒント注入）

付随する PreCompact / PostCompact / SessionStart(compact) フック（`hooks/hooks.json`）が圧縮の前後で退避・復元を自動化する。これらは **opt-in**: `.claude-session/.compaction-enabled` マーカーがあるプロジェクトでのみ発火する（スキル初回実行時に自動作成、他プロジェクトでは no-op）。

設計詳細は `architecture/compaction-memory-model.md` を参照。

## セキュリティ注記

`cld` / `cld-spawn` で起動するセッションは自動実行を前提に `claude --dangerously-skip-permissions` で起動する。信頼できる環境でのみ使用すること。

## テスト

```
bats tests/
```

## ライセンス

(未設定)
