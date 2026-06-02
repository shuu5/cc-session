# cc-session

汎用 Claude Code セッション管理プラグイン。tmux ウィンドウでの Claude Code セッションの **spawn / fork** と状態検出、**ready-compaction**（compaction-prep の policy router 兼 effort 一時層 carrier）、および **enforce**（hard 強制層: PreToolUse(Bash) hook が gate 未通過の危険操作を deny-block する。policy 存在で opt-in）を提供する。特定プロジェクトに依存しない（namespace は環境変数で切り替え可能）。

## Beads Issue Tracker (bd)

タスク追跡は **bd (beads)**。SessionStart hook が `bd prime` で全ワークフロー文脈を毎セッション注入する（SSOT = `.beads/PRIME.md`）。本節は bd 未導入時のフォールバック。

- **タスク = beads / 知識 = doobidoo**: 永続・横断の作業は bd issue で追跡。知見は doobidoo に保存し、**`bd remember/recall/memories` は使わない**。
- 終了前に `bd close` → `bd dolt push`。コードは標準 PR ワークフロー（`main` 直 push 禁止）。

## レビュー・検証方針（このプロジェクトの必須ルール）

セキュリティ/正しさにクリティカルな変更（`scripts/hooks/` ・ `scripts/lib/` ・ enforce 層 ・ compaction フック等）は、**main へ merge する前に ultracode の多次元 adversarial レビュー＋検証を必須**とする。

- **Workflow ツール**で「観点別レビュー → 各 finding を懐疑的検証（実コマンドで突破/退行を試行）→ 合成判定」を回す。**bats が全 green でもレビューは independent に行う**（テストが誤挙動を encode していることがあるため。実例: Phase-2 で 260 green のまま `#` bypass・無効 ERE 沈黙失効・認可スコープ漏洩が CONFIRMED された）。
- セキュリティのコア（マッチング・fail-closed 経路・marker 導出等）を**実質変更したら再レビュー必須**（修正で新たな穴が出るため。実例: 第1ラウンド修正後の第2ラウンドで ERE エンジン乖離・シェル難読化が判明）。
- 判定が **CONDITIONAL / NO-GO の間は merge しない**。CONFIRMED な fail-open は merge 前に解消する。可能なら merge 後に end-to-end スモークで実機確認する。
- 些末な doc / コメント / 設定変更はこの限りではない。

## 構成

- `skills/` — `spawn` / `fork` / `ready-compaction` / `enforce` スキル（`/session:spawn` 等で起動）
- `scripts/` — セッション管理スクリプト群（`cld`, `cld-spawn`, `cld-fork`, `session-state.sh`, `session-comm.sh`, `session-name.sh`, `window-manifest.sh` 等）＋ `enforce-unlock`〔hard 強制の marker を人間が生シェルで作る helper〕
- `scripts/hooks/` — compaction フック（`pre-compact.sh` / `post-compact.sh` / `session-start-compact.sh`）＋ `pretooluse-enforce.sh`〔hard 強制 PreToolUse(Bash) hook〕
- `scripts/lib/` — 共有ライブラリ（`session-env.sh`, `path-validate.sh`, `compaction-indicators.sh`〔auto-compaction フェーズ名の SSOT〕, `working-memory.sh`〔2節スキーマ＋carry-forward の SSOT〕, `enforce-policy.sh`〔hard 強制の policy/マッチ/marker 導出の SSOT〕）
- `hooks/hooks.json` — フック登録（PreToolUse:Bash / PreCompact / PostCompact / SessionStart:compact、自動検出）
- `architecture/` — 設計ドキュメント（`compaction-memory-model.md`〔記憶外部化の設計 SSOT〕, `ready-compaction-redesign.md`〔フェーズ別の決定根拠・§9.6 が hard 強制の設計 SSOT〕, `enforce-policy.example.json`〔policy スキーマの正典例〕, `window-manifest-v1.schema.json` 等）
- `tests/` — bats テスト

## namespace / 環境変数

状態・ロック・manifest のパスは `scripts/lib/session-env.sh` が一元解決し、すべて環境変数で上書き可能。デフォルトは中立な `claude-session` namespace。

| 変数 | デフォルト |
|---|---|
| `SESSION_STATE_DIR` | `~/.local/state/claude-session` |
| `SESSION_SHARE_DIR` | `~/.local/share/claude-session` |
| `WINDOW_MANIFEST_FILE` | `$SESSION_SHARE_DIR/window-manifest.json` |
| `SESSION_LOCK_FILE` | `$SESSION_STATE_DIR/window-create.lock` |
| `SESSION_MAP_DIR` | `$SESSION_STATE_DIR` |

`ready-compaction` の Working Memory 系は会話/プロジェクト固有のため、既定で**プロジェクトローカル**（`$PWD` 基準）に置く:

| 変数 | デフォルト |
|---|---|
| `WORKING_MEMORY_DIR` | `$PWD/.claude-session` |
| `WORKING_MEMORY_FILE` | `$WORKING_MEMORY_DIR/working-memory.md` |
| `WORKING_MEMORY_CONSUMED_FILE` | `$WORKING_MEMORY_DIR/working-memory.consumed.md` |
| `COMPACTION_ENABLED_MARKER` | `$WORKING_MEMORY_DIR/.compaction-enabled`（フック発火の opt-in マーカー）|
| `COMPACTION_LOG_FILE` | `$WORKING_MEMORY_DIR/compaction-log.txt` |

## ready-compaction の責務（policy router 兼 effort carrier）

`ready-compaction` は項目を **2 軸（適用範囲 always/default/effort × 強制 auto/confirm/hard）** で分類し carrier へ委譲する。自前で抱えるのは **effort 一時層（Working Memory）だけ**:

- **恒久命令**（このリポで常に真の手法・規約）→ **このプロジェクトの CLAUDE.md(git) へ追記/修正を昇格提案**（提案のみ。commit は通常フロー。**ユーザースコープのグローバル CLAUDE.md は対象外**＝スキルは自動提案も編集もしない）
- 横断/インシデントの事実 → doobidoo ／ effort 命令・作業状態 → Working Memory（2 節スキーマ＋carry-forward）／ hard 候補 → `[hard候補]` マーク → `/session:enforce` で gate 昇格を提案（実強制は `pretooluse-enforce.sh`）

2 節スキーマ・タグ書式・carry-forward の SSOT は `scripts/lib/working-memory.sh`。設計詳細は `architecture/compaction-memory-model.md`。

## enforce の責務（hard 強制層）

`[hard候補]`（gate-point を持ち、わずかな歪みも許せない命令）を、PreToolUse(Bash) hook が **deny-block** で強制する層。設計 SSOT は `architecture/ready-compaction-redesign.md §9.6`、フォーマット/マッチ/marker 導出の SSOT は `scripts/lib/enforce-policy.sh`。

- **opt-in は policy ファイルの存在**（`$PWD/.claude-session/enforce-policy.json`）。不在/空のプロジェクトでは hook は no-op（allow）＝全プロジェクトへの波及は無害。
- **認可（gate 定義）と unlock（許可）を分離**: `/session:enforce` が `[hard候補]`→gate を **LLM 提案 → 人間確定**で policy へ書く（authoring 専用）。実行時の unlock は人間が生シェルで `scripts/enforce-unlock <gate> "<command>"`（または block 時に提示される `touch`）を叩いて操作インスタンス marker を作る。lib は marker を作らない（読み取り専用）が、marker は空ファイルなので Claude も技術的には作成可能。本層が保証するのは「**沈黙の・偶発的な自己認可の防止**」（必ず block→人間に surface＋可監査な明示操作）であって、決然と回避する LLM を暗号学的に止めるものではない（信頼境界は人間が生シェルで叩く規律）。
- **判定フロー**: policy 不在/`enforce:false`→allow ／ gate 不一致→allow ／ 有効 marker 在り→allow ／ marker 不在→block(exit 2)＋unlock 案内 ／ policy 破損・jq 不在→**fail-closed scoped**（内蔵 danger list のみ block）。
- **marker は操作インスタンス単位**（例 `pr-merge-pr-3-sha-<head8>`）。対象や head SHA が変われば marker 名も変わり自動で再 gate（「一度で永久解除」を防ぐ）。
- **緊急 bypass は人間操作のみ**: `SESSION_ENFORCE_OFF=1` の export か policy 削除/空化。Claude は実行せず提示のみ（git ガードの代替ルート流儀）。
- グローバル `git-destructive-guard.sh` と共存（両者 PreToolUse:Bash、条件が別）。

| 変数 | デフォルト |
|---|---|
| `ENFORCE_POLICY_FILE` | `$WORKING_MEMORY_DIR/enforce-policy.json` |
| `ENFORCE_MARKER_DIR` | `$WORKING_MEMORY_DIR/enforce-markers` |
| `ENFORCE_SHA_TIMEOUT` | `5`（sha_keyed gate の SHA 導出 1 呼び出しの上限秒）|

## tmux Window 命名規則

### フォーマット

```
<prefix>-<repo>-<branch>[-i<issue>]-<h8>
```

| フィールド | 内容 |
|-----------|------|
| `prefix` | `wt`（spawn）/ `fk`（fork） |
| `repo` | リポジトリ名（slug化、最大16文字） |
| `branch` | ブランチ名（slug化、最大24文字）|
| `-i<issue>` | ブランチ末尾の Issue 番号（厳格抽出時のみ）|
| `h8` | sha256の先頭8文字（`worktree_path\|cwd\|prefix` のハッシュ）|
| 全体最大長 | 50文字（超過時は `branch` を truncate、hash は末尾固定）|

### Slug 仕様

- 英数字・ハイフンのみ許容（`LC_ALL=C tr -c '[:alnum:]-' '-'`）
- 連続ハイフンは1文字に圧縮、先頭・末尾のハイフンを除去
- 空文字の場合は `x` にフォールバック

### 共通ヘルパー

`scripts/session-name.sh` を source して使う:

```bash
source "$(dirname "$0")/session-name.sh"
WINDOW_NAME=$(generate_window_name wt "$CWD" "$CWD")
```

### 同一 Worktree の再利用 / TOCTOU 対策

`cld-spawn` は `find_existing_window` で既存 window を確認し再利用する（`--force-new` で強制新規）。並列 spawn の重複作成は `flock`（`SESSION_LOCK_FILE`）で防止する。

## テスト

```bash
bats tests/
```

tmux に依存するテストは tmux セッション内で実行すること。
