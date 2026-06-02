# cc-session

汎用 Claude Code セッション管理プラグイン。tmux ウィンドウ上の Claude Code セッションを **spawn / fork** し、状態を検出する。

## 機能

| スキル | 説明 |
|--------|------|
| `/session:spawn` | 新しい tmux ウィンドウで Claude Code を起動（コンテキスト非継承、`--worktree` 対応）。完了監視はデフォルト ON |
| `/session:fork` | 現在のセッションを fork（会話履歴を継承して並行実行）。完了監視はデフォルト ON |
| `/session:ready-compaction` | `/compact` 前に「命令・状態」を carrier 別に振り分け外部化（policy router）。effort 一時層を退避＋carry-forward し、フックで圧縮後に自動復元（opt-in） |
| `/session:enforce` | `[hard候補]` 命令を PreToolUse(Bash) hook が deny-block する gate へ昇格（認可専用。LLM 提案 → 人間確定）。policy 存在で opt-in |

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
- **discrete・永続タスク**（セッション/effort を越えて残す作業）→ **beads（`bd create`）で issue 化**を誘導。Working Memory「計画弧」は bd issue ID 参照に留め内容を重複させない（bd 未導入リポは Working Memory にフォールバック）
- **hard 候補**（gate を持ち歪みを許せない命令）→ working-file に `[hard候補]` でマーク → `/session:enforce` で gate 昇格（実強制は PreToolUse hook）

付随する PreCompact / PostCompact / SessionStart(compact) フック（`hooks/hooks.json`）が圧縮の前後で退避・復元と命令の carry-forward を自動化する。これらは **opt-in**: `.claude-session/.compaction-enabled` マーカーがあるプロジェクトでのみ発火する（スキル初回実行時に自動作成、他プロジェクトでは no-op）。

2 節スキーマ・carry-forward の実体は `scripts/lib/working-memory.sh`。設計詳細は `architecture/compaction-memory-model.md`（2 軸 × carrier モデルの SSOT）、フェーズ別の決定根拠は `architecture/ready-compaction-redesign.md` を参照。

## 危険操作を強制ブロックする（enforce / hard 強制層）

レビュー等の gate を通っていない危険操作（PR merge / push / deploy 等）を、PreToolUse(Bash) hook が **deny-block** する層。`[hard候補]` 命令を `/session:enforce` で gate 化して有効化する。

- **opt-in は policy ファイルの存在**（`.claude-session/enforce-policy.json`）。不在のプロジェクトでは hook は no-op（allow）＝波及は無害。スキーマの正典は `architecture/enforce-policy.example.json`。
- **認可と unlock の分離**: gate 定義は `/session:enforce` が **LLM 提案 → 人間確定**で書く（authoring 専用）。実行時の許可は人間が生シェルで `scripts/enforce-unlock <gate> "<command>"`（または block 時に提示される `touch` コマンド）を叩いて marker を作る。lib は marker を作らない（読み取り専用）が、marker は空ファイルなので技術的には作成可能。本層が保証するのは「**沈黙の・偶発的な自己認可の防止**」（必ず block→人間に surface＋可監査な明示操作）であり、信頼境界は「人間が生シェルで叩く規律」（暗号学的な不可能性ではない）。
- **marker は操作インスタンス単位**（例 `pr-merge-pr-3-sha-<head8>`）。対象や head SHA が変われば再 gate（「一度で永久解除」を防ぐ）。`marker_ttl_sec` で時間失効も設定可。
- **fail-closed (scoped)**: policy が壊れている / jq 不在のときは内蔵 danger list（push/merge/deploy 系）のみ block し、他は通す。
- **緊急 bypass は人間操作のみ**: `SESSION_ENFORCE_OFF=1` を export、または policy を削除/空化。
- グローバルの `git-destructive-guard.sh` 等と共存（条件が別の PreToolUse:Bash hook）。

パス（`ENFORCE_POLICY_FILE` / `ENFORCE_MARKER_DIR` / `ENFORCE_SHA_TIMEOUT`）は環境変数で上書き可能。フォーマット/マッチ/marker 導出の SSOT は `scripts/lib/enforce-policy.sh`、設計の SSOT は `architecture/ready-compaction-redesign.md §9.6`。

## セキュリティ注記

`cld` / `cld-spawn` で起動するセッションは自動実行を前提に `claude --dangerously-skip-permissions` で起動する。信頼できる環境でのみ使用すること。

## テスト

```
bats tests/
```

## ライセンス

(未設定)
