# cc-session

汎用 Claude Code セッション管理プラグイン。tmux ウィンドウ上の Claude Code セッションを **spawn / fork** し、状態を検出する。

## 機能

| スキル | 説明 |
|--------|------|
| `/session:spawn` | 新しい tmux ウィンドウで Claude Code を起動（コンテキスト非継承、`--worktree` 対応）。完了監視はデフォルト ON |
| `/session:fork` | 現在のセッションを fork（会話履歴を継承して並行実行）。完了監視はデフォルト ON |
| `/session:ready-compaction` | `/compact` 前に「命令・状態」を carrier 別に振り分け外部化（policy router）。effort 一時層を退避＋carry-forward し、フックで圧縮後に自動復元（opt-in） |

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

`/session:ready-compaction` は `/compact`（会話圧縮）で**命令**を失わないための policy router。`/compact` が構造的に落とすのは「事実」でなく「ambient な命令（手法・計画の弧）」——これは事実の店では解けない。スキルは項目を **2 軸（適用範囲 × 強制）** で分類し、carrier 別に振り分ける:

- **恒久命令**（このリポで常に真）→ **プロジェクト CLAUDE.md(git)** へ昇格提案（提案のみ。グローバル CLAUDE.md は対象外）
- **横断/インシデントの事実・教訓** → doobidoo MCP に保存
- **effort 命令・作業状態**（この作業の間だけ）→ `.claude-session/working-memory.md` に 2 節スキーマで退避し、次サイクルへ **carry-forward**（コア）
- **hard 候補**（gate を持ち歪みを許せない命令）→ working-file に `[hard候補]` でマーク（実強制は Phase-2 の hook）

付随する PreCompact / PostCompact / SessionStart(compact) フック（`hooks/hooks.json`）が圧縮の前後で退避・復元と命令の carry-forward を自動化する。これらは **opt-in**: `.claude-session/.compaction-enabled` マーカーがあるプロジェクトでのみ発火する（スキル初回実行時に自動作成、他プロジェクトでは no-op）。

2 節スキーマ・carry-forward の実体は `scripts/lib/working-memory.sh`。設計詳細は `architecture/compaction-memory-model.md`（2 軸 × carrier モデルの SSOT）、フェーズ別の決定根拠は `architecture/ready-compaction-redesign.md` を参照。

## セキュリティ注記

`cld` / `cld-spawn` で起動するセッションは自動実行を前提に `claude --dangerously-skip-permissions` で起動する。信頼できる環境でのみ使用すること。

## テスト

```
bats tests/
```

## ライセンス

(未設定)
