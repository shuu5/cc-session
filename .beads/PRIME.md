[bd prime] このリポの永続タスク台帳のワークフロー文脈。ポリシーの SSOT はこの `.beads/PRIME.md`（`bd prime` 出力を上書き）。出力が切れていたら全文を読んでから続行すること。

# Beads Workflow Context (cc-session)

> SessionStart hook が `bd prime` を自動実行し、この内容を注入する（新規・resume・clear・compaction 後の再開）。compaction 後は PostCompact(ready-compaction) で Working Memory が、SessionStart で本文脈が復元される。

## 役割分担（最重要）
- **タスク → beads**: 着手中 / 保留 / 依存のある作業は bd issue で追跡。セッションを跨いで永続する。
- **知識・知見 → doobidoo**: `mcp__doobidoo__memory_store` / `mcp__doobidoo__memory_search` を使う。**`bd remember` / `bd recall` / `bd memories` は使わない**（consolidation 機構が無く肥大化するため）。beads はタスク専用。
- 一時的なセッション内 TODO（TodoWrite）や workflow / Agent オーケストレーションは併用してよい。ただし**セッションを越えて残すべき作業は必ず bd issue 化**する。

## 🚨 セッション終了プロトコル
"done" / "完了" と言う前に必ず:
```
[ ] 1. bd close <id> [--reason "..."]   # 完了した issue を close
[ ] 2. bd create ...                    # 残作業をフォローアップ issue 化
[ ] 3. bd dolt push                     # 台帳をリモートへ同期
[ ] 4. git add → commit                 # コードは通常の PR ワークフロー（main へ直 push しない）
```

## ⚙️ バージョン管理・保守（重要）
- **bd は v1.1.0 前提**（旧 v1.0.4 pin は 2026-07-15 の user 裁定で意図的に解除。旧 pin の根拠 = v1.0.5+ の migration 0043 マルチマシン同期問題〔upstream #4259〕）。バージョン変更（`bd upgrade` / `npm install -g @beads/bd`）は agent が自発的に実行しない — 人間の明示指示があるときのみ。
- **v1.1.0 実測の罠（silent truncation）**: `bd list` は既定 `--limit 50` で超過分を無警告切り捨てる（footer の Total も切詰後件数）。完全性が要る機械 fetch は `bd list --limit 0` 必須。`bd ready` は open の subset（in_progress/blocked/deferred を含まない）で、`--status=open` も blocked/deferred を含まない（独立 status enum）。「未 close 全件」はフィルタ無し `bd list --limit 0`。
- このプロジェクトの beads は `bd init --skip-agents --skip-hooks` で導入済（bd に CLAUDE.md/AGENTS.md を汚染させない）。本 PRIME.md がポリシー SSOT で、bd は再生成しない。

## Core Rules
- 非自明な作業は**着手前に `bd create`** → `bd update <id> --claim` で in_progress 化。
- セッション開始時は `bd ready` で着手可能タスクを確認。
- `bd edit` は使わない（$EDITOR を開きエージェントをブロックする）→ `bd update <id> --description/--title/--notes` でインライン更新。
- priority は 0-4 / P0-P4（0=critical, 2=medium, 4=backlog）。"high"/"medium"/"low" は不可。
- 依存は blocks / parent-child 等。`bd ready` をブロックするのは blocking 系（blocks/parent-child/conditional-blocks/waits-for）のみ。

## Essential Commands（要点。全コマンド・詳細は `bd --help` / `bd <cmd> --help`）
- 探す: `bd ready`（着手可能）/ `bd list [--status=open|in_progress] [--limit 0]`（全件は `--limit 0`）/ `bd show <id>` / `bd search <query>` / `bd blocked`
- 作る/更新: `bd create --title="..." --description="..." --type=task|bug|feature --priority=2` / `bd update <id> --claim`（in_progress 化）/ `bd update <id> --description/--notes/--title`（インライン更新）
- 完了/依存: `bd close <id> [--reason="..."]` / `bd dep add <issue> <depends-on>`（issue が depends-on に依存）
- 同期/健全: `bd dolt push` / `bd dolt pull`（refs/dolt/data 同期）/ `bd stats` / `bd doctor`

<!-- beads-init-template v:1 — このファイルは beads-init skill 由来。手動編集してもこの行を残せば skill は「我々の版」と認識し上書きしない。 -->

