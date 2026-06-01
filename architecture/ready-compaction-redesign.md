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
- **`confirm` は Phase-1 では soft 止まり**（LLM が確認を求めるだけ。firm 化＝hook＝Phase-2）。
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
  - **hard 候補**（gate-point を持ち、歪みを許したくない命令）→ working-file に `※hard化候補(Phase-2 hook)` とマーク。
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
- [confirm] 例: merge 前にユーザー確認（※hard化候補 → Phase-2 hook）
```

### T3. フック改訂（最小）
- `scripts/hooks/pre-compact.sh`: 安全網スケルトンを**新スキーマ2節**に更新（現状は「作業状態」単節）。auto_precompact 時もスキーマ整合を保つ。
- `scripts/hooks/post-compact.sh`: 現状の「working→consumed へ mv」は維持（carry-forward の供給源になる）。復元時の見出し文言をスキーマ2節前提に微調整。
- `scripts/hooks/session-start-compact.sh`: 大筋維持。ambient hints に「consumed の命令・制約節を確認せよ」を一行追加可。

### T4. `architecture/compaction-memory-model.md` 更新
- 三層記憶モデルを **2軸 × carrier モデル**（§5）へ刷新、または追補。
- 「imperatives vs facts」「presence→effort 統合」「ready-compaction = router + effort carrier」「Phase-2 hook への接続点」を明記。

### T5. `tests/compaction-env.bats` 追従
- スキーマ2分割・carry-forward・router 分類のテストを追加/更新。

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

---

## 10. 参考：現行実装の所在（変更前の状態）
- スキル: `skills/ready-compaction/SKILL.md`
- 設計: `architecture/compaction-memory-model.md`
- フック: `scripts/hooks/{pre-compact,post-compact,session-start-compact}.sh`
- env/パス SSOT: `scripts/lib/session-env.sh`（`WORKING_MEMORY_DIR` 等。既定 `$PWD/.claude-session`）
- テスト: `tests/compaction-env.bats`
- 既定の working-file: `$PWD/.claude-session/working-memory.md` / consumed: `working-memory.consumed.md`
- opt-in マーカー: `$PWD/.claude-session/.compaction-enabled`
