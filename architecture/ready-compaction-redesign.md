# ready-compaction 再設計（Phase-1 実装 + Phase-2 設計）

> **このドキュメントの役割**: ubuntu-note-system 側の設計セッション（grill-me）で確定した
> ready-compaction スキルの再設計を、cc-session の実装セッションへ verbatim で引き継ぐためのハンドオフ。
> 設計の**決定とその根拠**を完全収録しているので、実装にあたり再議論は不要。
>
> **読み手（worktree-cld）への最初の指示**:
> 1. この doc を最後まで読む。
> 2. 「§7 実装タスクリスト」を上から実装する。実装は `feature-dev:feature-dev` を使う。
> 3. **§8 自分のセッション寿命**を必ず理解する（このセッションは ephemeral な worktree-cld）。
> 4. 不明点は親 anchor セッション（cc-session main）に確認できる。

---

## 0. 一行サマリ

`/compact` で失われるのは**事実ではなく「命令（手法・計画弧）」**である。これは MEMORY.md/doobidoo（＝事実の店）では原理的に解けない。ready-compaction を
**「compaction-prep の policy router 兼 effort 一時層の carrier」**として再定義し、Phase-1 で working-file を 2 分割スキーマ＋carry-forward に作り替える。hard 強制（hook）は Phase-2。

---

## 0.5 grilling 後の確定事項（2026-06-01・原案からの変更点）

> 原案（ubuntu-note-system 側の設計セッション）を cc-session 側で grill し直して確定したもの。
> **以下がこのドキュメントの他の節より優先される。** 実装はこの節に従う。

### 確定（挙動・運用が変わる実質決定）
- **A 実装手段**: feature-dev は使わない。**anchor セッション（cc-session main・安定 cwd）単独 + ダイナミックワークフロー**で実装→検証→レビュー。feature ブランチ + 通常コミット。**worktree/spawn 不使用**（設計確定済みで隔離の利得が薄く、§8 の cwd 消失リスクも回避）。→ §7 冒頭・§8 を上書き。
- **1 doobidoo の縮小**: doobidoo へは「**横断/インシデントの事実・教訓のみ**」。作業状態・進捗は doobidoo に入れず **working-file へ一本化**（ユーザーのグローバル CLAUDE.md の記憶役割分担と一致）。→ T1 Step2 確定。
- **2 CLAUDE.md 昇格先 = プロジェクト限定**: 恒久ルールの昇格提案は **プロジェクトの CLAUDE.md（追記/修正）のみ**。**ユーザースコープのグローバル CLAUDE.md は対象外**（スキルは提案も編集もしない）。横断的ルールが出ても「手動でグローバル検討を」と口頭で促すだけ。→ §5/T1 を限定。
- **3 carry-forward = ハイブリッド**: 「忘れる主体（LLM）」だけに依存させない。**シェルが consumed の「この effort を貫く命令・制約」節を機械的に抽出し新 working-file へ必ず prepend** ＋ **LLM が現在文脈とマージ・更新**。これで原案の「決定論的 carry-forward と言いつつ LLM read」の矛盾を解消。→ T1 Step3 / T2 確定。
- **4 フェーズ厳守**: Phase-1 を完成させてから Phase-2。Phase-2（hook 実ブロック・/session:enforce・marker）は**今回作らない**。`[hard候補]` タグの**付与と書式 freeze**＋設計メモへの「接続点」1 節記述のみ（記憶として残す）。→ §9 は将来着手。

### ビルド細部（実装判断・最小ドリフト方針）
- **設計メモ刷新**: `compaction-memory-model.md` を「2軸 × carrier」へ刷新、「三層」用語は廃止。ただし **sharp/fuzzy は「なぜ effort 層を外部化するのか」の根拠節**として保持（§4 の精度回復ロジックの支柱）。
- **スキーマ SSOT**: 2節スキーマの一次定義を1箇所に集約（シェルのテンプレ関数＋設計メモ）し、SKILL.md・フックは参照。現状の3重ドリフト（SKILL=3節 / pre-compact=単節 / memory-model=3節）を解消。
- **タグ/見出し書式 freeze**: 半角 `[auto]` `[confirm]` `[hard候補]`、節見出しは厳密固定文字列。
- **テスト配置**: `compaction-env.bats` は env パス据置／スキーマ assert は `pre-compact.bats`／carry-forward シェルは新規 `working-memory.bats`。
- **旧形式互換**: マイグレーションせず、旧「重要なコンテキスト」節があればフォールバック読み 1 行のみ。

---

## 1. 出発点の問い（ユーザーの当初疑問）

1. Anthropic は MEMORY.md があれば ready-compaction は不要と考えている？ それは事実か？
2. `/compact` + MEMORY.md だけで ready-compaction と同じ動きができるか？
3. スキルとしてやはり必要か？
4. 必要だとして、外部ファイルではなく MEMORY.md を使うべきか？

## 2. 検証した事実（公式 docs、`verified-from-docs`）

| 事項 | 結論 | 出典 |
|---|---|---|
| MEMORY.md auto-memory は実在 | `~/.claude/projects/<project>/memory/`。SessionStart で先頭200行/25KB **自動読込**。モデルが「将来有用」と判断したとき**自動書込**（書込タイミングはモデル裁量）| code.claude.com/docs/en/memory |
| `/compact` | 会話を要約。intent・主要概念・変更ファイル・エラーと修正・**pending tasks** を保存、tool出力と中間推論は圧縮。auto-compaction あり | context-window, how-claude-code-works |
| compact 後の再注入 | **CLAUDE.md（project-root）と auto-memory(MEMORY.md) は disk から自動再注入**。path-scoped/nested CLAUDE.md は次の該当ファイル read まで遅延 | context-window「What survives compaction」|
| MEMORY.md は machine-local | "not shared across machines"。`autoMemoryDirectory` で場所変更は可能 | memory |
| Hooks | PreCompact（manual/auto, block可）/ PostCompact（manual/auto, block不可）/ SessionStart（startup/resume/clear/**compact**）すべて実在 | hooks |
| 「memory は手動外部化を不要にする」とAnthropicは言っているか | **docs-silent**。公式が compaction 生存用に挙げるのは CLAUDE.md。auto-memory は "cross-session learnings の蓄積" 用 | memory |

→ **当初疑問①の答え: 「MEMORY.md で ready-compaction 不要」は裏付けのない仮説。** Anthropic はそう言っていない。

## 3. 根本の再フレーム（grill の最大の収穫）

ユーザーが compaction を越えて失って困っていたのは：
- 「session:spawn 先で feature-dev を使って実装しろ」
- 「ダイナミックワークフローで PR レビューしてから merge しろ」

**これらは事実（fact）ではなく手続き的命令（imperative）**。`/compact` の要約器は「特定の tool 出力に紐づかない ambient な命令（＝計画の弧・横断的手法）」を構造的に deprioritize するため、これらが落ちる。直前タスク自体は比較的保たれる。落ちるのは**メタ階層（計画の流れ＋貫く手法）**。

帰結：
- 命令を MEMORY.md/doobidoo（事実の店）に入れる発想は**カテゴリ錯誤**。→ 当初疑問②④の根本理由。
- Claude Code 設計では **命令=CLAUDE.md の仕事 / 事実=memory の仕事**。ユーザーの失った手法は命令なので、native の生存機構は本来 CLAUDE.md 系（自動再注入）。
- ただしユーザーの手法は **条件付き・effort スコープ**（重い操作なので無条件には適用できない）。→ 「永続 CLAUDE.md」でも「一時 working-file」でもピッタリ来ない＝**effort-lifetime の命令**という、native に存在しないカテゴリ。**これが ready-compaction の非代替コア**。

## 4. ユーザー運用の確定事実（設計制約）

- **毎回必ず ready-compaction を実行してから compact している** → 4.8 で「スキル無し」の反証データが無い（後述 §6 の caveat）。
- **1M でも精度低下のため ~50% で手動 compact、今後もこの運用** → (a) **auto-compaction はほぼ発火しない**ので PreCompact 安全網は低価値。(b) compact の目的は容量ではなく**精度回復**＝fuzzy な蓄積を捨て sharp な足場だけ温存したい＝**sharp/fuzzy 分離そのもの**。スキルの価値命題を強める。
- **複数マシンから 1 プロジェクトを git remote 経由で開発**（同時編集はしないが、こっちのマシン→あっちのマシンで触る）。→ **git が同期層**。恒久プロジェクト知識は git（CLAUDE.md/docs）に乗せるのが本命（自動注入＋クロスマシン同期）。**MEMORY.md は machine-local なので恒久知識を入れると別マシンで stranded**＝このユーザーでは MEMORY.md の出番なし。
- doobidoo は中央サーバ（ipatho1）。ユーザー自身のルールで「インシデント・他ホスト知見」用＝プロジェクト固有知識の本来の置き場ではない。

## 5. 最終アーキテクチャ（2軸 × carrier）

**軸1 適用範囲**: `always`（無条件）/ `default`（軽微は LLM 判断で除外）/ `effort`（この作業の間だけ。**presence「見ている間だけ」は effort に統合**＝effort 命令内の任意条件として表現）

**軸2 強制**: `auto`（LLM 自己適用）/ `confirm`（ユーザー確認）/ `hard`（物理ブロック）

| 区分 | carrier | 生存機構 | 所有者 |
|---|---|---|---|
| 恒久命令 `always`/`default` × auto/confirm | **CLAUDE.md(git)** | 自動注入＋git 同期 | 通常コミットフロー（ready-compaction は**昇格提案**のみ）|
| 恒久・横断/インシデントの**事実** | doobidoo | 中央サーバ | （本来用途に縮小）|
| **`effort` × auto/confirm** | **working-file** | skill が復元＋carry-forward | **ready-compaction（コア）** |
| any × **`hard`** | **PreToolUse hook + marker** | config（非圧縮）| **Phase-2**（skill は**候補マーク**のみ）|
| ~~MEMORY.md~~ | — | — | このユーザー構成では出番なし |

**重要な切り分け**: 「hard を除いた部分 ≠ ready-compaction」。non-hard はさらに「恒久→CLAUDE.md(native, skill 不要)」と「effort→working-file(=skill)」に割れる。**ready-compaction が carrier として所有するのは effort 一時層だけ**。恒久と hard は **検出して委譲/マークするだけ**で自前で抱え込まない（CLAUDE.md/hook を再発明しない）。

## 6. honest な制約（実装でも保持すること）

- **「4.8 で load-bearing」は反証不能のまま**。ユーザーは毎回スキルを使うので反例が無い。first-principles（要約器が ambient 命令を落とす）で正当化している。唯一の検証＝低リスク長セッションで一度スキルを抜いて compact し挙動観察。実装はこの不確実性を前提に「過剰投資しない」。
- **`confirm` は soft 止まり**（LLM が確認を求めるだけ）。**confirm の firm 化（hook での ask 強制）は Phase-2 スコープ外**＝当面 soft 維持（§9.6 C-1 で確定。Claude Code ネイティブ権限プロンプトと機能が重複するため）。Phase-2 が hook 化するのは **hard のみ**。
- **hard 化は gate-point（単一の不可逆ツール呼び出し）を持つ命令のみ**可能。「merge 前にレビュー」は `gh pr merge` という gate があり可。「実装は spawn+feature-dev」は多数の Edit/Write に分散し gate が無く hard 不可 → default/auto に格下げ。

---

## 7. 実装タスクリスト（Phase-1）

対象リポ: cc-session。実装は **anchor 単独 + ダイナミックワークフロー**（§0.5-A。feature-dev は使わない）で行い、各変更後にコミット（git スキル準拠、Conventional Commits 日本語）。

### T0. この設計 doc をブランチに載せる
- 本ファイルは main checkout の working tree に untracked で置かれている。worktree ブランチへコピーして最初のコミットにする:
  `cp /home/shuu5/projects/local-projects/cc-session/architecture/ready-compaction-redesign.md architecture/`（worktree 内で）→ commit。
- （main checkout 側の untracked コピーは merge 後に重複するので、worktree で commit したら main 側のファイルは削除してよい。）

### T1. `skills/ready-compaction/SKILL.md` 改訂
- **Step 1（外部化の判断）→ policy router 化**。会話から抽出した各項目を分類:
  - 恒久 standing rule → 「**プロジェクトの** CLAUDE.md(git) へ追記/修正しては？」と**提案**（commit は通常フローへ委譲）。**グローバル CLAUDE.md は対象外**（§0.5-2。横断的なら手動検討を口頭で促すのみ）。
  - 横断/インシデントの事実 → doobidoo（縮小した用途）。
  - effort 命令・状態 → working-file。
  - **hard 候補**（gate-point を持ち、歪みを許したくない命令）→ working-file に `[hard候補]` タグでマーク（実強制は `pretooluse-enforce.sh`＝§9.6/Phase-2 で実装済み。`/session:enforce` で gate 化）。
- **Step 2（doobidoo 保存）→ 降格**。「作業状態を全部 doobidoo」をやめ、**横断/インシデントの事実のみ**。プロジェクト固有の恒久知識は「git にコミット」へ誘導。
- **Step 3（Working Memory 退避）→ スキーマ2分割＋ハイブリッド carry-forward**（§7.4 のスキーマ、§0.5-3）。
  - 退避前に `working-memory.consumed.md` が存在すれば、その「この effort を貫く命令・制約」節を **シェルヘルパーが機械的に抽出して新 working-file へ必ず prepend**（決定論的に「絶対落とさない」）＋ **LLM が現在文脈とマージ・更新**（古い項目の削除・追記）。＝「忘れて続けていった」の治療。
- **Step 4（compaction 提案）**: 大筋維持。
- **禁止事項/注意**: 「working-file に恒久知識を入れない（git へ）」「MEMORY.md を carrier に使わない」を追記。

### T2. working-memory スキーマの 2 分割
```markdown
---
externalized_at: "<ISO8601>"
trigger: manual | auto_precompact
lifecycle: temporary
---

## 計画弧・次のステップ
<!-- ephemeral。毎サイクル再生成。今どこにいて次に何をするか -->

## この effort を貫く命令・制約
<!-- persistent within effort。consumed から決定論的に carry-forward。
     各項目に強制モードをタグ: [auto] / [confirm] / [hard候補] -->
- [auto] 例: 軽微でなければ spawn+feature-dev で実装
- [hard候補] 例: merge 前にレビュー必須（実強制は `pretooluse-enforce.sh`＝Phase-2 実装済み。`/session:enforce` で gate 化）
```

### T3. フック改訂（最小）
- `scripts/hooks/pre-compact.sh`: 安全網スケルトンを**新スキーマ2節**に更新（現状は「作業状態」単節）。auto_precompact 時もスキーマ整合を保つ。
- `scripts/hooks/post-compact.sh`: 現状の「working→consumed へ mv」は維持（carry-forward の供給源になる）。復元時の見出し文言をスキーマ2節前提に微調整。
- `scripts/hooks/session-start-compact.sh`: 大筋維持。ambient hints に「consumed の命令・制約節を確認せよ」を一行追加可。

### T4. `architecture/compaction-memory-model.md` 更新
- 三層記憶モデルを **2軸 × carrier モデル**（§5）へ刷新、または追補。
- 「imperatives vs facts」「presence→effort 統合」「ready-compaction = router + effort carrier」「Phase-2 hook への接続点」を明記。

### T5. テスト追従
- スキーマ2分割・carry-forward・router 分類のテストを追加/更新。
  実装では `tests/working-memory.bats`（carry-forward シェル）/ `pre-compact.bats` / `post-compact.bats` /
  `session-start-compact.bats` に分割し、既存 `compaction-env.bats` も残置（§0.5 ビルド細部に従う）。

### T6. ドキュメント整合
- README.md / SKILL.md description / 関連 docs を新責務に合わせ更新。

---

## 8. 自分（worktree-cld）のセッション寿命 ── 必読

> **【§0.5-A で無効化】** 確定した実装手段は anchor 単独（worktree 不使用）のため、本節の worktree-cld 前提は**今回は適用されない**。将来 worktree 方式で実装する場合のみ有効な参考情報として残す。

- **このセッションは ephemeral な worktree-cld**。cwd は `cc-session/.worktrees/<name>`。
- **merge 完了後この worktree は `git worktree remove` で削除され、その瞬間このセッションの cwd が消えて機能停止する**（getcwd ENOENT、git/hook 全滅）。これは正常な寿命。
- **文脈の本体は親 anchor セッション（cwd=cc-session main、安定）＋この doc（安定パス）に在る**。だからこのセッションが死んでも設計は失われない。
- 従って:
  - **長期に残すべき成果（設計・決定・進捗）は必ず git にコミット&push する**（worktree 削除で消えないため）。worktree のローカル未コミット状態に重要情報を留めない。
  - worktree を消す/移すのは**親 anchor 側の判断**。このセッションから自分の cwd worktree を削除しない。
  - 作業が中断しそうなら、push 済みであることを確認してから離れる。

## 9. Phase-2 設計（hard 強制 / hook policy システム）

> Phase-1 完了後に着手。ユーザーは最終的にこの hard 層まで含めた完全な spectrum を望んでいる。

### 9.1 目的
`always × hard`（「わずかな歪みも許さない」）の命令を、soft-text（CLAUDE.md/working-file）の確率的遵守ではなく **PreToolUse hook で決定論的に強制**する。cc-session/グローバルに既存の「破壊的 git/tmux 操作を PreToolUse hook がブロック」パターンの拡張。

### 9.2 policy スペック
```
directive: <命令の説明>
applies_when: always | default-unless-trivial | this-effort   # presence は this-effort に統合
enforce:     auto | confirm | hard
gate:        <hard の場合のみ: ブロック対象のツール/コマンド、例 "gh pr merge", "git push", "git merge">
marker:      <hard の場合のみ: 解除条件マーカーのパス、例 .claude-session/pr-<N>-reviewed>
```
> **注**: 上の `marker` 例は §9.6 C-4a で **操作インスタンス単位**（`pr-<N>-<sha8>-reviewed`、PR番号＋head SHA で keying）に精緻化されている。grilling 後は §9.6 が優先。

### 9.3 強制機構（hard）
- **PreToolUse hook** が `gate` にマッチするツール呼び出しを横取りし、`marker` が存在しなければ `decision: block`＋代替ルート提示で拒否。
- `marker` は gate を正当化する作業（例: workflow PR レビュー）の完了時に書かれる。
- 既存フック流儀を踏襲: opt-in マーカーゲート、`set -e` 不使用、path-validate、IO 握り潰し（フック失敗で正規操作をブロックしない設計だが、hard の場合は「マーカー不在＝ブロック」が意図的挙動である点に注意）。

### 9.4 制約（honest）
- **gate-point を持つ命令のみ hard 化可**。merge/push/deploy は可。拡散的な「実装は spawn で」は gate が無く不可 → `default/auto` 止まり。
- hook は config（会話履歴外）なので compaction で消えない＝reliability が機構で保証される。これが soft-text に対する本質的優位。

### 9.5 router 連携
- ready-compaction の Step 1 router が `hard候補` を検出 → Phase-2 では「この directive を hook policy に登録するか？」をユーザーに提案 → 承認時に policy 生成＋hook 有効化。
- policy の登録/生成/有効化を担う小さなコマンド（例 `/session:enforce` 仮称）を Phase-2 で新設する想定。

### 9.6 grilling 後の確定事項（2026-06-02・着手前 grill）

> Phase-1 完了（PR #2 merge, main `7ac6915`）後、Phase-2 着手前に anchor セッション（cc-session main）で grill-me し確定。
> **以下が §9.1〜§9.5 および §6 の関連記述より優先される。** 実装はこの節に従う。
>
> **実装状況: 2026-06-02 に Phase-2 実装完了**（ブランチ `feat/phase2-hard-enforce`。`[confirm]` ゲート＝ユーザー承認済み）。
> 下の P2-T1〜T8 はすべて実装済み（各タスクに実ファイル名を併記）。実装時の確定事項:
> - hook 名は **`pretooluse-enforce.sh`**（§9.6 P2-T2 の SSOT 表記を採用。設計合成内の `enforce-bash.sh` はドリフトのため不採用）。
> - `subject_re` は **POSIX ERE 安全形**（bash `=~`）に確定。PCRE 非捕捉グループ `(?:...)` は使わず、対象は **capture group 1**。
> - `{subject}` トークンを `sha_cmd` と `unlock_hint` の両方で統一（合成案の `${subject}` 表記から変更）。
> - hot path（allow 経路）の jq 呼び出しを **health 1 回 + match 1 回**に最適化。SHA キャッシュは安全性の穴のため**不採用**（block 経路で都度 fresh 取得）。
> - 例 policy は `architecture/enforce-policy.example.json`（スキーマの正典）。

確定した設計判断（C-1〜C-10）:

- **C-1 強制モデル = hard(deny-block) のみ**。confirm は soft 維持で **firm 化は Phase-2 スコープ外**（§6 を本決定に合わせ修正済み。理由: ネイティブ権限プロンプトと重複、スコープ規律）。
- **C-2 policy の SSOT = 独立永続ファイル** `$PWD/.claude-session/enforce-policy.*`。`[hard候補]` タグは**検出トリガのみ**、`/session:enforce` がそこから policy へ materialize。working-memory 直読みは PostCompact で consumed へ mv され揮発し §9.4「config だから消えない」優位と矛盾するため**不採用**。
- **C-3 gate 変換 = LLM 提案 → 人間確定**。directive の "gate:" ヒントから LLM が下案、人間が確認/編集して policy ファイルへ確定。**人間 ratified が信頼境界**（取りこぼし＝危険操作を黙って通す最悪 failure を防ぐ）。
- **C-4a marker scope = 操作インスタンス単位**（例 `pr-<N>-<sha8>-reviewed`、PR番号＋head SHA で keying）。対象/SHA が変われば再 gate ＝「一度で永久解除」を構造的に防止。
- **C-4b / C-10 marker 作成 = 人間の生シェルのみ（規律ベースの信頼境界）**。`/session:enforce` は**認可（policy 生成）専用**で unlock は担わない。unlock は hook が stderr で提示する helper / `touch` を**ユーザーが `!` で実行**。lib は marker を作るコードパスを持たない（読み取り専用）が、**marker は単なる空ファイルなので Claude も技術的には Bash/Write で作成可能**。したがって本層が保証するのは「沈黙の・偶発的な自己認可の防止」＝Claude は通常 marker を持たず block され、人間に必ず surface する＋認可は可監査な明示操作になる、という**摩擦と可視性**であって、決然と回避する LLM を**暗号学的に**止めるものではない（marker dir の権限分離等は将来の hardening 課題。§9.7 の adversarial レビュー HIGH#5 参照）。
- **C-5 opt-in = policy ファイルの存在**。不在/空 → hook は **no-op（allow）**。専用 marker も `.compaction-enabled` 流用も不要（流用は compaction 使用済み全プロジェクトで誤ブロック）。
- **C-6 障害時 = fail-closed (scoped)**。policy 在りで破損/jq 不在/hook 障害時は**内蔵 danger list**（`git push`/`git merge`/`gh pr merge`/deploy 系）のみ block ＋大警告、他 Bash は通す。compaction フック（fail-open）とは**あえて規約を分ける**（性質が違うため）。
- **C-7 bypass = 人間操作のみの多層**。通常=marker 作成、緊急=policy 削除/空化 or `SESSION_ENFORCE_OFF=1` を**ユーザーが**セット。Claude は実行せず提示のみ（git ガードの代替ルート流儀）。
- **C-8 登録先 = cc-session `hooks.json` に PreToolUse:Bash 追加**（`${CLAUDE_PLUGIN_ROOT}/scripts/hooks/pretooluse-enforce.sh`）。policy-presence opt-in で no-op になるため全プロジェクト波及は無害。**グローバル `settings.json` は触らない**。既存グローバル `git-destructive-guard.sh` と共存（両者 PreToolUse:Bash、いずれかが deny で成立、条件が別）。
- **C-9 gate 対象 = Bash コマンド限定スタート**。既知 hard gate（merge/push/deploy）は全て Bash。Edit/Write は拡散的で §9.4 の単一 gate-point を満たさず hard 不適。MCP は `tool_input` スキーマがサーバ毎で要確認のため後回し（policy は将来拡張可能に設計）。

補足（C 番号外・実装時に最終化する細部）:

- **policy フォーマット**: JSON 推奨（jq 既使用・`window-manifest.json` と一貫・追加依存なし）。yaml は人間編集性で候補だがパーサ依存増のため非推奨。可逆な実装詳細。
- **コマンドマッチの誤爆対策**: gate マッチは部分文字列/正規表現一致のため、flag 名や gate 語を含む `grep`/`echo`/コメント等を誤ブロックしうる（テンプレ `git-destructive-guard.sh` 自身が L10 で同リスクを注記。本レビュー中に実際に発生）。`git-destructive-guard.sh` の**空白正規化＋コメント除去**（`tr -s` ＋ `#` 以降除去）を踏襲し、残る誤爆は C-7 bypass ＋ C-3 の精緻な人間 ratified gate パターンで緩和する。

hook の判定フロー（1 Bash 呼び出しごと、C-2/4/5/6 の合成）:

1. policy 不在/空 → **allow**（no-op）
2. command が gate に不一致 → allow
3. gate 一致 ＆ 操作インスタンス marker 在り → allow
4. gate 一致 ＆ marker 不在 → **block**（exit 2 ＋ stderr: どの gate か・理由・ユーザーが叩く unlock コマンド）
5. policy 在り＋破損/jq 不在/障害 → **fail-closed (scoped)**: 内蔵 danger list のみ block＋大警告、他は allow

派生実装タスク（Phase-2・**2026-06-02 実装完了**。✅＝実装済み、実ファイル名を併記）:

- ✅ **P2-T1** policy フォーマット確定（`enforce-policy.json`／例は `architecture/enforce-policy.example.json`）＋パーサ lib `scripts/lib/enforce-policy.sh`（フォーマット/マッチ/marker 導出の SSOT。`ep_*` 関数群。marker は読み取りのみ＝作成しない）。`session-env.sh` に `ENFORCE_POLICY_FILE` / `ENFORCE_MARKER_DIR` / `ENFORCE_SHA_TIMEOUT` を追加。tests: `tests/enforce-policy.bats`。
- ✅ **P2-T2** `scripts/hooks/pretooluse-enforce.sh`（5 ステップ判定フロー・fail-closed scoped・stderr bypass。`git-destructive-guard.sh` 型: `INPUT=$(cat)`＋jq `.tool_input.command`＋exit 2＋空白正規化/コメント除去〔誤爆対策〕。lib 不在時は no-op）。tests: `tests/pretooluse-enforce.bats`。
- ✅ **P2-T3** `hooks/hooks.json` に PreToolUse:Bash 登録（`${CLAUDE_PLUGIN_ROOT}/scripts/hooks/pretooluse-enforce.sh`、timeout 10000）。
- ✅ **P2-T4** `scripts/enforce-unlock` 生シェル helper（SHA 導出＋操作インスタンス marker 作成。Claude は呼ばない運用。gate 取り違え防止・fail-closed では作らない）。tests: `tests/enforce-unlock.bats`（hook↔helper の marker 名一致と SHA 前進での自動失効を往復検証）。
- ✅ **P2-T5** `skills/enforce/SKILL.md`（`/session:enforce` 認可フロー: `[hard候補]` 検出→LLM 提案→人間確定→policy 書き込み。unlock は担わない）。
- ✅ **P2-T6** ready-compaction router 連携（`skills/ready-compaction/SKILL.md` の carrier/router 行を更新し `[hard候補]` 検出時に `/session:enforce` を提案）。
- ✅ **P2-T7** doc 整合（本節・§6・`compaction-memory-model.md`・`README.md`・`CLAUDE.md`・両 `SKILL.md`）。
- ✅ **P2-T8** bats（policy parse / gate match / marker 有無 / TTL / fail-closed scoped / opt-in no-op / unlock helper / hook 統合）。`tests/{enforce-policy,pretooluse-enforce,enforce-unlock}.bats` に分割。

### 9.7 実装後 adversarial レビューの結果（2026-06-02・マージ前ゲート）

[hard候補] 命令「PR merge 前に adversarial レビュー」に従い、実装直後に 6 次元（bypass / fail-closed / 誤爆 / marker 健全性 / shell 安全 / spec 準拠）× 各 finding 懐疑検証のレビューを実施。判定は **CONDITIONAL**（現状マージ不可）で、以下の critical/high を修正してから再 GREEN（255/255）:

- **[CRIT] `#` による 1 文字 bypass**: `ep_normalize` がコメント（`#` 以降）を除去していたため `echo "#" && git push` で gate 語を判定文字列から落とせた。→ **コメント保持マッチへ修正**（git-destructive-guard の NORM 意味論に合わせる）。over-block 側に倒すが安全。
- **[CRIT] fail-closed 不達 2 系統**: (a) 無効 ERE の gate が `[[ =~ ]]` で常に偽になり黙って無効化（health=active のまま）→ **health で全 ERE を構文検証し corrupt 化**。(b) session-env のみ欠落で空 health が hook の `case` を素通り → **lib に ENFORCE_* 安全デフォルトの再フォールバック＋hook の `case` に `*)` fail-closed**。
- **[HIGH] gate 語彙の表記揺れ貫通**: 絶対パス `/usr/bin/gh`・`git -C`・フラグ・引用符ラップで gate を外せた（builtin danger も同様）→ **境界を `(^|[^[:alnum:]_-])…([^[:alnum:]_-]|$)` ＋ `( +[^ ]+)*` フラグ吸収へ強化**。
- **[HIGH] git-push の認可スコープ漏洩**: token subject_re が flag 有無で remote/branch を取り違え、`origin main` の承認が `origin 全 branch` へ漏れた → **git-push を command-hash 戦略へ**（コマンド全体＝remote・refspec・force 有無を keying）。
- **[HIGH] C-4b 文言の乖離**: marker は空ファイルで Claude も技術的に作成可能 → **doc を正直化**（信頼境界は「人間が生シェルで叩く規律」＋摩擦＋可監査性。沈黙の自己認可は防ぐが暗号学的barrierではない。C-4b 注記参照）。

あわせて MEDIUM/LOW を一部前倒し: pr-merge subject_re の flag-before-number 対応（`merge[^0-9]*#?([0-9]+)`）、裸 `deploy` トークン除去（`git commit -m deploy` 誤爆解消）、subject 検証の先頭ダッシュ禁止、`ep_marker_valid` の stat 失敗時 block（fail-open 是正）。

**残る follow-up（beads epic `ccs-5p4` で追跡）**: settings.json env 経由の恒久 OFF（C-7 の単一 env 依存・`ccs-5p4.2`）、marker dir の権限分離による hard 化（HIGH#5 の技術強制への格上げ・`ccs-5p4.4`）。**✅ 解消済**: (1) TTL 未指定 gate の無期限化（`ccs-5p4.1`）＝`ep_policy_health` が sha_keyed≠true gate に有限 TTL を必須化し、無ければ corrupt→fail-closed scoped に倒す（ランタイムと同一の `ep_gate_ttl` で判定。Position B）。(2) `.match` schema 検証（`ccs-5p4.3`＋`ccs-5p4.6`）＝probe で `.match` を object・`any_re` を非空の文字列配列に必須化（substring-only の .all 単独 gate と、`any_re`=object 等の沈黙 fail-open を corrupt 化）。`.key`・`.match` 型不正や jq index abort も probe ガード＋ループ rc 捕捉で順序非依存に corrupt へ surface。(3) TTL 値の hardening（`ccs-5p4.5`）＝`ep_gate_ttl` を 10 進正規化（先頭ゼロの8進誤解釈/監査汚染を解消）＋桁数/上限（既定 30 日 `ENFORCE_TTL_MAX_SEC`）ガード（巨大値の事実上恒久 unlock を空→corrupt 化）。

健全と再確認された点（誤検出として却下含む）: 決定性・hook↔helper の marker 名一致・SHA/subject の fail-closed 伝播（exit 3/4）・argv injection 防御・`%q`・`_ep_slug` のパストラバーサル無効化・lib が marker を作らない（C-4b は lib レベルで SOLID）・ReDoS なし。

#### 第2ラウンド検証（修正コミット後・実プローブ）

マッチングのコア（境界 ERE・command-hash・ERE 検証・fail-closed 経路）を実質変更したため、修正面に絞った第2ラウンド検証を実施し、さらに以下を発見・対処（260/260 GREEN）:

- **[CRIT] ERE 検証エンジン乖離**: health の ERE 構文検証が `grep -qE` だったため、先頭量化子 `*terraform` 等を grep は valid 扱い（rc=1）する一方 bash `[[ =~ ]]` は rc=2 で扱い、無効 ERE の gate が corrupt 化されず**沈黙失効**（fail-open）。→ **検証を実マッチと同一エンジン（bash `[[ =~ ]]` の rc=2）へ統一**。`broken(re`/`[unclosed` だけでなく先頭量化子も検出。
- **[CRIT] シェル難読化での gate 貫通**: `g'i't push`・`git p\ush`・`git${IFS}push`・`terra'f'orm apply` 等が正規化後もリテラルのまま残り gate を外せた（builtin danger も同様）。→ **ep_normalize に de-obfuscate を追加**（`"' \` 除去＋`${IFS}`→空白）。これで引用符/エスケープ/`${IFS}` を捕捉。
- **[残存・脅威モデル外]**: 変数間接（`m=push; git $m`）・コマンド置換 `$(...)` は実行なしに解決できず、本マッチャ（および同型のグローバル `git-destructive-guard.sh`）の原理的限界。**本層の脅威モデルは「沈黙の・偶発的な自己認可の防止＋摩擦＋可監査性」（Position B）**であり、決然と回避する LLM（難読化・変数間接・marker 直接 touch・Write）は対象外と確定（C-4b と整合）。暗号学的barrierが必要なら marker dir の権限分離等の別設計が要る（将来課題）。
- **[要方針確認・LOW]**: pr-merge marker は同一 PR・同一 head SHA ならマージ方式フラグ（`--squash`/`--admin` 等）を区別しない。`--squash` の unlock が TTL 内に `--admin`（レビュー要件 bypass）も認可しうる。許容可否は運用方針判断（フラグを keying に含めるかはユーザー確定事項）。

---

## 10. 参考：現行実装の所在（変更前の状態）
- スキル: `skills/ready-compaction/SKILL.md`
- 設計: `architecture/compaction-memory-model.md`
- フック: `scripts/hooks/{pre-compact,post-compact,session-start-compact}.sh`
- env/パス SSOT: `scripts/lib/session-env.sh`（`WORKING_MEMORY_DIR` 等。既定 `$PWD/.claude-session`）
- テスト: `tests/compaction-env.bats`（再設計後は `working-memory.bats` / `pre-compact.bats` / `post-compact.bats` / `session-start-compact.bats` を追加）
- 既定の working-file: `$PWD/.claude-session/working-memory.md` / consumed: `working-memory.consumed.md`
- opt-in マーカー: `$PWD/.claude-session/.compaction-enabled`
