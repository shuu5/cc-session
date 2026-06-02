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

## ⚙️ バージョン固定・保守（重要）
- **bd は v1.0.4 にピン**。`bd upgrade` や `npm install -g @beads/bd`(latest) を実行しないこと。v1.0.5+ は migration 0043 がマルチマシン同期を破壊する（upstream #4259）。
- このプロジェクトの beads は `bd init --skip-agents --skip-hooks` で導入済（bd に CLAUDE.md/AGENTS.md を汚染させない）。本 PRIME.md がポリシー SSOT で、bd は再生成しない。

## Core Rules
- 非自明な作業は**着手前に `bd create`** → `bd update <id> --claim` で in_progress 化。
- セッション開始時は `bd ready` で着手可能タスクを確認。
- `bd edit` は使わない（$EDITOR を開きエージェントをブロックする）→ `bd update <id> --description/--title/--notes` でインライン更新。
- priority は 0-4 / P0-P4（0=critical, 2=medium, 4=backlog）。"high"/"medium"/"low" は不可。
- 依存は blocks / parent-child 等。`bd ready` をブロックするのは blocking 系（blocks/parent-child/conditional-blocks/waits-for）のみ。

## Essential Commands（要点。全コマンド・詳細は `bd --help` / `bd <cmd> --help`）
- 探す: `bd ready`（着手可能）/ `bd list [--status=open|in_progress]` / `bd show <id>` / `bd search <query>` / `bd blocked`
- 作る/更新: `bd create --title="..." --description="..." --type=task|bug|feature --priority=2` / `bd update <id> --claim`（in_progress 化）/ `bd update <id> --description/--notes/--title`（インライン更新）
- 完了/依存: `bd close <id> [--reason="..."]` / `bd dep add <issue> <depends-on>`（issue が depends-on に依存）
- 同期/健全: `bd dolt push` / `bd dolt pull`（refs/dolt/data 同期）/ `bd stats` / `bd doctor`

<!-- beads-init-template v:1 — このファイルは beads-init skill 由来。手動編集してもこの行を残せば skill は「我々の版」と認識し上書きしない。 -->

