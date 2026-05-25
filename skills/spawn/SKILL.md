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
| prompt | cd 意図なしのテキスト | `cld-spawn "$PROMPT"` を即実行 |

**優先順位**: worktree > cd > window名指定 > prompt。`--worktree` と cd 意図が同時検出された場合は `--worktree` を優先（cd は無視）。

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
   テキストを prompt として `cld-spawn "$PROMPT"` を実行。

   ### パターン D: --worktree → worktree 作成 + セッション起動

   1. **プロジェクトルート解決**:
      ```bash
      GIT_COMMON_DIR=$(git rev-parse --git-common-dir)
      GIT_COMMON_DIR=$(cd "$GIT_COMMON_DIR" && pwd)
      PROJECT_DIR=$(dirname "$GIT_COMMON_DIR")
      ```

   2. **ブランチ名・worktree パス生成**:
      ```bash
      BRANCH_NAME="spawn/$(date +%H%M%S)"
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

   4. **ウィンドウ名決定**:
      - プロンプトに Issue 番号（`#123`）が含まれる → `wt-123`
      - それ以外 → `wt-HHMMSS`（ブランチ名のタイムスタンプ部分）

   5. **cld-spawn 実行**:
      `--worktree` を除いた残りのテキストを PROMPT として使用。
      ```bash
      SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
      bash "$SCRIPT_DIR/cld-spawn" --cd "$WORKTREE_DIR" --window-name "$WINDOW_NAME" "$PROMPT"
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

   bash "$SCRIPT_DIR/cld-spawn" "${OPTS[@]}" "$FULL_PROMPT"
   ```

   cld-spawn は以下を順に実行:
   1. tmux new-window で cld を引数なし起動
   2. `session-state.sh wait` で input-waiting 状態を待機（デフォルト60秒）
   3. プロンプトを一時ファイルに書き出し `session-comm.sh inject-file` で送達

   stdout からウィンドウ名を取得（`spawned → tmux window 'WINDOW_NAME'` の形式）。

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
