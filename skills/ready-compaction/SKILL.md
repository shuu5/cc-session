---
name: ready-compaction
description: |
  context cycle（/clear・respawn）の前に、失うと困る「命令・状態」を carrier 別に
  振り分けて外部化する退避 skill。policy router として項目を分類し、effort 一時層
  （Working Memory ファイル）だけを自前で運ぶ。恒久命令はプロジェクト CLAUDE.md(git) へ昇格提案、
  横断/インシデントの事実は doobidoo、hard 候補はマーク＋ /session:enforce 昇格提案。
  書込前に bd/git ground-truth 突合を必須とする（stale 主張を焼かない）。
  auto-compact が発火した場合（incident）は PreCompact/PostCompact/SessionStart フックが
  自動復元と carry-forward を担う（安全網として残置）。

  Use when user wants to: prepare for context cycle, externalize knowledge,
  says 「cycle 前に退避」「/clear する前に」「respawn 前に」「context cycle」
  says 「compaction の準備」「知識を保存して」「ready-compaction」
  says 「コンテキストが限界」「/compact する前に」「作業状態を退避」
---

# ready-compaction Skill

context cycle（`/clear`・respawn）の前に effort を退避する **policy router 兼 effort 一時層 carrier**。two-hat で働く:

- **主（cycle 前の退避 carrier）**: 意図的な context cycle の正路は `/clear`（+ 各 project の resume 正路）
  または respawn であり、手動 `/compact` は cycle 正路から廃止済み（裁定 SSOT = scriptorium top-spec §1.1・
  scribe protocol.md）。`/clear`・respawn は文脈を**丸ごと**捨てるため、外部化しない限り命令も状態も全て失う——
  cycle の前に本スキルで退避する。
- **従（auto-compact incident の復元安全網）**: auto-compact（built-in 会話圧縮の自動発火）は正常フローでなく
  **incident**。発火時は PreCompact/PostCompact/SessionStart フックが Working Memory を機械復元する
  非常用パラシュートとして残置している（本スキルの退避があれば incident でも sharp な足場が生き残る）。

`/compact` の要約器が構造的に落とすのは「事実」ではなく **ambient な命令（手法・計画の弧）**——そして
`/clear`・respawn はそもそも全てを捨てる。どちらの経路でも、これは事実の店（doobidoo / MEMORY.md）では
原理的に解けない。本スキルは会話から抽出した各項目を **「事実か命令か」「いつ効く命令か」** で分類し、
それぞれ正しい carrier へ委譲する。自前で抱えるのは **effort 一時層（Working Memory ファイル）だけ**——
恒久命令と hard は再発明せず委譲/マークする。

> **重要**: cycle（`/clear`・respawn）は built-in CLI / 外部操作のため skill/tool からの自動起動はしない。
> 本スキルは Step 0〜3 を自動実行し、Step 4 で **ユーザーへの cycle 案内のみ** 行う。

## carrier モデル（要約）

| 項目の種類 | carrier | 本スキルの役割 |
|---|---|---|
| 恒久命令（このリポで常に真）| **プロジェクト CLAUDE.md(git)** | 「追記/修正しては?」と**提案のみ**（commit は通常フロー）|
| 横断/インシデントの**事実**・教訓 | doobidoo MCP | Step 2 で保存（事実のみ）|
| **effort 命令・作業状態**（この作業の間だけ）| `$WORKING_MEMORY_FILE` | Step 3 で退避＋carry-forward（**コア**）|
| **discrete・永続タスク**（セッション/effort を越えて残す作業）| **beads (`bd`)** | 「`bd create` で issue 化しては?」と誘導。Working Memory「計画弧」は bd issue ID を参照し内容を重複させない（bd 未導入リポは Working Memory にフォールバック）|
| **hard 候補**（gate を持ち歪みを許せない命令）| working-file に `[hard候補]` マーク（＋ `/session:enforce` で gate 昇格）| マーク＋昇格の導線提示（実強制は PreToolUse hook）|

詳細は `architecture/compaction-memory-model.md`（2軸 × carrier モデルの SSOT）を参照。
スキーマ・carry-forward の実体は `scripts/lib/working-memory.sh`。

## 実行手順（MUST）

### Step 0: セットアップ（opt-in 有効化）

パスとライブラリを解決し、退避ディレクトリと opt-in マーカーを用意する。
マーカーがあるプロジェクトでのみ compaction フックが発火する（他プロジェクトでは no-op）。

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/session-env.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/working-memory.sh"
mkdir -p "$WORKING_MEMORY_DIR"
touch "$COMPACTION_ENABLED_MARKER"   # 初回のみ作成。以降このプロジェクトでフックが有効化される
```

### Step 1: policy router（振り分け）

現在の会話から「失うと困る項目」を抽出し、各項目を carrier へ振り分ける。
まず **事実か命令か** を見極め、命令は **適用範囲（いつ効くか）** で分ける:

| 判定 | 振り分け先 | アクション |
|---|---|---|
| **恒久命令**（このリポで何をしていても常に真の手法・規約）| プロジェクト CLAUDE.md | 「**プロジェクトの** CLAUDE.md に追記/修正しては?」と**提案**。承認時のみ通常のコミットフローで反映（スキルは勝手にコミットしない）。**ユーザースコープのグローバル CLAUDE.md は対象外**——横断的ルールに見えても、グローバルへは「手動で検討を」と口頭で促すだけ（自動提案・自動編集しない）|
| **横断/インシデントの事実・教訓** | doobidoo | Step 2 へ |
| **effort 命令・作業状態**（この作業の間だけ有効）| working-file | Step 3 で「命令・制約」節に強制モードタグ付きで記入 |
| **discrete・セッション/effort 横断のタスク**（着手中/保留/依存があり跨いで残す作業）| beads（`bd create`）| 着手前に `bd create` → `bd update <id> --claim`。Working Memory「計画弧」には **bd issue ID のみ参照**（内容重複禁止）。**bd 未導入リポでは従来どおり Working Memory に退避**（フォールバック）|
| **hard 候補**（gate-point を持ち、わずかな歪みも許したくない命令）| working-file | 「命令・制約」節に `[hard候補]` タグでマーク。さらに **`/session:enforce` で gate へ昇格** を提案（policy 書き込みは /session:enforce が人間 ratify を得て行う。本スキルはマーク＋導線提示まで）|

> **hard 候補は適用範囲（always/default/effort）に依らずマーク対象**（`any × hard`）。effort 項目に限定されない。実強制は `pretooluse-enforce.sh`（PreToolUse:Bash hook）＝コマンドを deny-block する。本スキルの責務はマークと **`/session:enforce` への導線提示**まで。ユーザーが「この操作をブロックしたい」と望むなら `/session:enforce` を勧める（gate 定義は LLM 提案 → 人間確定）。marker による unlock は人間が生シェルで `enforce-unlock` を叩く（Claude は実行しない＝hard 性の核心）。

### Step 2: Long-term Memory 保存（doobidoo）— 事実のみ

**横断/インシデントの事実・教訓のみ**を doobidoo に保存する（作業状態・進捗は入れない＝Step 3 へ回す）:

- `mcp__doobidoo__memory_store` を使用。type は doobidoo の ontology 内の事実・教訓系（例 `learning` / `decision`）を指定する（作業状態・進捗は入れない＝Step 3 の working-file へ）
  - ※ `feedback` は type ontology に無く `observation` へ黙示変換される（保存自体は失敗しないが意図とズレる）ため使わない
- **プロジェクト固有の恒久知識は doobidoo でなく git（CLAUDE.md/docs）へのコミット**へ誘導する
  （CLAUDE.md は compaction 後に自動再注入＋git でマシン間同期されるため、本来の置き場）
- doobidoo が利用不可なら **警告のみでスキップ**（エラー終了しない）

### Step 3: Working Memory 退避（ground-truth 突合 → 2節スキーマ＋ハイブリッド carry-forward）

`$WORKING_MEMORY_FILE` に 2節スキーマで現在の effort を退避する。**書込前に必ず 3-pre の突合を行う**。

**3-pre. bd/git ground-truth 突合（機械 fetch → LLM 突合・書込前 MUST）**

計画弧・タスク状態を**会話の信念だけで書いてはならない**。ここで書かれた内容は PostCompact が
**無検証で verbatim 復元**するため、stale な主張（完了済みタスクを未完了と言う・逆に未完了を
完了と言う等）が焼き付くと compaction 後の誤認識事故として再生される（是正段は復元側に無い）。
書込前に外部の現在値（ground truth）を機械的に取得し、これから書く内容と突合する:

```bash
# 機械 fetch（決定論）。bd はリポ root に .beads/ が存在する場合のみ実行し（cwd 相対で判定すると
# subdir 起動時に bd 導入リポを未導入と誤検知する）、stderr は捨てない・exit code を確認する
# （「fetch 失敗」と「未 close が本当に無い」を区別するため）。
# フィルタ無しの bd list を --limit 0 で使う（closed のみ除外＝非 closed 全件。--limit 0 は必須:
# 既定 limit=50 は非 closed が 50 件を超えるリポで超過分を無警告に切り捨て、exit 0 のため
# 下の失敗判定でも検知できない。bd ready や --status=open は blocked/deferred を含まない
# subset のため取りこぼす＝どちらも使わない）。
_root=$(git rev-parse --show-toplevel 2>/dev/null) || _root=$PWD
if [ -d "${_root}/.beads" ]; then bd list --limit 0; fi
# git: 実作業の現在値（ブランチ・未コミット・直近コミット）
git status -sb 2>/dev/null; git log --oneline -5 2>/dev/null
```

LLM 突合（判定）——上記出力と「計画弧・次のステップ」に書こうとしている主張を突き合わせる:

- **fetch の成否を先に判定する**: bd がエラー/非 0 exit を返した場合、空出力を「open 無し」と
  断定してはならない。突合未成立として git のみで突合し、計画弧に
  「bd 突合スキップ（失敗: <理由>）」を明記する（会話の完了主張を bd 空出力で正当化しない。
  Step 4 の報告も ✓ でなく ⚠ にする——虚偽の突合済み報告をしない）
- 会話では「完了」と認識しているのに bd が未 close（open/in_progress/blocked/deferred）→
  **bd 現在値を truth** とする。
  実完了のエビデンス（merge 済み PR・green テスト等）を実出力で確認できる場合のみ先に `bd close` し、
  確認できなければ WM の主張を bd に合わせて修正する
- 会話に現れていない in_progress issue が bd にある → 計画弧に拾う（黙って落とさない）
- git の branch/HEAD/未コミットが会話の認識と違う → 計画弧の「現在地」を実測値で書く

> 不一致の解消方向は常に「**外部 truth に語りを合わせる**」。語りに合わせて bd を書き換えるのは
> エビデンスがある場合のみ。bd 未導入リポは git 突合のみ行う。

**3a. 機械シード（決定論・絶対落とさない）**: lib のテンプレで新 working-file を生成する。
consumed があれば前サイクルの「命令・制約」節が**機械的に carry-forward** される:

```bash
emit_working_memory "$(date -u +%Y-%m-%dT%H:%M:%SZ)" manual "$WORKING_MEMORY_CONSUMED_FILE" > "$WORKING_MEMORY_FILE"
```

**3b. LLM マージ（更新）**: 生成された `$WORKING_MEMORY_FILE` を Edit して仕上げる:
- 「## 計画弧・次のステップ」に現在地と次の行動を記入（ephemeral、毎回上書き。**3-pre の突合済み内容のみ**）。
  **bd 導入リポでは各 durable 項目に bd issue ID の参照を必須とする**（ID が無い durable 項目は
  Step 1 に従い `bd create` してから書く。ID 参照があれば復元側が bd 直読で検証できる）
- 「## この effort を貫く命令・制約」を現在文脈とマージ・更新（古い項目は削除、新規追加、
  各項目の先頭に強制モードタグ `[auto]` / `[confirm]` / `[hard候補]` を付与）

スキーマ（節見出し・タグ書式）は `scripts/lib/working-memory.sh` が SSOT。手書きで見出しを変えない。

### Step 4: cycle 案内（ユーザー手動実行）

保存・退避の完了を報告し、context cycle（`/clear` または respawn）の実行を案内する:

```
✓ 恒久命令 → プロジェクト CLAUDE.md への昇格を提案（承認分のみコミット）
✓ 横断/インシデントの事実 → doobidoo 保存
✓ bd/git ground-truth 突合済み（計画弧は bd/git 現在値と整合・bd 導入リポは bd-ID 参照付き）
✓ effort 命令・作業状態 → Working Memory 退避（前サイクルから carry-forward 済み）
✓ opt-in 有効化済み（このプロジェクトで compaction フックが発火します）
>>> 退避完了。`/clear`（推奨）または respawn（plugin 変更後）で cycle してください。
    /clear 後の復元は各 project が提供する resume 正路で行います（scribe 系 project は
    /scribe:rebrief・orchestrator は /scriptorium:orch-resume・resume 未導入 project は
    SessionStart(clear) が出す Working Memory ポインタから手動 Read でフォールバック）
```

> 「✓ 突合済み」行は **3-pre の fetch が成功したときのみ**出す。bd fetch が失敗していた場合は
> `⚠ bd 突合未成立（<理由>）——計画弧の完了主張は未検証` に置き換える（成否に依らず ✓ を
> 印字すると、bd が壊れているときに虚偽の成功報告となる）。

> 復帰導線は上記のとおり**条件法で案内する**（呼び出し元 project を静的に知り得ない汎用 skill のため
> 単一 project のコマンドへ hardcode しない。cc-session 自身は resume skill を持たない——
> `/session:resume` のような存在しないコマンドを案内してはならない）。

> 手動 `/compact` は cycle 正路から廃止済み（裁定 SSOT = scriptorium top-spec §1.1・scribe protocol.md。
> 本スキルは廃止対象でない——退避は /clear 経路でも同じく使う）。auto-compact が発火した場合
> （incident）は PreCompact → PostCompact → SessionStart(compact) フックが自動的に Working Memory を
> 復元し、命令・制約を次サイクルへ carry-forward する（非常用パラシュート＝安全網として残置。
> 意図的 cycle ではこの経路を使わない）。

## 禁止事項（MUST NOT）

- `/compact` の自動実行を試みてはならない（built-in CLI のため skill/tool から起動不可）
- **bd/git ground-truth 突合（Step 3-pre）を経ずに Working Memory を書いてはならない**（会話の
  信念だけで書かれた stale 主張が PostCompact で無検証復元され、compaction 後の誤認識事故になる）
- doobidoo エラーで全体を停止してはならない（警告のみ）
- 外部化が未完了の状態で「完了」と報告してはならない
- **working-file に恒久知識を入れてはならない**（恒久命令→プロジェクト CLAUDE.md、恒久事実→doobidoo/git）
- **MEMORY.md を carrier に使ってはならない**（machine-local のため別マシンで stranded する）
- **ユーザースコープのグローバル CLAUDE.md を自動提案・自動編集してはならない**（昇格提案先はプロジェクト CLAUDE.md のみ）
- `.gitignore` を勝手に編集してはならない（`.claude-session/` の扱いはユーザー判断に委ねる）
- **durable な discrete タスクを Working Memory「計画弧」（ephemeral・carry-forward 対象外）に *だけ* 置いてはならない**（複数 compaction を跨いで喪失する）。bd 導入リポでは `bd create` で issue 化し、計画弧は **bd issue ID 参照に留める**（bd 未導入リポは従来どおり Working Memory に退避）
- **beads の `bd remember` / `bd recall` / `bd memories` を使ってはならない**（consolidation 機構が無く肥大化する。知識・知見は doobidoo、タスクは bd issue ＝役割分担）

## 注意

- 退避先は既定で作業ディレクトリ直下 `$WORKING_MEMORY_DIR`（`.claude-session/`、環境変数で上書き可）
- compaction フックは opt-in マーカーがあるプロジェクトでのみ動作する
- **`/clear` 経路（意図的 cycle の主経路）**: 意図的な context cycle は `/clear`（または respawn）が正路。`/clear` 後の復元の本線は各 project の resume 正路（Step 4 の条件法案内を参照）で、`SessionStart(clear)` フック（`session-start-clear.sh`）は新コンテキストに退避ファイルへの **read-only ポインタ**だけを出す（`cat` 自動注入も `consumed` mv もしない。resume 未導入 project はこのポインタから手動 Read）。厳密 session id 一致が無ければ、非 consumed の退避ファイルを mtime 降順で全件列挙してフォールバックする（`/clear` は session_id を変える〔実測 verified〕ため厳密一致は空振りし、この全件列挙がポインタ提示の主経路。最新 1 件のみだと自分の古いファイルが並走セッションのファイルに隠れるため。候補は別セッション由来の可能性もあり原因は断定しない）。`/clear` は `PreCompact`/`PostCompact` を発火させない（compaction 専用）ため、PostCompact 型の自動復元は走らない——自動復元フックは **auto-compact 発火（incident）時の安全網**であって `/clear` 主経路の機構ではない（設計根拠は `architecture/compaction-memory-model.md`「/clear 経路の安全網」節〔read-only ポインタ機構の記述・節名は歴史的〕・bd ccs-et2。framing の二分: `/clear`=計画 cycle の主経路・auto-compact=incident パラシュート＝真の安全網）
- PostCompact が復元すると Working Memory は `$WORKING_MEMORY_CONSUMED_FILE`（session-scoped: `working-memory.<sid>.consumed.md`）へ mv される（削除しない）。
  この consumed が次サイクルの **carry-forward の供給源**になる（命令・制約節を機械引き継ぎ）。退避ファイルは session id を含むため cwd=anchor の複数セッションでも互いに上書きしない（`un-gcu`）
- 2節スキーマ・タグ書式・carry-forward の実体は `scripts/lib/working-memory.sh`（SSOT）
