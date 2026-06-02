---
name: enforce
description: |
  ready-compaction で検出した [hard候補] 命令を、PreToolUse(Bash) hook が強制する gate として
  policy ファイル（enforce-policy.json）へ昇格させる **認可（authoring）専用** スキル。
  LLM が gate 定義を提案し、人間が確定（ratify）してはじめて書き込む（人間 ratified が信頼境界）。
  unlock（marker 作成）は担わない——それは人間が生シェルで enforce-unlock を叩く（hard 性の核心）。

  Use when user wants to: author/define an enforce gate, harden a directive into a hook gate,
  promote a [hard候補] to policy, says 「enforce」「gate を作る/定義」「hard 強制を有効化」
  says 「policy を作る」「この操作をブロックして」「レビュー必須にして」
---

# enforce Skill（hard 強制 policy の認可フロー）

`[hard候補]`（gate-point を持ち歪みを許せない命令）を、`pretooluse-enforce.sh` が deny-block で
強制する **gate** へ昇格させる。設計の SSOT は `architecture/ready-compaction-redesign.md §9.6`、
フォーマット/マッチ/marker 導出の SSOT は `scripts/lib/enforce-policy.sh`。

> **このスキルがやること＝認可（policy 生成）だけ**。実行時の unlock（marker 作成）は **やらない**。
> unlock は人間がレビュー後に生シェルで `enforce-unlock <gate> "<command>"` を叩く（C-4b/C-10）。
> 信頼境界は「**人間が生シェルで叩く規律**」＋摩擦＋可監査性であって、技術的不可能性ではない
> （marker は空ファイルで Claude も作成可能。本層が防ぐのは沈黙の・偶発的な自己認可）。

## 信頼境界（MUST）

- **C-3: LLM 提案 → 人間確定**。gate の下案は LLM が作るが、**人間が確認・編集して承認した内容だけ**を
  policy に書く。人間の ratify が信頼境界。取りこぼし（危険操作を黙って通す）が最悪の failure なので、
  曖昧なら gate を**広めに**提案し、人間に絞らせる。
- スキルは**勝手に gate を緩めない/消さない**。既存 gate の削除・縮小は人間の明示指示があるときのみ。

## 実行手順

### Step 0: パス解決と現状提示

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/session-env.sh"
echo "policy: $ENFORCE_POLICY_FILE"
[ -f "$ENFORCE_POLICY_FILE" ] && jq -r '.gates[].id' "$ENFORCE_POLICY_FILE" 2>/dev/null  # 既存 gate
```

スキーマの正典は `architecture/enforce-policy.example.json`（フィールド定義は §9.6 補足・B-1）。
gate の `match` / `key.subject_re` は **POSIX ERE**（bash `=~`）で書く。`(?:...)` 等 PCRE 構文は不可。
`subject_re` は **capture group 1** に対象（PR番号・ブランチ名等）が来るように書く。

### Step 1: `[hard候補]` 候補の収集

昇格対象を集める。出所は次のいずれか:
- Working Memory（`$WORKING_MEMORY_FILE` / consumed）の「この effort を貫く命令・制約」節の
  `[hard候補]` タグ付き項目（ready-compaction が付けたマーク）
- いま会話でユーザーが「この操作はブロックして」と挙げた命令

各候補について、命令文に書かれた **gate-point**（どの Bash コマンドが対象か）を特定する。
gate 対象は **Bash コマンド限定**（C-9）。Edit/Write/MCP は対象外（拡散的で単一 gate-point を持たない）。

### Step 2: gate 定義の下案（LLM 提案）

候補ごとに gate を組み立てる。各フィールドの決め方:

- `id`: `[a-z0-9-]+`（例 `pr-merge` / `git-push` / `deploy`）。
- `match.all`: 正規化後コマンドに**必ず含まれるトークン**（AND の軽量プレフィルタ）。
- `match.any_re`: コマンド境界アンカー付き ERE（例 `(^| )gh +pr +merge( |$)`）。誤爆を避ける。
- `key.strategy`: 対象を抽出できるなら `token`、できない（コマンド全体で識別）なら `command-hash`。
- `key.subject_re`: token 時、対象を group 1 で抽出する ERE を表記揺れの分だけ配列で。
- `key.subject_fallback`: 抽出失敗時。**安全側は `deny`**（特定できなければ block 維持）。
- `key.sha_keyed`:
  - **不可逆かつ対象内容が変わりうる**（PR の head が進む等）操作は `true`（head SHA で再 gate＝C-4a）。
    その場合 `sha_cmd`（`{subject}` を含む argv 配列）・`sha_validate_re`・`sha_len` も付ける。
  - それ以外は `false`（gh 等を呼ばず軽量。`marker_ttl_sec` で「古い認可」を時間失効させる）。
- `marker_ttl_sec`: 認可の有効期限（秒）。不可逆度が高いほど短く。
- `unlock_hint`: 人間が「何を確認してから承認すべきか」。`{subject}` は実行時に対象へ展開される。

`architecture/enforce-policy.example.json` の pr-merge / git-push / deploy をテンプレに流用してよい。

### Step 3: 人間の確定（ratify）— MUST

提案 gate（JSON）を**そのまま見せて**、人間に確認・編集させる。`AskUserQuestion` で
「この gate でよいか / 編集するか / やめるか」を問う。**承認が取れるまで policy を書かない**。
複数候補があれば 1 つずつ確定する。

### Step 4: policy への書き込み（承認分のみ）

`$ENFORCE_POLICY_FILE` が無ければスケルトンを作り、承認された gate を `.gates` に追加する。

```bash
# 初回スケルトン（存在しないときだけ）
[ -f "$ENFORCE_POLICY_FILE" ] || jq -n '{
  version: 1, schema: "cc-session/enforce-policy", enforce: true,
  ratified_by: "human-shell", default_marker_ttl_sec: null, gates: []
}' > "$ENFORCE_POLICY_FILE"

# 承認された gate（GATE_JSON）を追加（atomic: tmp → mv）
tmp=$(mktemp) && jq --argjson g "$GATE_JSON" '.gates += [$g]' "$ENFORCE_POLICY_FILE" > "$tmp" && mv "$tmp" "$ENFORCE_POLICY_FILE"
```

`ratified_at` は ISO8601 で記録してよい（監査痕跡・判定には未使用）。
**`.gitignore` は触らない**（`.claude-session/` の扱いはユーザー判断。policy をコミットするか否かも）。

### Step 5: 検証と案内

書き込み後、必ず health を確認し、`active` でなければ修正する:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/enforce-policy.sh"
ep_policy_health   # → active であること
```

人間に次を伝える:
- 以降、当該コマンドは marker が無い限りブロックされる（opt-in は policy の存在＝C-5）。
- 承認するときは**人間が生シェルで** `${CLAUDE_PLUGIN_ROOT}/scripts/enforce-unlock <gate> "<command>"`
  （または block 時に提示される `touch` コマンド）を `!` で実行する。**Claude は実行しない**。
- 緊急停止は人間が `SESSION_ENFORCE_OFF=1` を export、または policy を削除/空化（C-7）。

## 禁止事項（MUST NOT）

- **unlock を代行しない**（marker を作らない・`enforce-unlock` を呼ばない）。それは人間の操作（C-4b）。
- **人間の確定なしに policy を書かない**（C-3 の信頼境界を侵さない）。
- 既存 gate を**勝手に緩めない/削除しない**（縮小は人間の明示指示時のみ）。
- グローバル（ユーザースコープ）の設定・CLAUDE.md を触らない。`.gitignore` を勝手に編集しない。
- gate 対象を Bash 以外（Edit/Write/MCP）へ拡張しない（現スコープは Bash 限定＝C-9）。
