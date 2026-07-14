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
| discrete・永続タスク（セッション/effort を越えて残す）| **beads（`bd create`）で issue 化を誘導**。Working Memory「計画弧」は bd issue ID 参照に留め内容を重複させない（bd 未導入リポは Working Memory にフォールバック）|
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
| SessionStart(clear) | `/clear` **後の** 新 context | 退避ファイルへの **read-only ポインタ**（安全網。下記）|

PostCompact は「直前作業の復帰」、SessionStart(compact) は「プロジェクト全体の再認識」と棲み分ける。

### `/clear` 経路の安全網（read-only ポインタ・bd ccs-et2）

`/compact`（会話圧縮）とは別に、ユーザーが **`/clear`（文脈の完全リセット）してから Working Memory を読み込んで再開**したい運用がある。`/clear` は `SessionStart` を **`source: "clear"`** で発火させ（`compact` ではない・verified: 公式 docs `code.claude.com/docs/en/hooks.md` の SessionStart matcher values = `startup`/`resume`/`clear`/`compact`）、`PreCompact`/`PostCompact` は**発火させない**（compaction 専用・verified 同上）。よって `matcher: "compact"` だけの旧構成では `/clear` 後に**自動復元は一切走らない**（退避＝書き込みは動くが復元が繋がらない非対称）。

`session-start-clear.sh`（`matcher: "clear"`）はこの非対称を、**フル自動復元ではなく read-only ポインタ**で埋める安全網（grill 2026-06-23 で確定した運用 (b)＝「基本は /compact、たまの /clear で失わず拾えれば十分」に対応する論点2案B）:

- **read-only に徹する**: working-memory への `cat` 注入も `consumed` への `mv` も**しない**。「退避ファイルあり: `<path>`。続きなら Read してください」とポインタを出すだけ（PostCompact の「復元＋consumed 化」とは責務が違う）。
- **発見性フォールバック**: 厳密 sid 一致（`$WORKING_MEMORY_FILE`）が無ければ、非 consumed の `working-memory*.md`（`*.consumed.md` 除外）を **mtime 降順で全件列挙**する。`/clear` は session_id を変える（**verified・実測 2026-06-23**: env `CLAUDE_CODE_SESSION_ID` と transcript jsonl `~/.claude/projects/<slug>/<sid>.jsonl` の 2 系統が独立に一致。`/clear` 前 `b6ae180a…` → 後 `bbe4d81e…`）。よって `/clear` 後は新セッションのパス解決が `working-memory.<新sid>.md` を指し**厳密 sid 一致は必ず空振り**する（session-scoped 命名 un-gcu の副作用）。**このフォールバックは `/clear` 復帰の load-bearing パス**であって単なる防御ではない（旧 sid の退避ファイルはここでのみ拾える）。**最新 1 件のみの提示にしない**のは、自分の古い pre-clear ファイルが並走セッションの新しいファイルの陰に隠れる発見ギャップを避けるため（全件列挙でユーザーが選べる）。
- **原因を断定しない**: フォールバックが発火する原因（`/clear` による sid 変化〔常態〕／sid 未解決の legacy 経路／自セッションが exact 名を未書込＋並走ファイル在り）は hook の発火時点からは区別不能。よって「session_id が変わったため」のような**特定原因の断定**は出さず、**「別セッション由来、または /clear で sid が変わった自セッションの退避ファイルの可能性（区別不能）」と条件法で正直に提示**する（最頻原因は /clear の sid 変化だが、並走セッションのファイルを拾う等もあり、出力で 1 原因に断定すると誤りになりうるため）。
- **un-gcu との両立**: cwd 共有の並走セッションがあると他セッションの退避ファイルを列挙しうるが、**read-only なので un-gcu が閉じた「上書き破壊」は再導入しない**。提示した候補を読むか否かはユーザー判断に委ねる。
- **世代バックアップは増やさない**（論点4＝現状維持）。命令・制約は carry-forward が世代不問に保全済みで、追加世代の限界価値は小さい。

### PostCompact のファイル後処理は input-waiting 復帰と非同期（ccs-9pv）

PostCompact（`scripts/hooks/post-compact.sh`）は **① `working-memory.md` を stdout へ `cat`（復元注入）→ ② `working-memory.md` を `consumed.md` へ `mv`** の順で動く。`mv`（②）は復元 `cat`（①）の **後** に置く設計で、これは意図的:

- **restore landing 優先**: 復元テキストが新 context に届くこと（①）を、ファイル整理（②）より先に確実化する。
- **kill 耐性**: フックが ①→② の間で中断されても、復元は既に landing 済みで `working-memory.md` も残る（再処理可能）。逆に `mv` を先にすると中断時に復元が landing せず、ephemeral な「計画弧」がそのサイクルで失われる。

帰結として、`consumed.md` への rename（②）は **`session-state.sh` が観測する `input-waiting` 復帰と非同期**になる。`detect_state` は tmux pane の表示文字（`❯` プロンプト）だけで状態判定し、フックのファイル後処理の進捗は一切見ない。したがって **`input-waiting` が true になった瞬間に `consumed.md` がまだ生成されていないタイミング窓**が存在しうる（②は①直後の同一プロセス内なので遅延は微小だが、ゼロ保証はない）。

- **機能的実害なし**: 復元（①）は成功し、`consumed.md` は遅れて確実に生成される。次サイクルの carry-forward は PreCompact の `emit_working_memory` が `consumed.md` を読む時点（次の compaction）で効くため、その頃には rename は完了済み。
- **監視/テスト側の契約**: 親プロセスや統合テストは、`input-waiting` 復帰**直後に `consumed.md` の存在を即 assert してはならない**。出現を**有界ポーリング**で待つこと（即時 assert は偽陰性になりうる）。これは「状態判定（UI）が実完了（フック後処理）より早く true を返す」一般クラスの一例（spawn 起動時の `ccs-ldt` と同根クラス・別メカニズム）。

## 書込側 reconciliation（bd/git ground-truth 突合・ccs-8mt）

PostCompact の復元は**無検証の verbatim 注入**であり、復元側に是正段は存在しない（上記②の設計は
restore landing 優先であって内容検証ではない）。したがって Working Memory に会話の信念だけで
書かれた stale 主張（完了済みタスクを未完了と言う等）は、compaction を跨いで**そのまま再生**される。
この事故クラスは両端の reconciliation 層で塞ぐ:

- **書込側（本リポの責務）**: スキル Step 3-pre が WM 書込前に bd/git の現在値を機械 fetch し、
  LLM が計画弧の主張と突合する（不一致は外部 truth に語りを合わせる）。bd 導入リポでは計画弧の
  各 durable 項目に bd issue ID 参照を必須化し、復元側が bd 直読で検証できる形にする。
- **復元側（呼び出し元の責務・scope 外）**: 復元後に WM の主張と bd 現在値を diff する resume
  手順（機械 fetch ＋ LLM judgment の二層）は、cc-session でなく利用側のワークフロー
  （例: scriptorium の /orch-resume）が担う。本リポは session-scoped な退避/復元の transport と
  書込時の突合規律までを保証する。

## コンポーネント責務

| 責務 | 担当 |
|------|------|
| 項目を 2軸（always/default/effort × auto/confirm/hard）へ分類し carrier を決める（router）| スキル Step 1（AI 判断）|
| 書込前の bd/git ground-truth 突合（stale 主張の焼き付き防止）| スキル Step 3-pre（機械 fetch ＋ LLM 突合）|
| 恒久命令のプロジェクト CLAUDE.md 昇格提案 | スキル（提案のみ。commit は通常フロー）|
| 横断/インシデント事実の doobidoo 保存 | スキル Step 2（`mcp__doobidoo__memory_store`）|
| Working Memory の生成（2節シード）と内容マージ | スキル Step 3a（`emit_working_memory`）＋ Step 3b（Edit）|
| consumed からの命令・制約の機械 carry-forward | `scripts/lib/working-memory.sh`（`extract_effort_directives` / `emit_working_memory`）|
| Working Memory の安全網退避（スキル未実行時）| PreCompact フック（consumed があれば命令節を機械引き継ぎ）|
| Working Memory の context 注入・consumed マーク | PostCompact フック |
| ambient hints 注入 | SessionStart(compact) フック |
| `/clear` 後の退避ファイル read-only ポインタ提示 | SessionStart(clear) フック（`session-start-clear.sh`・安全網）|
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

| 変数 | 既定（session id 解決時 / 非解決時） |
|---|---|
| `WORKING_MEMORY_DIR` | `$PWD/.claude-session` |
| `WORKING_MEMORY_FILE` | `…/working-memory.<sid>.md` / `…/working-memory.md` |
| `WORKING_MEMORY_CONSUMED_FILE` | `…/working-memory.<sid>.consumed.md` / `…/working-memory.consumed.md` |
| `COMPACTION_ENABLED_MARKER` | `$WORKING_MEMORY_DIR/.compaction-enabled`（session-scoped でない）|
| `COMPACTION_LOG_FILE` | `$WORKING_MEMORY_DIR/compaction-log.txt`（session-scoped でない）|
| `WORKING_MEMORY_SESSION_ID` | 解決済み session id（可観測性のため export。空＝legacy 非 scoped 経路）|

### session-scoped 化（un-gcu・cwd=anchor 同居 2 セッションの衝突根絶）

`session-env.sh` が `WORKING_MEMORY_FILE` を `$PWD/.claude-session/working-memory.md` に**固定**解決して
いたため、cwd=anchor の複数 claude セッションが ready-compaction で**同一ファイルを奪い合い上書き**した
（2026-06-09 実害: あるセッションが別セッションの退避内容を破壊）。退避ファイル名へ **session id** を含める
session-scoped 化で構造的に根絶する。

- **session id の解決順（defense-in-depth）**: `WM_SESSION_ID`（hook が stdin の `.session_id` から設定／
  test override）> `CLAUDE_CODE_SESSION_ID`（bash tool / hook 継承 env）> 空。
  - **stdin が一次・env が二次の理由**: 全 hook の stdin JSON には `session_id` が**必ず**来る（documented・
    `/compact` 跨ぎで同一値を保持）。一方 `CLAUDE_CODE_SESSION_ID` が hook subprocess の env に継承されるかは
    **undocumented（不確実）**。よって hook は stdin を一次ソース、env を二次フォールバックにする。抽出は
    `scripts/lib/hook-session-id.sh`（`jq -r '.session_id // empty'`、jq 不在時 sed フォールバック）が担い、
    各 hook が `session-env.sh` を source する**前**に `WM_SESSION_ID` を export する。bash tool（LLM）文脈では
    `CLAUDE_CODE_SESSION_ID` が env に存在する（verified）ため二次経路が拾う。
- **slug 化（pure-bash・subprocess 不使用）**: `[A-Za-z0-9-]` 以外を除去（`..` / `/` を構造排除＝path
  traversal 不能）し 64 文字上限。slug 後に空へ縮退したら legacy 非 scoped 名へフォールバック。
- **marker / log は session-scoped にしない**: opt-in（`.compaction-enabled`）と log は**プロジェクト単位**の
  共有概念であって 1 セッションに帰属させると opt-in の意味が壊れる。
- **後方互換＝coexistence（自動移行はしない）**: 既存 legacy `working-memory.md` を scoped 名へ自動移行
  **しない**。移行は「2 セッションが同一 legacy を奪い合う」衝突を再導入する。退避ファイルは
  `lifecycle=temporary`（1 effort スコープ）なので、upgrade 直後の旧 legacy ファイル orphan は**最大 1
  サイクルの carry-forward 損失で自己回復**する（その後は scoped 連鎖が自走）。session id が解決不能な
  非 Claude Code 文脈・明示 override 時のみ legacy 非 scoped 名を使う。
- **consumed 連鎖も session-scoped**: PostCompact の `working-memory.<sid>.md → working-memory.<sid>.consumed.md`
  の rename と、次サイクル PreCompact の consumed→新 working への carry-forward は同一 `<sid>` 内で閉じる
  （別セッションの consumed を拾わない＝連鎖が混線しない）。

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
