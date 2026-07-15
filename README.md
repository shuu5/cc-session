# cc-session

汎用 Claude Code セッション管理プラグイン。tmux ウィンドウ上の Claude Code セッションを **spawn / fork** し、状態を検出する。

## 機能

| スキル | 説明 |
|--------|------|
| `/session:spawn` | 新しい tmux ウィンドウで Claude Code を起動（コンテキスト非継承、`--worktree` 対応）。完了監視はデフォルト ON |
| `/session:fork` | 現在のセッションを fork（会話履歴を継承して並行実行）。完了監視はデフォルト ON |
| `/session:ready-compaction` | context cycle（`/clear`・respawn）前に「命令・状態」を carrier 別に振り分け外部化（policy router）。effort 一時層を退避＋carry-forward。auto-compact 発火（incident）時はフックが自動復元（opt-in） |
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

## context cycle を生き延びる（ready-compaction）

`/session:ready-compaction` は context cycle（`/clear`・respawn）で**命令**を失わないための policy router。意図的な cycle の正路は `/clear`（+ 各 project の resume 正路）または respawn で、手動 `/compact` は cycle 正路から廃止済み（裁定 SSOT = scriptorium top-spec §1.1・scribe protocol.md）。`/clear`・respawn は文脈を丸ごと捨て、auto-compact（発火は incident）の要約器も「事実」でなく「ambient な命令（手法・計画の弧）」を構造的に落とす——どちらも事実の店では解けない。スキルは項目を **2 軸（適用範囲 × 強制）** で分類し、carrier 別に振り分ける:

- **恒久命令**（このリポで常に真）→ **プロジェクト CLAUDE.md(git)** へ昇格提案（提案のみ。グローバル CLAUDE.md は対象外）
- **横断/インシデントの事実・教訓** → doobidoo MCP に保存
- **effort 命令・作業状態**（この作業の間だけ）→ `.claude-session/working-memory.<sid>.md`（session-scoped）に 2 節スキーマで退避し、次サイクルへ **carry-forward**（コア）
- **discrete・永続タスク**（セッション/effort を越えて残す作業）→ **beads（`bd create`）で issue 化**を誘導。Working Memory「計画弧」は bd issue ID 参照に留め内容を重複させない（bd 未導入リポは Working Memory にフォールバック）
- **hard 候補**（gate を持ち歪みを許せない命令）→ working-file に `[hard候補]` でマーク → `/session:enforce` で gate 昇格（実強制は PreToolUse hook）

付随する PreCompact / PostCompact / SessionStart(compact) フック（`hooks/hooks.json`）は **auto-compact 発火（incident）時の復元安全網**——圧縮の前後で退避・復元と命令の carry-forward を自動化する非常用パラシュートとして残置している（意図的 cycle ではこの経路を使わない）。これらは **opt-in**: `.claude-session/.compaction-enabled` マーカーがあるプロジェクトでのみ発火する（スキル初回実行時に自動作成、他プロジェクトでは no-op）。

SessionStart(clear) フック（`session-start-clear.sh`）は **`/clear`（意図的 cycle の主経路）後の復帰導線**。復元の本線は各 project が提供する resume 正路（scribe 系 = `/scribe:resume` 等）で、resume 未導入 project はこのフックが出すポインタから手動 Read でフォールバックする。`/clear` 後の新コンテキストに退避ファイルへの **read-only ポインタ**（「退避ファイルあり: `<path>`。続きなら Read してください」）だけを出す——`cat` 自動注入も `consumed` への mv も行わない（PostCompact の自動復元とは責務が違う）。厳密な session id 一致が無ければ、非 consumed の退避ファイルを mtime 降順で**全件列挙**してフォールバックする。`/clear` は session_id を変える（実測 verified）ため `/clear` 後は厳密一致が必ず空振りし、**この全件列挙フォールバックが復帰の主経路**になる（最新 1 件だけ出すと自分の古い退避ファイルが並走セッションのファイルに隠れるため全件出す）。フォールバック時の候補は **cwd を共有する別セッション由来の可能性もある**ため、原因を断定せず「別セッション由来、または sid が変わった自セッションのファイルの可能性」と正直に提示し、読むか否かはユーザー判断に委ねる（read-only ゆえ上書き破壊は起こさない）。設計根拠は `architecture/compaction-memory-model.md`「/clear 経路の安全網」節。

退避ファイルは **session-scoped**（`working-memory.<sid>.md`）。cwd=anchor の複数セッションが同一ファイルを奪い合う衝突（2026-06-09 実害）を構造的に根絶するため、ファイル名に session id を含める。session id は hook stdin の `.session_id`（一次）→ `CLAUDE_CODE_SESSION_ID` env（二次フォールバック）で解決し、解決不能なら legacy 非 scoped 名（`working-memory.md`・後方互換）へ落ちる。opt-in マーカーと log はプロジェクト共有なので session-scoped にしない。設計判断（自動移行はせず coexistence・consumed 連鎖も同一セッション内に閉じる）は `architecture/compaction-memory-model.md`。

2 節スキーマ・carry-forward の実体は `scripts/lib/working-memory.sh`。設計詳細は `architecture/compaction-memory-model.md`（2 軸 × carrier モデルの SSOT）、フェーズ別の決定根拠は `architecture/ready-compaction-redesign.md` を参照。

## 危険操作を強制ブロックする（enforce / hard 強制層）

レビュー等の gate を通っていない危険操作（PR merge / push / deploy 等）を、PreToolUse(Bash) hook が **deny-block** する層。`[hard候補]` 命令を `/session:enforce` で gate 化して有効化する。

- **opt-in は policy ファイルの存在**（`.claude-session/enforce-policy.json`）。不在のプロジェクトでは hook は no-op（allow）＝波及は無害。スキーマの正典は `architecture/enforce-policy.example.json`。
- **認可と unlock の分離**: gate 定義は `/session:enforce` が **LLM 提案 → 人間確定**で書く（authoring 専用）。実行時の許可は人間が生シェルで `scripts/enforce-unlock <gate> "<command>"`（または block 時に提示される `touch` コマンド）を叩いて marker を作る。lib は marker を作らない（読み取り専用）が、marker は空ファイルなので技術的には作成可能。本層が保証するのは「**沈黙の・偶発的な自己認可の防止**」（必ず block→人間に surface＋可監査な明示操作）であり、信頼境界は「人間が生シェルで叩く規律」（暗号学的な不可能性ではない）。
- **marker は操作インスタンス単位**（例 `pr-merge-pr-3-sha-<head8>-<disamb16>`）。対象や head SHA が変われば再 gate（「一度で永久解除」を防ぐ）。`marker_ttl_sec` で時間失効も設定可。`key.risk_flags`（allowlist）を持つ gate は危険フラグも区別する（例 pr-merge は `--admin` を `-flag-admin` として keying＝`--squash` の unlock が `--admin`〔レビュー要件 bypass〕を巻き込み認可しない・認可スコープ漏洩の防止）。末尾の `<disamb16>` は構造化フィールドの sha256（16桁）で、別 gate 間で readable 部が一致しても marker は必ず異なる（marker 文法の曖昧さに由来する別 gate 衝突を構造的に排除）。
- **fail-closed (scoped)**: policy が壊れている / jq 不在のときは内蔵 danger list（push/merge/deploy 系）のみ block し、他は通す。
- **緊急 bypass は人間操作のみ**: `SESSION_ENFORCE_OFF=1` を export、または policy を削除/空化。
- **env 経由の silent disable は Position B 限界**（`ccs-5p4.2` won't-fix）: `SESSION_ENFORCE_OFF` も `ENFORCE_POLICY_FILE` の redirect も settings.json env で設定でき enforce を silent 無効化しうるが、settings.json 編集は deliberate な config 改変＝determined evasion で本層の対象外（防ぐのは沈黙の・偶発的な自己認可）。設計根拠は `architecture/ready-compaction-redesign.md §9.4 C-7`。
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
