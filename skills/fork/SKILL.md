---
name: fork
description: |
  現在のセッションをforkして新しいtmuxウィンドウで起動。
  会話履歴を引き継いだ別セッションを並行実行できる。

  Use when user wants to: fork session, create parallel session,
  branch conversation, open forked session in new window,
  says 「fork」「フォーク」「並行セッション」「別窓で続き」
  says 「監視して」「完了したら教えて」
---

# Fork Skill

現在のClaude Codeセッションをforkし、新しいtmuxウィンドウで起動する。

## 仕組み

- `claude --continue --fork-session` で最新セッションの会話履歴を引き継ぎつつ新しいセッションIDを発行
- 元のセッション（このセッション）は変更されず継続
- 新しいtmuxウィンドウで独立したセッションとして起動

## 意図推定（NLU）

ユーザー入力から以下を推定する:

| 意図 | 検出パターン例 | 動作 |
|------|--------------|------|
| 即実行 | 引数なし | `cld-fork` を即座に実行 |
| watch | 「監視して」「完了したら教えて」「見ていて」「終わったら報告」 | fork 後にバックグラウンド監視 |
| prompt | 上記以外のテキスト | fork 先セッションの初期プロンプト |
| 曖昧 | 判別不能 | AskUserQuestion で確認 |

watch と prompt は併用可能（例: `/fork 監視しながらテスト実行して`）。

## 実行手順

1. tmux内か確認（tmux外はエラー終了）

2. 意図を推定する

   - 引数なし → `WITH_WATCH=false`, `PROMPT=""`
   - watch 意図あり → `WITH_WATCH=true`, 残りテキストを `PROMPT` に
   - watch 意図なし → `WITH_WATCH=false`, テキストを `PROMPT` に
   - 判別不能 → AskUserQuestion で「監視しますか？」を確認

3. `cld-fork` を実行

   ```bash
   SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"

   # 引数なし
   bash "$SCRIPT_DIR/cld-fork"

   # 引数あり
   bash "$SCRIPT_DIR/cld-fork" "$PROMPT"
   ```

   cld-fork の stdout からウィンドウ名を取得（`forked → tmux window 'WINDOW_NAME'` の形式）。

4. watch 処理（WITH_WATCH=true の場合）

   fork 後に Bash tool (run_in_background) で監視を開始:

   ```bash
   SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
   WINDOW_NAME="<Step 3で取得したウィンドウ名>"
   bash "$SCRIPT_DIR/session-state.sh" wait "$WINDOW_NAME" input-waiting --timeout 300 && \
     bash "$SCRIPT_DIR/session-comm.sh" capture "$WINDOW_NAME" --lines 30
   ```

   - 完了通知を受け取ったら、capture 結果を要約してユーザーに報告
   - タイムアウト時は「タイムアウトしました（5分）」と報告

## 注意

- tmux外では使用不可（エラー終了）
- forkされたセッションではセッションスコープの権限は引き継がれない
- watch のタイムアウトはデフォルト300秒（5分）
