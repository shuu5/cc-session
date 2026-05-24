# cc-session

汎用 Claude Code セッション管理プラグイン。tmux ウィンドウでの Claude Code セッションの **spawn / observe / fork** と状態検出、および **ready-compaction**（compaction 知識外部化）を提供する。特定プロジェクトに依存しない（namespace は環境変数で切り替え可能）。

## 構成

- `skills/` — `spawn` / `observe` / `fork` / `ready-compaction` スキル（`/session:spawn` 等で起動）
- `scripts/` — セッション管理スクリプト群（`cld`, `cld-spawn`, `cld-fork`, `cld-observe`, `cld-observe-loop`, `cld-observe-any`, `session-state.sh`, `session-comm.sh`, `session-name.sh`, `window-manifest.sh` 等）
- `scripts/hooks/` — compaction フック（`pre-compact.sh` / `post-compact.sh` / `session-start-compact.sh`）
- `scripts/lib/` — 共有ライブラリ（`session-env.sh`, `tmux-resolve.sh`, `path-validate.sh`, `llm-indicators.sh`）
- `hooks/hooks.json` — フック登録（PreCompact / PostCompact / SessionStart:compact、自動検出）
- `architecture/` — 設計ドキュメント（`compaction-memory-model.md`, `window-manifest-v1.schema.json` 等）
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
