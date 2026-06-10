---
name: ready-compaction
description: |
  /compact（会話圧縮）の前に、失うと困る「命令・状態」を carrier 別に振り分けて外部化し、
  compaction を安全に生き延びる準備をする。policy router として項目を分類し、effort 一時層
  （Working Memory ファイル）だけを自前で運ぶ。恒久命令はプロジェクト CLAUDE.md(git) へ昇格提案、
  横断/インシデントの事実は doobidoo、hard 候補はマーク＋ /session:enforce 昇格提案。
  PreCompact/PostCompact/SessionStart フックが圧縮後の自動復元と carry-forward を担う。

  Use when user wants to: prepare for compaction, externalize knowledge,
  says 「compaction の準備」「知識を保存して」「ready-compaction」
  says 「コンテキストが限界」「/compact する前に」「作業状態を退避」
---

# ready-compaction Skill

`/compact`（Claude Code の built-in 会話圧縮）を安全に通過するための **policy router 兼 effort 一時層 carrier**。

`/compact` の要約器が構造的に落とすのは「事実」ではなく **ambient な命令（手法・計画の弧）**。
これは事実の店（doobidoo / MEMORY.md）では原理的に解けない。本スキルは会話から抽出した各項目を
**「事実か命令か」「いつ効く命令か」** で分類し、それぞれ正しい carrier へ委譲する。
自前で抱えるのは **effort 一時層（Working Memory ファイル）だけ**——恒久命令と hard は再発明せず委譲/マークする。

> **重要**: `/compact` は built-in CLI のため skill/tool からの自動起動は不可能。
> 本スキルは Step 0〜3 を自動実行し、Step 4 で **ユーザーへの手動実行指示のみ** 行う。

## carrier モデル（要約）

| 項目の種類 | carrier | 本スキルの役割 |
|---|---|---|
| 恒久命令（このリポで常に真）| **プロジェクト CLAUDE.md(git)** | 「追記/修正しては?」と**提案のみ**（commit は通常フロー）|
| 横断/インシデントの**事実**・教訓 | doobidoo MCP | Step 2 で保存（事実のみ）|
| **effort 命令・作業状態**（この作業の間だけ）| `$WORKING_MEMORY_FILE` | Step 3 で退避＋carry-forward（**コア**）|
| **discrete・永続タスク**（セッション/effort を越えて残す作業）| **beads (`bd`)** | 「`bd create` で issue 化しては?」と誘導。Working Memory「計画弧」は bd issue ID を参照し内容を重複させない（bd 未導入リポは Working Memory にフォールバック）|
| **hard 候補**（gate を持ち歪みを許せない命令）| working-file に `[hard候補]` マーク（＋ `/session:enforce` で gate 昇格）| マーク＋昇格の導線提示（実強制は PreToolUse hook）|

詳細は `architecture/compaction-memory-model.md`（2軸 × carrier モデルの SSOT）を参照。
スキーマ・carry-forward の実体は `scripts/lib/working-memory.sh`。

## 実行手順（MUST）

### Step 0: セットアップ（opt-in 有効化）

パスとライブラリを解決し、退避ディレクトリと opt-in マーカーを用意する。
マーカーがあるプロジェクトでのみ compaction フックが発火する（他プロジェクトでは no-op）。

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/session-env.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/working-memory.sh"
mkdir -p "$WORKING_MEMORY_DIR"
touch "$COMPACTION_ENABLED_MARKER"   # 初回のみ作成。以降このプロジェクトでフックが有効化される
```

### Step 1: policy router（振り分け）

現在の会話から「失うと困る項目」を抽出し、各項目を carrier へ振り分ける。
まず **事実か命令か** を見極め、命令は **適用範囲（いつ効くか）** で分ける:

| 判定 | 振り分け先 | アクション |
|---|---|---|
| **恒久命令**（このリポで何をしていても常に真の手法・規約）| プロジェクト CLAUDE.md | 「**プロジェクトの** CLAUDE.md に追記/修正しては?」と**提案**。承認時のみ通常のコミットフローで反映（スキルは勝手にコミットしない）。**ユーザースコープのグローバル CLAUDE.md は対象外**——横断的ルールに見えても、グローバルへは「手動で検討を」と口頭で促すだけ（自動提案・自動編集しない）|
| **横断/インシデントの事実・教訓** | doobidoo | Step 2 へ |
| **effort 命令・作業状態**（この作業の間だけ有効）| working-file | Step 3 で「命令・制約」節に強制モードタグ付きで記入 |
| **discrete・セッション/effort 横断のタスク**（着手中/保留/依存があり跨いで残す作業）| beads（`bd create`）| 着手前に `bd create` → `bd update <id> --claim`。Working Memory「計画弧」には **bd issue ID のみ参照**（内容重複禁止）。**bd 未導入リポでは従来どおり Working Memory に退避**（フォールバック）|
| **hard 候補**（gate-point を持ち、わずかな歪みも許したくない命令）| working-file | 「命令・制約」節に `[hard候補]` タグでマーク。さらに **`/session:enforce` で gate へ昇格** を提案（policy 書き込みは /session:enforce が人間 ratify を得て行う。本スキルはマーク＋導線提示まで）|

> **hard 候補は適用範囲（always/default/effort）に依らずマーク対象**（`any × hard`）。effort 項目に限定されない。実強制は `pretooluse-enforce.sh`（PreToolUse:Bash hook）＝コマンドを deny-block する。本スキルの責務はマークと **`/session:enforce` への導線提示**まで。ユーザーが「この操作をブロックしたい」と望むなら `/session:enforce` を勧める（gate 定義は LLM 提案 → 人間確定）。marker による unlock は人間が生シェルで `enforce-unlock` を叩く（Claude は実行しない＝hard 性の核心）。

### Step 2: Long-term Memory 保存（doobidoo）— 事実のみ

**横断/インシデントの事実・教訓のみ**を doobidoo に保存する（作業状態・進捗は入れない＝Step 3 へ回す）:

- `mcp__doobidoo__memory_store` を使用。type は doobidoo の ontology 内の事実・教訓系（例 `learning` / `decision`）を指定する（作業状態・進捗は入れない＝Step 3 の working-file へ）
  - ※ `feedback` は type ontology に無く `observation` へ黙示変換される（保存自体は失敗しないが意図とズレる）ため使わない
- **プロジェクト固有の恒久知識は doobidoo でなく git（CLAUDE.md/docs）へのコミット**へ誘導する
  （CLAUDE.md は compaction 後に自動再注入＋git でマシン間同期されるため、本来の置き場）
- doobidoo が利用不可なら **警告のみでスキップ**（エラー終了しない）

### Step 3: Working Memory 退避（2節スキーマ＋ハイブリッド carry-forward）

`$WORKING_MEMORY_FILE` に 2節スキーマで現在の effort を退避する。carry-forward は2段:

**3a. 機械シード（決定論・絶対落とさない）**: lib のテンプレで新 working-file を生成する。
consumed があれば前サイクルの「命令・制約」節が**機械的に carry-forward** される:

```bash
emit_working_memory "$(date -u +%Y-%m-%dT%H:%M:%SZ)" manual "$WORKING_MEMORY_CONSUMED_FILE" > "$WORKING_MEMORY_FILE"
```

**3b. LLM マージ（更新）**: 生成された `$WORKING_MEMORY_FILE` を Edit して仕上げる:
- 「## 計画弧・次のステップ」に現在地と次の行動を記入（ephemeral、毎回上書き）
- 「## この effort を貫く命令・制約」を現在文脈とマージ・更新（古い項目は削除、新規追加、
  各項目の先頭に強制モードタグ `[auto]` / `[confirm]` / `[hard候補]` を付与）

スキーマ（節見出し・タグ書式）は `scripts/lib/working-memory.sh` が SSOT。手書きで見出しを変えない。

### Step 4: compaction 提案（ユーザー手動実行）

保存・退避の完了を報告し、`/compact` の手動実行を促す:

```
✓ 恒久命令 → プロジェクト CLAUDE.md への昇格を提案（承認分のみコミット）
✓ 横断/インシデントの事実 → doobidoo 保存
✓ effort 命令・作業状態 → Working Memory 退避（前サイクルから carry-forward 済み）
✓ opt-in 有効化済み（このプロジェクトで compaction フックが発火します）
>>> `/compact` を手動で実行してください（built-in CLI のため自動起動不可）
```

`/compact` 実行後は PreCompact → PostCompact → SessionStart(compact) フックが
自動的に Working Memory を復元し、命令・制約を次サイクルへ carry-forward する。

## 禁止事項（MUST NOT）

- `/compact` の自動実行を試みてはならない（built-in CLI のため skill/tool から起動不可）
- doobidoo エラーで全体を停止してはならない（警告のみ）
- 外部化が未完了の状態で「完了」と報告してはならない
- **working-file に恒久知識を入れてはならない**（恒久命令→プロジェクト CLAUDE.md、恒久事実→doobidoo/git）
- **MEMORY.md を carrier に使ってはならない**（machine-local のため別マシンで stranded する）
- **ユーザースコープのグローバル CLAUDE.md を自動提案・自動編集してはならない**（昇格提案先はプロジェクト CLAUDE.md のみ）
- `.gitignore` を勝手に編集してはならない（`.claude-session/` の扱いはユーザー判断に委ねる）
- **durable な discrete タスクを Working Memory「計画弧」（ephemeral・carry-forward 対象外）に *だけ* 置いてはならない**（複数 compaction を跨いで喪失する）。bd 導入リポでは `bd create` で issue 化し、計画弧は **bd issue ID 参照に留める**（bd 未導入リポは従来どおり Working Memory に退避）
- **beads の `bd remember` / `bd recall` / `bd memories` を使ってはならない**（consolidation 機構が無く肥大化する。知識・知見は doobidoo、タスクは bd issue ＝役割分担）

## 注意

- 退避先は既定で作業ディレクトリ直下 `$WORKING_MEMORY_DIR`（`.claude-session/`、環境変数で上書き可）
- compaction フックは opt-in マーカーがあるプロジェクトでのみ動作する
- PostCompact が復元すると Working Memory は `$WORKING_MEMORY_CONSUMED_FILE`（session-scoped: `working-memory.<sid>.consumed.md`）へ mv される（削除しない）。
  この consumed が次サイクルの **carry-forward の供給源**になる（命令・制約節を機械引き継ぎ）。退避ファイルは session id を含むため cwd=anchor の複数セッションでも互いに上書きしない（`un-gcu`）
- 2節スキーマ・タグ書式・carry-forward の実体は `scripts/lib/working-memory.sh`（SSOT）
