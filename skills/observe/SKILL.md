---
name: observe
description: tmuxウィンドウ/ペインの出力を観察し、AI分析で状態を要約報告する
user_invocable: true
---

# /observe - tmuxペイン観察スキル

指定した tmux ウィンドウまたはペインの出力をキャプチャし、要約して報告する。
観察のみ（単一責務）。コマンド実行・inject は含まない。

## Dynamic Context Injection

!`tmux list-windows -F '#{window_index}:#{window_name}:#{pane_current_command}'`

## ウィンドウ選択（NLU + AskUserQuestion）

DCI で取得した窓一覧から、自窓（現在のセッションが動作しているウィンドウ）を除外して判定する:

| 他窓の数 | 動作 |
|---------|------|
| 0 | 「他のウィンドウがありません」と報告して終了 |
| 1 | そのウィンドウを自動選択 |
| 2+ | AskUserQuestion でウィンドウを選択させる |

ユーザーが入力でウィンドウ名を明示した場合（例: `/observe fork-123456`）は、選択をスキップしてそのウィンドウを使用する。

## 取得行数の推定（NLU）

| ユーザー入力 | 推定行数 | 動作 |
|-------------|---------|------|
| 指定なし（デフォルト） | 30 | `cld-observe <window>` |
| 「多めに見て」「詳しく」 | 100 | `cld-observe <window> --lines 100` |
| 「会話全て」「全部見せて」「全スクロールバック」 | 全取得 | `cld-observe <window> --all` + トークン消費警告 |

全スクロールバック取得時は、実行前に以下を警告する:
「全スクロールバックを取得します。トークン消費が大きくなる可能性があります。」

## 実行手順（MUST）

### Step 1: cld-observe 実行

```bash
SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
bash "$SCRIPT_DIR/cld-observe" <window> [--lines N | --all]
```

エラーの場合はエラーメッセージをそのまま報告して終了。

### Step 2: AI 要約

cld-observe の出力を分析し、以下の形式で報告する:

**Claude Code セッションの場合:**
- 状態（idle/input-waiting/processing/error/exited）
- 現在の作業内容の要約（出力から推定）
- 直近の操作やツール呼び出しの概要

**一般シェルペインの場合:**
- 実行中のコマンドと出力の要約
- 完了/実行中/エラーの判定

## 禁止事項（MUST NOT）

- 対象ペインにコマンドを送信してはならない
- inject や send-keys を使用してはならない
- キャプチャ内容を外部に送信してはならない

## 定期監視モード（--loop）

`--loop` オプション指定時は `cld-observe-loop` を使用して複数ウィンドウを定期ポーリングする。

### 起動方法

```bash
SCRIPT_DIR="${CLAUDE_PLUGIN_ROOT}/scripts"
bash "$SCRIPT_DIR/cld-observe-loop" [TARGET|--pattern GLOB] [--interval SECONDS] [--max-cycles N] [--notify-dir DIR]
```

Bash tool の `run_in_background: true` で起動し、完了通知を待機する。

### オプション

| オプション | デフォルト | 説明 |
|-----------|----------|------|
| `TARGET` | — | 単一ウィンドウ名（`--pattern` と排他） |
| `--pattern GLOB` | — | `session-state.sh list --json` の `window_name` を bash glob でフィルタ |
| `--interval N` | 300 | ポーリング間隔（秒） |
| `--max-cycles N` | 0 | 最大サイクル数（0 = 無制限） |
| `--notify-dir D` | `/tmp/claude-notifications` | 通知ファイルディレクトリ |

### 完了時の処理

`cld-observe-loop` の stdout 出力を受け取り、以下を要約して報告する:
- 検出された異常（exited/error/attention(unseen) 状態）とそのキャプチャ内容
- 終了理由（max-cycles到達 / 全窓消失 / SIGINT受信）
- 各サイクルの状態変化サマリー
