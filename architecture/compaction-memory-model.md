# Compaction 知識外部化モデル（ready-compaction）

cc-session の `ready-compaction` スキルと 3 つの compaction フックが実装する設計の SSOT。
Claude Code の `/compact`（会話圧縮）を「単なる圧縮」ではなく「**命令の選択的外部化**」として扱う。

`ready-compaction` は **policy router 兼 effort 一時層 carrier**。会話から抽出した項目を
**2 軸（適用範囲 × 強制）** で分類し、それぞれ正しい carrier へ委譲する。自前で抱えるのは
effort 一時層（Working Memory ファイル）だけで、恒久命令（→ CLAUDE.md）と hard（→ hook）は再発明しない。

> このモデルは grilling（2026-06-01）で確定。旧「三層記憶モデル」は本モデルへ刷新した
> （sharp/fuzzy は「なぜ外部化が要るか」の根拠として下に残す）。実装フェーズ別の決定根拠は
> [`ready-compaction-redesign.md`](ready-compaction-redesign.md) を参照。

## なぜ外部化が要るのか（sharp / fuzzy）

ユーザーは 1M でも精度低下のため **~50% で手動 compact** する運用。compact の目的は容量でなく
**精度回復**——ぼやけた蓄積（fuzzy）を捨て、はっきりした足場（sharp）だけを温存したい。

- **sharp**: 明確で固定された情報（決定事項・制約・命令・ファイルパス）。失うと作業が破綻する。
- **fuzzy**: compaction のたびに変容する「ぼんやりした全体像」（= Compacted Context）。直接制御できない。

`/compact` は fuzzy を作り直すが、その過程で sharp な情報の一部、とりわけ後述の **命令** を落とす。
だから sharp な要素を compaction の外へ退避してから compact する——これが本スキルの存在理由。

## 落ちるのは「事実」でなく「命令」

`/compact` の要約器は intent・主要概念・変更ファイル・pending tasks は比較的保つが、
**特定の tool 出力に紐づかない ambient な命令（手法・計画の弧・横断的方針）** を構造的に deprioritize する。

→ 失って困るのは事実ではなく **命令（imperative）**。命令を「事実の店」（doobidoo / MEMORY.md）に
入れるのは**カテゴリ錯誤**。Claude Code の設計では **命令 = CLAUDE.md の仕事 / 事実 = memory の仕事**。
ただしユーザーの手法の一部は「この作業の間だけ」効く **effort スコープの命令**で、永続 CLAUDE.md にも
一時メモにも収まらない——この **effort-lifetime の命令** こそ ready-compaction の非代替コア。

## 2 軸 × carrier モデル

**軸1 適用範囲**: `always`（無条件）/ `default`（軽微は LLM 判断で除外）/ `effort`（この作業の間だけ。
「見ている間だけ」の presence は effort 内の任意条件として統合）。

**軸2 強制**: `auto`（LLM 自己適用）/ `confirm`（ユーザー確認）/ `hard`（物理ブロック）。

| 区分 | carrier | 生存機構 | 所有者 |
|---|---|---|---|
| 恒久命令 `always`/`default` × auto/confirm | **プロジェクト CLAUDE.md(git)** | 自動再注入＋git 同期 | 通常コミットフロー（スキルは**昇格提案**のみ）|
| 恒久・横断/インシデントの**事実** | doobidoo | 中央サーバ | 本来用途に縮小 |
| **`effort` × auto/confirm** | **Working Memory ファイル** | スキルが退避＋carry-forward | **ready-compaction（コア）** |
| any × **`hard`** | **PreToolUse hook + marker** | config（非圧縮）| **Phase-2**（スキルは**候補マーク**のみ）|
| ~~MEMORY.md~~ | — | — | machine-local のため別マシンで stranded する。carrier に使わない |

**切り分け**: 「hard を除いた部分 ≠ ready-compaction」。non-hard はさらに
「恒久 → CLAUDE.md(native, スキル不要)」と「effort → Working Memory(=スキル)」に割れる。
**ready-compaction が carrier として所有するのは effort 一時層だけ**。恒久と hard は検出して委譲/マークする。

## ready-compaction の責務境界

| 項目の種類 | スキルの役割 |
|---|---|
| 恒久命令（このリポで常に真）| **プロジェクト CLAUDE.md へ昇格提案のみ**（commit は通常フロー。グローバル CLAUDE.md は対象外）|
| 横断/インシデントの事実 | doobidoo に保存（事実のみ）|
| effort 命令・作業状態 | Working Memory に退避し、次サイクルへ carry-forward（コア）|
| hard 候補 | Working Memory の「命令・制約」節に `[hard候補]` でマーク → `/session:enforce` で gate 昇格（実強制は `pretooluse-enforce.sh`＝Phase-2 で実装済み。設計は ready-compaction-redesign §9.6）|

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
④ SessionStart(compact) → ambient hints 注入（Long-term の存在ポインタ・carry-forward リマインダ）
```

| Hook | stdout の行き先 | 役割 |
|------|----------------|------|
| PreCompact | compaction **される** context | ①退避（side effect、2節スキーマ＋consumed の機械 carry-forward）②圧縮に残すヒント |
| PostCompact | compaction **後の** 新 context | sharp な作業状態の復元＋命令・制約の carry-forward 明示＋consumed へ mv |
| SessionStart(compact) | compaction **後の** 新 context | ambient hints（Long-term ポインタ・consumed の命令・制約引き継ぎリマインダ）|

PostCompact は「直前作業の復帰」、SessionStart(compact) は「プロジェクト全体の再認識」と棲み分ける。

## コンポーネント責務

| 責務 | 担当 |
|------|------|
| 項目を 2軸（always/default/effort × auto/confirm/hard）へ分類し carrier を決める（router）| スキル Step 1（AI 判断）|
| 恒久命令のプロジェクト CLAUDE.md 昇格提案 | スキル（提案のみ。commit は通常フロー）|
| 横断/インシデント事実の doobidoo 保存 | スキル Step 2（`mcp__doobidoo__memory_store`）|
| Working Memory の生成（2節シード）と内容マージ | スキル Step 3a（`emit_working_memory`）＋ Step 3b（Edit）|
| consumed からの命令・制約の機械 carry-forward | `scripts/lib/working-memory.sh`（`extract_effort_directives` / `emit_working_memory`）|
| Working Memory の安全網退避（スキル未実行時）| PreCompact フック（consumed があれば命令節を機械引き継ぎ）|
| Working Memory の context 注入・consumed マーク | PostCompact フック |
| ambient hints 注入 | SessionStart(compact) フック |
| `[hard候補]` の hook 強制 | **Phase-2**（PreToolUse hook + marker。下記接続点）|
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

## working-memory.md スキーマ（2 節）

**正典（SSOT）は `scripts/lib/working-memory.sh`**（`emit_working_memory` が生成）。
スキル・フックはこのテンプレに収束し、見出し・タグ書式を手書きで変えない。

```markdown
---
externalized_at: "<ISO8601>"
trigger: manual | auto_precompact
lifecycle: temporary
---

## 計画弧・次のステップ
<!-- ephemeral: 毎サイクル再生成。今どこにいて、次に何をするか。 -->

## この effort を貫く命令・制約
<!-- persistent-within-effort: consumed から carry-forward。
     各項目の先頭に強制モードタグ [auto] / [confirm] / [hard候補] を付ける。 -->
- [auto] 例: 軽微でなければ専用フローで実装
- [confirm] 例: merge 前にユーザー確認
- [hard候補] 例: gh pr merge はレビュー完了まで禁止（Phase-2 で hook 化）
```

**書式 freeze**: 節見出しは上記の厳密文字列、タグは半角 `[auto]` / `[confirm]` / `[hard候補]` を
行頭リスト項目の先頭トークンとする（Phase-2 hook が機械で拾うため）。

## carry-forward（ハイブリッド）

「毎サイクル忘れて続ける」を治療する機構。**決定論的な機械引き継ぎ＋LLM マージ**の2段:

1. **機械（決定論・絶対落とさない）**: `emit_working_memory <ts> <trigger> <consumed>` が、
   consumed の「この effort を貫く命令・制約」節を機械抽出して新 working-file へ引き継ぐ。
   新節が**不在**なら旧スキーマ「重要なコンテキスト」節をフォールバックで読む（新節が在って空＝意図的な空は尊重。後方互換）。
2. **LLM（更新）**: スキル Step 3b が生成済みファイルを Edit し、現在文脈とマージ（古い項目の削除・新規追加）。

consumed は PostCompact が working→consumed へ mv して供給する。次サイクルの退避で新 working を
作る際に上記 1 が consumed を読むため、effort が複数 compaction を跨いでも命令が連鎖継承される。

## Phase-2（hard 強制 / hook policy）への接続点

> 設計のみ。実装は Phase-1 完了後（詳細は [`ready-compaction-redesign.md`](ready-compaction-redesign.md) §9）。

`any × hard`（わずかな歪みも許さない命令）は soft-text の確率的遵守でなく
**PreToolUse hook で決定論的に強制**する。Phase-1 で working-file に付いた `[hard候補]` タグが起点:

- router（スキル Step 1）が `[hard候補]` を検出 → Phase-2 では「この命令を hook policy に登録するか?」を提案。
- 承認時、`gate`（例 `gh pr merge`）にマッチするツール呼び出しを横取りし、`marker`（解除条件）不在なら
  `decision: block`＋代替ルート提示で拒否する hook を有効化する。
- **gate-point（単一の不可逆ツール呼び出し）を持つ命令のみ hard 化可**。拡散的な「実装は〜で」は gate が無く不可。
- hook は config（会話履歴外）なので compaction で消えない＝reliability が機構で保証される（soft-text に対する本質的優位）。

## twill su-compact からの主な変更（汎用化）

移植元は twill の `twl:su-compact`（command）＋ `su-precompact.sh` / `su-postcompact.sh` / `su-session-compact.sh`。
以下の twill 固有結合を剥がして cc-session の構成に合わせた:

- `.autopilot/` モード自動判定（Wave/Issue 駆動）→ 削除。単一モード（命令・作業状態の外部化）に統合
- `.supervisor/session.json` 連携（session_id 更新・current_wave 等）→ 削除
- `.supervisor/events/` クリーンアップ → 削除
- su-observer 前提・MCP backend・observer-auto-inject → 削除
- `.supervisor/` → `.claude-session/`（`$WORKING_MEMORY_DIR`、env 上書き可）
- Memory MCP は pluggable config を廃し doobidoo 固定
- command 形式 → cc-session 規約に合わせ skill（`/session:ready-compaction`）化
