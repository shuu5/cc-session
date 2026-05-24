---
name: ready-compaction
description: |
  /compact（会話圧縮）の前に作業状態を外部化し、compaction を安全に生き延びる準備をする。
  Long-term Memory（doobidoo）への知見保存 → Working Memory のファイル退避 → /compact 手動実行の提案。
  PreCompact/PostCompact/SessionStart フックが圧縮後の自動復元を担う。

  Use when user wants to: prepare for compaction, externalize knowledge,
  says 「compaction の準備」「知識を保存して」「ready-compaction」
  says 「コンテキストが限界」「/compact する前に」「作業状態を退避」
---

# ready-compaction Skill

`/compact`（Claude Code の built-in 会話圧縮）を安全に通過するための知識外部化スキル。
三層記憶モデルに基づき、失ってはいけない情報を「外部」へ退避してから compaction を促す。

> **重要**: `/compact` は built-in CLI のため skill/tool からの自動起動は不可能。
> 本スキルは Step 0〜3 を自動実行し、Step 4 で **ユーザーへの手動実行指示のみ** 行う。

## 三層記憶モデル（要約）

| 層 | 保存先 | 担当 |
|---|---|---|
| Long-term（永続・sharp）| doobidoo MCP | 本スキル Step 2 |
| Working Memory（一時・sharp）| `$WORKING_MEMORY_FILE` | 本スキル Step 3 → PostCompact フックが復元 |
| Compacted Context（動的・fuzzy）| Claude Code 内部 | 自動生成（PreCompact フックがヒント注入）|

詳細は `architecture/compaction-memory-model.md` を参照。

## 実行手順（MUST）

### Step 0: セットアップ（opt-in 有効化）

パスを解決し、退避ディレクトリと opt-in マーカーを用意する。
マーカーがあるプロジェクトでのみ compaction フックが発火する（他プロジェクトでは no-op）。

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/session-env.sh"
mkdir -p "$WORKING_MEMORY_DIR"
touch "$COMPACTION_ENABLED_MARKER"   # 初回のみ作成。以降このプロジェクトでフックが有効化される
```

### Step 1: 外部化の判断

現在の会話から、何を Long-term（この compaction を超えて将来も必要）に、
何を Working Memory（圧縮直後に即必要）に振り分けるか判断する。

判定基準: 「この compaction を超えてもう使わないが将来必要」→ Long-term、
「次のステップで即座に必要」→ Working Memory。

### Step 2: Long-term Memory 保存（doobidoo）

セッション中に判明した重要な知見・決定・教訓を doobidoo に保存する:

- `mcp__doobidoo__memory_store` を使用
- type は内容に応じて `project`（作業状態・進捗）または `feedback`（技術的決定・教訓）
- doobidoo が利用不可なら **警告のみでスキップ**（エラー終了しない）

### Step 3: Working Memory 退避

`$WORKING_MEMORY_FILE`（Step 0 で解決済み）に現在の作業状態を以下のスキーマで書き出す:

```markdown
---
externalized_at: "<ISO8601>"
trigger: manual
lifecycle: temporary
---

## 現在のタスク
<!-- 何に取り組んでいるか。チェックリスト形式 -->

## 次のステップ
<!-- compaction 復帰後に最初に実行すべきアクション -->

## 重要なコンテキスト
<!-- 圧縮で失われると困る sharp な情報（ファイルパス、決定事項、制約など）-->
```

書き出しは Write tool で `$WORKING_MEMORY_FILE` に対して行う。

### Step 4: compaction 提案（ユーザー手動実行）

保存完了を報告し、`/compact` の手動実行を促す:

```
✓ Long-term Memory 保存完了（doobidoo）
✓ Working Memory 退避完了（$WORKING_MEMORY_FILE）
✓ opt-in 有効化済み（このプロジェクトで compaction フックが発火します）
>>> `/compact` を手動で実行してください（built-in CLI のため自動起動不可）
```

`/compact` 実行後は PreCompact → PostCompact → SessionStart(compact) フックが
自動的に Working Memory を復元する。

## 禁止事項（MUST NOT）

- `/compact` の自動実行を試みてはならない（built-in CLI のため skill/tool から起動不可）
- doobidoo エラーで全体を停止してはならない（警告のみ）
- 外部化が未完了の状態で「完了」と報告してはならない
- `.gitignore` を勝手に編集してはならない（`.claude-session/` の扱いはユーザー判断に委ねる）

## 注意

- 退避先は既定で作業ディレクトリ直下 `$WORKING_MEMORY_DIR`（`.claude-session/`、環境変数で上書き可）
- compaction フックは opt-in マーカーがあるプロジェクトでのみ動作する
- PostCompact が復元すると Working Memory は `working-memory.consumed.md` へ mv される（削除しない）
