---
name: fork
description: |
  現在のセッションをforkして新しいtmuxウィンドウで起動。
  会話履歴を引き継いだ別セッションを並行実行できる。

  Use when user wants to: fork session, create parallel session,
  branch conversation, open forked session in new window,
  says 「fork」「フォーク」「並行セッション」「別窓で続き」
  says 「監視して」「完了したら教えて」「投げっぱなし」
---

# Fork Skill

現在のClaude Codeセッションをforkし、新しいtmuxウィンドウで起動する。

## 仕組み

- `claude --continue --fork-session` で最新セッションの会話履歴を引き継ぎつつ新しいセッションIDを発行
- 元のセッション（このセッション）は変更されず継続
- 新しいtmuxウィンドウで独立したセッションとして起動

## 意図推定（NLU）

| 意図 | 検出パターン例 | 動作 |
|------|--------------|------|
| 即実行 | 引数なし | `cld-fork` を実行 + 完了監視（デフォルト） |
| prompt | テキスト | fork 先の初期プロンプト + 完了監視（デフォルト） |
| 詳細監視 | 「監視して」「経過も教えて」「見ていて」 | 完了監視に加え途中経過も逐次報告 |
| 監視なし | 「投げっぱなし」「監視不要」 | 完了監視を省略 |

## 実行手順

1. tmux内か確認（tmux外はエラー終了）

2. 意図を推定する
   - テキストがあれば `PROMPT` に
   - 「投げっぱなし」「監視不要」 → `WATCH=off`
   - 「監視して」「経過も」等 → `WATCH=detailed`
   - それ以外 → `WATCH=completion`（デフォルト）

3. `cld-fork` を実行

   ```bash
   SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
   bash "$SCRIPT_DIR/cld-fork" "$PROMPT"   # PROMPT が空なら引数なしで実行
   ```

   cld-fork の stdout からウィンドウ名を取得（`forked → tmux window 'WINDOW_NAME'` の形式）。

4. 完了監視（`WATCH=off` 以外）— 後述の「完了監視」を実行する。

## 完了監視（spawn/fork 共通）

`WATCH=off` 以外では、spawn 元のこのセッションが fork 先の完了を監視し報告する。
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

- `WATCH=detailed` では `sleep 10` を短く（例 5）して途中経過（processing 状態）も報告に含める。
- `run_in_background` の完了通知を受けたら、capture を下記フォーマットで要約報告する。

### 完了報告フォーマット

- **Claude Code セッション**（状態 input-waiting / error / exited）: 状態 ＋ 作業内容の要約 ＋ 直近の操作・ツール呼び出し
- **一般シェルペイン**（状態 idle）: 実行コマンドと出力の要約 ＋ 完了/実行中/エラーの判定
- **タイムアウト**（最終状態が input-waiting でない）: 最終状態と「どこまで進んだか」を報告

## 注意

- tmux外では使用不可（エラー終了）
- forkされたセッションではセッションスコープの権限は引き継がれない
- 完了監視のタイムアウトはデフォルト300秒（5分）。長時間・常駐の監視はこのプラグインの範囲外
