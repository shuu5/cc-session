---
name: spawn
description: |
  新規セッションで指定プロンプトを実行。コンテキスト引き継ぎなし。
  tmux new-window で cld を起動し、wait-ready + inject-file でプロンプトを送達。

  Use when user wants to: spawn new session, run background task,
  start independent session, run command in new window,
  says 「spawn」「新しいセッション」「バックグラウンドで」
  says 「別ディレクトリで」「コンテキスト付きで」「監視して」
  says 「--worktree」「ワークツリーで」
---

# Spawn Skill

新しい tmux ウィンドウで cld を起動し、指定プロンプトを初期入力として実行する。
`--worktree` オプションで独立した git worktree を `.worktrees/`（隠しディレクトリ、`.gitignore` に自動追記）に作成し、その中でセッションを起動できる。
会話コンテキストは引き継がない（`/fork` との違い）。

## Dynamic Context Injection

!`ls -d ~/projects/local-projects/*/main 2>/dev/null`

## 意図推定（NLU）

ユーザー入力から以下を推定する:

| 意図 | 検出パターン例 | 動作 |
|------|--------------|------|
| 即実行 | 引数なし | カレントディレクトリで `cld-spawn` を即座に実行 |
| worktree | `--worktree`, `ワークツリーで` | worktree 作成 → cld-spawn --cd（パターン D） |
| cd | 「tradingで」「別ディレクトリで」「paperプロジェクトで」 | AskUserQuestion でプロジェクト選択 |
| window名指定 | 「11というウィンドウで」「window名はXで」 | `--window-name` オプション使用 |
| **bd id** | プロンプト中の `un-cbi` 形式 / `#123` 数値形式の issue id | `BD_ID` に格納し命名規約へ反映（後述） |
| prompt | cd 意図なしのテキスト | `cld-spawn -- "$PROMPT"` を即実行 |

**優先順位**: worktree > cd > window名指定 > prompt。`--worktree` と cd 意図が同時検出された場合は `--worktree` を優先（cd は無視）。

### bd id の捕捉（fleet-monitor 照合の producer 規約）

worker セッションを bd issue に紐づけて起動するとき、プロンプト中の bd issue id を `BD_ID` として特定する。これにより worktree/branch=`spawn/<BD_ID>-<HHMMSS>`・window=`wt-<BD_ID>` が生成され、consumer 側（`fleet-monitor.sh`）が **window 名 `wt-<id>` / worktree パス `spawn/<id>-<HHMMSS>` の完全一致**で worker を ◆ 点灯できる。

- **特定方法（最優先は LLM の明示特定）**: 「worker cell: un-cbi」「#291 を直して」等のプロンプトから id を読み取り、`BD_ID` に直接セットするのが一次経路（信頼境界）。`un-cbi` 形式・`#123` 数値形式・**dotted 階層 id（例 `un-3sh.3`）**に対応する。
- **機械的フォールバック `extract_bd_id "$PROMPT"`（`session-name.sh`）は確実性が低い last resort**:
  - 優先順は (1) `#<digits>` (2) **明示アンカー**（`cell: <id>` / `bd id: <id>` / `issue: <id>` の直後トークン） (3) bare-slug `<prefix>-<slug>`。
  - bare-slug（優先3）は `read-only` / `multi-line` 等の hyphenated 英単語にも構造的に一致しうる（常用語は denylist で除外するが網羅ではない）。**誤検出を避けたいときは LLM が明示特定した `BD_ID` を渡すか、プロンプトに `cell: <id>` アンカーを置く**こと。
  - dotted 階層 id は `'.'` 込みで丸ごと捕捉される（`un-3sh` 等への誤切詰めはしない）。
- **正規化**: `#123` は `123` に正規化される（`#` を剥がす）。`#123` → window `wt-123`（既存挙動と整合）。dotted id（`un-3sh.3`）は内部 `'.'` を保持し `wt-un-3sh.3` / `spawn/un-3sh.3-<HHMMSS>` になる（consumer が完全一致で復元）。`'..'` / `'/'` を含む id は path traversal として拒否される。
- **不明なとき**: `BD_ID=""` のままにする → 現行フォールバック命名（`spawn/<HHMMSS>-<pid>` / 意味論的 window 名）になり後方互換。
- 命名生成は `session-name.sh` の `spawn_branch_name` / `spawn_window_name` が SSOT（cld-spawn と共有）。

## 実行手順

1. tmux内か確認（tmux外はエラー終了）

2. 意図を推定する

   ### パターン A: 引数なし → 即起動
   `cld-spawn` をカレントディレクトリで実行。

   ### パターン B: cd 意図あり → プロジェクト選択

   DCI で取得したプロジェクト一覧から AskUserQuestion で選択:

   ```
   どのプロジェクトで起動しますか？
   （DCI 一覧からプロジェクト名を選択肢として提示）
   ```

   プロジェクト選択後、追加オプションを multiSelect で提示:

   ```
   追加オプション:
   □ コンテキスト注入（現在の会話の要約を引き継ぐ）
   ```

   - コンテキスト注入 → 会話要約を生成して PROMPT に結合（50行以内）
   - 完了監視はデフォルト ON（後述の Step 4）。不要なら「監視なし」、途中経過も追うなら「監視して」と指示

   ### パターン C: cd 意図なし・テキストあり → 即実行
   テキストを prompt として `cld-spawn -- "$PROMPT"` を実行（PROMPT は '--' の後に置き、
   '-' 始まり PROMPT の誤拒否を構造的に封鎖する）。

   ### パターン D: --worktree → worktree 作成 + セッション起動

   1. **プロジェクトルート解決**:
      ```bash
      GIT_COMMON_DIR=$(git rev-parse --git-common-dir)
      GIT_COMMON_DIR=$(cd "$GIT_COMMON_DIR" && pwd)
      PROJECT_DIR=$(dirname "$GIT_COMMON_DIR")
      ```

   2. **ブランチ名・worktree パス生成**（bd id 連動）:
      ```bash
      SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
      source "$SCRIPT_DIR/session-name.sh"

      # bd id を特定（NLU で明示特定した値があれば優先、無ければ prompt から best-effort 抽出）
      BD_ID="${BD_ID:-$(extract_bd_id "$PROMPT" 2>/dev/null || true)}"

      # bd id 有り: spawn/<id>-<HHMMSS>（fleet-monitor が ◆ 照合する規約名。pid は含めない
      #   ＝consumer の末尾 -<数字> 1 回剥がし照合と整合させるため）。1 issue = 1 cell 運用が前提で、
      #   同一 id を同一秒に二重 spawn すると branch 名が完全一致するが、git worktree add -b が
      #   fail-loud で検知する（規約外の二重 spawn を黙って通さない）。
      # bd id 無し: spawn/<HHMMSS>-<pid>（フォールバック）。pid 込みのため同一秒の並列 spawn でも distinct。
      BRANCH_NAME="$(spawn_branch_name "$BD_ID")"
      WORKTREE_DIR="$PROJECT_DIR/.worktrees/$BRANCH_NAME"
      ```

   3. **`.gitignore` 冪等追記 → worktree 作成**:
      ```bash
      # 対象リポジトリの .gitignore に .worktrees/ を冪等追記（git 汚染防止）
      GI="$PROJECT_DIR/.gitignore"
      if ! { [ -f "$GI" ] && grep -qxF '.worktrees/' "$GI"; }; then
          printf '%s\n' '.worktrees/' >> "$GI"
      fi
      mkdir -p "$(dirname "$WORKTREE_DIR")"
      git worktree add -b "$BRANCH_NAME" "$WORKTREE_DIR" main
      ```
      失敗時はエラーメッセージを表示して終了。

   4. **ウィンドウ名決定**（bd id 連動）:
      ```bash
      # bd id 有り: wt-<id>（fleet-monitor が ◆ 照合する規約名。un-cbi → wt-un-cbi / #123 → wt-123）
      # bd id 無し: 空 → 時刻ベースフォールバック wt-HHMMSS-$$
      WINDOW_NAME="$(spawn_window_name "$BD_ID")"
      [[ -z "$WINDOW_NAME" ]] && WINDOW_NAME="wt-$(date +%H%M%S)-$$"
      ```
      - **並列 spawn 時**: `session-comm.sh` / `session-state.sh` は **window 名で送達・状態取得**するため、各 worker に **distinct な window 名**を与える（bd id ベース `wt-<id>` 推奨。無名フォールバックも `-$$` で衝突回避）。
      - **fleet-monitor 照合**: `wt-<完全bd id>` と worktree `spawn/<完全bd id>-<HHMMSS>` は consumer 側の完全一致照合（誤検出ゼロ設計）の producer。両者が規約どおりなら実 worker が ◆ 点灯する。

   5. **cld-spawn 実行**:
      `--worktree` を除いた残りのテキストを PROMPT として使用。
      ```bash
      # --bd-id は cld-spawn 側の window 名フォールバック（--window-name 未指定時の wt-<id> 採用）の
      # ためにのみ併渡しする（空なら省略可）。ここでは --window-name を明示しているので window 名は
      # それが優先され、--bd-id は実質 no-op（cld-spawn は bd id を別途記録しない）。
      # PROMPT は必ず '--' の後に置く。'-' 始まりの PROMPT を未知オプション扱いで誤拒否させない
      # ための構造的封鎖（cld-spawn は '--' 以降を PROMPT として扱う）。
      bash "$SCRIPT_DIR/cld-spawn" --cd "$WORKTREE_DIR" --window-name "$WINDOW_NAME" \
        ${BD_ID:+--bd-id "$BD_ID"} -- "$PROMPT"
      ```

   6. **ロールバック**: cld-spawn が失敗した場合、作成した worktree を削除:
      ```bash
      git worktree remove "$WORKTREE_DIR" 2>/dev/null
      git branch -D "$BRANCH_NAME" 2>/dev/null
      ```

   完了メッセージに worktree パスを含める:
   `worktree 作成: $WORKTREE_DIR（ブランチ: $BRANCH_NAME）`

3. cld-spawn を実行する

   ```bash
   SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"

   # オプション構築
   OPTS=()
   [[ -n "$TARGET_DIR" ]] && OPTS+=(--cd "$TARGET_DIR")
   [[ -n "$WINDOW_NAME" ]] && OPTS+=(--window-name "$WINDOW_NAME")
   # bd id があれば渡す（--window-name 未指定時に cld-spawn が wt-<id> を採用）
   [[ -n "$BD_ID" ]] && OPTS+=(--bd-id "$BD_ID")

   # PROMPT は必ず '--' の後に置く（'-' 始まり PROMPT の誤拒否を構造的に封鎖）。
   bash "$SCRIPT_DIR/cld-spawn" "${OPTS[@]}" -- "$FULL_PROMPT"
   ```

   cld-spawn は以下を順に実行:
   1. tmux new-window で cld を引数なし起動
   2. `session-state.sh wait` で input-waiting 状態を待機（デフォルト60秒）
   3. プロンプトを一時ファイルに書き出し `session-comm.sh inject-file` で送達

   stdout からウィンドウ名を取得（`spawned → tmux window 'WINDOW_NAME' (session: SESSION)` の形式。
   ウィンドウ名は最初の引用符内。`--session` 未指定時の spawn 先は現在の session）。

4. 完了監視（`WATCH=off` 以外、デフォルト ON）

   spawn 元のこのセッションが spawn 先の完了を監視し報告する。「投げっぱなし」「監視不要」と指示された場合のみ省略する。
   Bash tool の `run_in_background: true` で以下を起動する。状態を逐次 stdout に出すため経過を追える:

   ```bash
   SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
   WINDOW_NAME="<Step 3 で取得したウィンドウ名>"
   TIMEOUT=300; ELAPSED=0
   until bash "$SCRIPT_DIR/session-state.sh" state "$WINDOW_NAME" 2>/dev/null | grep -qx "input-waiting"; do
     STATE=$(bash "$SCRIPT_DIR/session-state.sh" state "$WINDOW_NAME" 2>/dev/null || echo exited)
     echo "[${ELAPSED}s] $STATE"
     { [ "$STATE" = "exited" ] || [ "$ELAPSED" -ge "$TIMEOUT" ]; } && break
     sleep 10; ELAPSED=$((ELAPSED + 10))
   done
   echo "[final] $(bash "$SCRIPT_DIR/session-state.sh" state "$WINDOW_NAME" 2>/dev/null || echo exited)"
   bash "$SCRIPT_DIR/session-comm.sh" capture "$WINDOW_NAME" --lines 30
   ```

   - 「監視して」「経過も教えて」（詳細監視）では `sleep 10` を短く（例 5）して途中経過（processing）も報告に含める。
   - `run_in_background` の完了通知を受けたら、capture を下記フォーマットで要約報告する:
     - **Claude Code セッション**（状態 input-waiting / error / exited）: 状態 ＋ 作業内容の要約 ＋ 直近の操作・ツール呼び出し
     - **一般シェルペイン**（状態 idle）: 実行コマンドと出力の要約 ＋ 完了/実行中/エラーの判定
     - **タイムアウト**（最終状態が input-waiting でない）: 最終状態と「どこまで進んだか」を報告

## コンテキスト注入の形式

```markdown
# Context from previous session

## 決定事項
- （設計判断、技術選定など）

## 技術制約
- （プロジェクト固有の制約、禁止事項など）

## 関連ファイル
- （議論で参照されたファイルパス）

## 補足
- （その他の重要なコンテキスト）
```

## 注意

- tmux 外では使用不可（エラー終了）
- 会話コンテキストは引き継がれない（コンテキスト注入時はテキスト要約のみ）
- cd なしの場合、作業ディレクトリは呼び出し元の `pwd` が引き継がれる
- セッションスコープの権限は引き継がれない
- 完了監視はデフォルト ON（不要なら「投げっぱなし」「監視不要」）。タイムアウトはデフォルト300秒。長時間・常駐監視はこのプラグインの範囲外
- `--worktree` の worktree は対象リポジトリの `.worktrees/` に作成し、`.gitignore` に自動追記する（git 汚染防止）
- `--worktree` で作成した worktree は手動管理（自動削除しない）。不要時は `worktree-delete` で削除
- `--worktree` は git リポジトリ内でのみ使用可能（bare repo 構造を前提）
