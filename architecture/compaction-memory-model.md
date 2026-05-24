# Compaction 知識外部化モデル（ready-compaction）

cc-session の `ready-compaction` スキルと 3 つの compaction フックが実装する三層記憶モデルの設計。
Claude Code の `/compact`（会話圧縮）を「単なる圧縮」ではなく「知識の選択的外部化」として扱う。

## 三層記憶モデル

3 層は **固定性（sharpness）** と **持続性（persistence）** の 2 軸で分類される。

| 層 | 固定性 | 持続性 | 保存先 | 変容パターン |
|----|--------|--------|--------|-------------|
| **Long-term Memory** | sharp | 永続 | doobidoo MCP | 書込後は不変。削除するまで残る |
| **Working Memory** | sharp | 一時 | `$WORKING_MEMORY_FILE` | 書込後は不変。復元後に consumed へ |
| **Compacted Context** | **fuzzy** | セッション内 | Claude Code 内部 | compaction 毎に書き換わる「ぼんやりした全体像」|

- **Long-term と Working Memory はどちらも sharp**（明確で固定）だが、持続性が違う（永続 vs 一時）。
- **Compacted Context だけが fuzzy** で compaction のたびに変容する。直接制御できないが、PreCompact の stdout が圧縮対象に含まれるため「何を残すべきか」のヒントは渡せる。

## hook 発火順序

```
[context が限界に近づく / ユーザーが /compact]
  ↓
① PreCompact      → working-memory を退避（side effect）＋ 圧縮ヒント（stdout=圧縮対象）
  ↓
② Compaction 実行 → Compacted Context 生成（fuzzy）
  ↓
③ PostCompact     → working-memory を読んで新 context に注入（sharp 復元）＋ consumed へ mv
  ↓
④ SessionStart(compact) → ambient hints 注入（Long-term の存在ポインタ等）
```

| Hook | stdout の行き先 | 役割 |
|------|----------------|------|
| PreCompact | compaction **される** context | ①退避（side effect）②圧縮に残すヒント |
| PostCompact | compaction **後の** 新 context | sharp な作業状態の復元 |
| SessionStart(compact) | compaction **後の** 新 context | ambient hints（fuzzy な全体像補強）|

PostCompact は「直前作業の復帰」、SessionStart(compact) は「プロジェクト全体の再認識」と棲み分ける。

## コンポーネント責務

| 責務 | 担当 |
|------|------|
| 何を Long-term / Working に振り分けるか判断 | スキル（AI 判断）|
| Long-term Memory への保存 | スキル（`mcp__doobidoo__memory_store`）|
| Working Memory の内容生成・書き出し | スキル（Write）|
| Working Memory の安全網退避（スキル未実行時）| PreCompact フック |
| Working Memory の context 注入・consumed マーク | PostCompact フック |
| ambient hints 注入 | SessionStart(compact) フック |
| opt-in マーカー作成 | スキル Step 0 |

## opt-in ゲート

compaction フックは cc-session をロードした全プロジェクトで発火しうるため、
**`$COMPACTION_ENABLED_MARKER`（既定 `.claude-session/.compaction-enabled`）が存在するプロジェクトでのみ動作**する。
マーカーはスキル初回実行時に自動作成され、未使用プロジェクトでは全フックが no-op（exit 0）になる。

各フックは `set -e` を使わず、ファイル I/O は握り潰す（フック失敗で compaction をブロックしないため）。

## パス解決

すべて `scripts/lib/session-env.sh` が SSOT として解決し、環境変数で上書き可能（[CLAUDE.md](../CLAUDE.md) 参照）。
window 状態系（`$HOME` 配下 namespace）と異なり、Working Memory は会話/プロジェクト固有のため
既定でプロジェクトローカル（`$PWD/.claude-session`）に置く。

| 変数 | 既定 |
|---|---|
| `WORKING_MEMORY_DIR` | `$PWD/.claude-session` |
| `WORKING_MEMORY_FILE` | `$WORKING_MEMORY_DIR/working-memory.md` |
| `WORKING_MEMORY_CONSUMED_FILE` | `$WORKING_MEMORY_DIR/working-memory.consumed.md` |
| `COMPACTION_ENABLED_MARKER` | `$WORKING_MEMORY_DIR/.compaction-enabled` |
| `COMPACTION_LOG_FILE` | `$WORKING_MEMORY_DIR/compaction-log.txt` |

## working-memory.md スキーマ

```markdown
---
externalized_at: "<ISO8601>"
trigger: manual | auto_precompact
lifecycle: temporary
---

## 現在のタスク
## 次のステップ
## 重要なコンテキスト
```

## twill su-compact からの主な変更（汎用化）

移植元は twill の `twl:su-compact`（command）＋ `su-precompact.sh` / `su-postcompact.sh` / `su-session-compact.sh`。
以下の twill 固有結合を剥がして cc-session の構成に合わせた:

- `.autopilot/` モード自動判定（Wave/Issue 駆動）→ 削除。単一モード（作業状態の外部化）に統合
- `.supervisor/session.json` 連携（session_id 更新・current_wave 等）→ 削除
- `.supervisor/events/` クリーンアップ → 削除
- su-observer 前提・MCP backend・observer-auto-inject → 削除
- `.supervisor/` → `.claude-session/`（`$WORKING_MEMORY_DIR`、env 上書き可）
- Memory MCP は pluggable config を廃し doobidoo 固定
- command 形式 → cc-session 規約に合わせ skill（`/session:ready-compaction`）化
