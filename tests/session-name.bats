#!/usr/bin/env bats
# session-name.bats - Unit tests for plugins/session/scripts/session-name.sh
# 依存: bats-core のみ（bats-support / bats-assert 不要）

# ---------------------------------------------------------------------------
# 共通セットアップ
# ---------------------------------------------------------------------------

SESSION_NAME_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)/session-name.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  export SANDBOX
  # stub bin ディレクトリ（コマンドスタブ用）
  STUB_BIN="${SANDBOX}/.stub-bin"
  mkdir -p "$STUB_BIN"
  _ORIGINAL_PATH="$PATH"
  export PATH="${STUB_BIN}:${PATH}"
}

teardown() {
  export PATH="$_ORIGINAL_PATH"
  [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

# git リポジトリの bare+worktree 構成を SANDBOX 内に作成
# 正確な bare+worktree 構成を作る（git clone では common_dir が .git になりリポジトリ名が誤る）
_setup_repo() {
  local repo_name="$1"
  local branch="${2:-main}"

  # 元リポジトリ（コミット付き）
  git init "${SANDBOX}/${repo_name}/_src" >/dev/null 2>&1
  git -C "${SANDBOX}/${repo_name}/_src" config user.email "test@test" >/dev/null 2>&1
  git -C "${SANDBOX}/${repo_name}/_src" config user.name "test" >/dev/null 2>&1
  touch "${SANDBOX}/${repo_name}/_src/init"
  git -C "${SANDBOX}/${repo_name}/_src" add . >/dev/null 2>&1
  git -C "${SANDBOX}/${repo_name}/_src" commit -m "init" >/dev/null 2>&1

  # bare クローン
  git clone --bare "${SANDBOX}/${repo_name}/_src" "${SANDBOX}/${repo_name}/.bare" >/dev/null 2>&1

  # worktree 追加（これにより .git がファイルになり common_dir が .bare を指す）
  git -C "${SANDBOX}/${repo_name}/.bare" worktree add \
    "${SANDBOX}/${repo_name}/main" HEAD >/dev/null 2>&1

  if [[ "$branch" != "main" ]]; then
    git -C "${SANDBOX}/${repo_name}/main" checkout -b "$branch" >/dev/null 2>&1 \
      || git -C "${SANDBOX}/${repo_name}/main" switch -c "$branch" >/dev/null 2>&1
  fi

  printf '%s' "${SANDBOX}/${repo_name}/main"
}

# ---------------------------------------------------------------------------
# slugify
# ---------------------------------------------------------------------------

@test "slugify: 通常ASCII文字列はそのまま返す" {
  source "$SESSION_NAME_SH"
  result=$(slugify "hello-world")
  [ "$result" = "hello-world" ]
}

@test "slugify: スラッシュはハイフンに変換される" {
  source "$SESSION_NAME_SH"
  result=$(slugify "feat/my-branch")
  [ "$result" = "feat-my-branch" ]
}

@test "slugify: 連続ハイフンは1つに圧縮される" {
  source "$SESSION_NAME_SH"
  result=$(slugify "feat//double")
  [ "$result" = "feat-double" ]
}

@test "slugify: 日本語は英数ハイフンのみの文字列になる" {
  source "$SESSION_NAME_SH"
  result=$(slugify "日本語ブランチ")
  [ "${#result}" -gt 0 ]
  [[ "$result" =~ ^[a-zA-Z0-9-]+$ ]]
}

@test "slugify: 空文字列は'x'を返す" {
  source "$SESSION_NAME_SH"
  result=$(slugify "")
  [ "$result" = "x" ]
}

@test "slugify: maxlen を超えた場合は切り詰める" {
  source "$SESSION_NAME_SH"
  result=$(slugify "abcdefghijklmnopqrstuvwxyz" 10)
  [ "${#result}" -le 10 ]
  [ "$result" = "abcdefghij" ]
}

# ---------------------------------------------------------------------------
# generate_window_name — 正常系
# ---------------------------------------------------------------------------

@test "generate_window_name: 通常 clone + branch=main で wt- prefix の名前を返す" {
  source "$SESSION_NAME_SH"
  local wt
  wt=$(_setup_repo "myrepo" "main")

  run generate_window_name wt "$wt" "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == wt-* ]]
  [[ "$output" == *myrepo* ]]
  [ "${#output}" -le 50 ]
  [[ "$output" =~ ^[a-zA-Z0-9-]+$ ]]
}

@test "generate_window_name: bare+worktree 構成でリポジトリ名がブランチ名と混同されない" {
  source "$SESSION_NAME_SH"
  local wt
  wt=$(_setup_repo "myrepo" "feat-test")

  run generate_window_name wt "$wt" "$wt"
  [ "$status" -eq 0 ]
  # repo 名が myrepo（branch 名 feat-test ではない）
  [[ "$output" == *-myrepo-* ]]
  [[ "$output" == *feat-test* ]]
}

@test "generate_window_name: branch 末尾の Issue 番号を抽出する (fix/issue-291 → i291)" {
  source "$SESSION_NAME_SH"
  local wt
  wt=$(_setup_repo "myrepo" "fix/issue-291")

  run generate_window_name wt "$wt" "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *-i291-* ]]
}

@test "generate_window_name: feature/v2 で '2' を誤抽出しない" {
  source "$SESSION_NAME_SH"
  local wt
  wt=$(_setup_repo "myrepo" "feature/v2")

  run generate_window_name wt "$wt" "$wt"
  [ "$status" -eq 0 ]
  # -i2- が含まれてはいけない
  [[ "$output" != *-i2-* ]]
}

@test "generate_window_name: 長大ブランチ名は truncate され hash が末尾に残る" {
  source "$SESSION_NAME_SH"
  local long_branch="feature-very-long-branch-name-that-exceeds-the-limit"
  local wt
  wt=$(_setup_repo "myrepo" "$long_branch")

  run generate_window_name wt "$wt" "$wt"
  [ "$status" -eq 0 ]
  # 長さが 50 以下
  [ "${#output}" -le 50 ]
  # hash（8文字16進）が末尾近くにある（末尾 9 文字 = '-' + 8chars）
  local suffix="${output: -9}"
  [[ "$suffix" =~ ^-[0-9a-f]{8}$ ]]
}

@test "generate_window_name: 非 git ディレクトリはエラー終了する" {
  source "$SESSION_NAME_SH"
  local non_git_dir
  non_git_dir=$(mktemp -d)

  run generate_window_name wt "$non_git_dir" "$non_git_dir"
  [ "$status" -ne 0 ]

  rm -rf "$non_git_dir"
}

@test "generate_window_name: detached HEAD は short SHA でクラッシュしない" {
  source "$SESSION_NAME_SH"
  local wt
  wt=$(_setup_repo "myrepo" "main")

  # detached HEAD にする
  local sha
  sha=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" checkout --detach "$sha" -q 2>/dev/null || true

  run generate_window_name wt "$wt" "$wt"
  [ "$status" -eq 0 ]
  [ "${#output}" -le 50 ]
  [ -n "$output" ]
}

@test "generate_window_name: prefix が異なると hash が異なる" {
  source "$SESSION_NAME_SH"
  local wt
  wt=$(_setup_repo "myrepo" "main")

  name_wt=$(generate_window_name wt "$wt" "$wt")
  name_fk=$(generate_window_name fk "$wt" "$wt")
  name_ap=$(generate_window_name ap "$wt" "$wt")

  [ "$name_wt" != "$name_fk" ]
  [ "$name_wt" != "$name_ap" ]
  [ "$name_fk" != "$name_ap" ]
}

@test "generate_window_name: 同一入力で同じ名前を返す（決定論的）" {
  source "$SESSION_NAME_SH"
  local wt
  wt=$(_setup_repo "myrepo" "main")

  name1=$(generate_window_name wt "$wt" "$wt")
  name2=$(generate_window_name wt "$wt" "$wt")

  [ "$name1" = "$name2" ]
}

@test "generate_window_name: cwd が異なると hash が異なる" {
  source "$SESSION_NAME_SH"
  local wt
  wt=$(_setup_repo "myrepo" "main")

  name1=$(generate_window_name wt "$wt" "$wt")
  name2=$(generate_window_name wt "$wt" "/tmp")

  [ "$name1" != "$name2" ]
}

# ---------------------------------------------------------------------------
# find_existing_window
# ---------------------------------------------------------------------------

@test "find_existing_window: 存在しない window は空文字を返す" {
  source "$SESSION_NAME_SH"

  # tmux スタブ: 空リスト
  cat > "${STUB_BIN}/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${STUB_BIN}/tmux"

  result=$(find_existing_window "nonexistent-window")
  [ -z "$result" ]
}

@test "find_existing_window: 一致する window は session:index を返す" {
  source "$SESSION_NAME_SH"

  # tmux スタブ: テスト用 window リスト
  cat > "${STUB_BIN}/tmux" <<'EOF'
#!/usr/bin/env bash
echo "main:0 base-window"
echo "main:1 wt-myrepo-main-abcd1234"
echo "main:2 other-window"
EOF
  chmod +x "${STUB_BIN}/tmux"

  result=$(find_existing_window "wt-myrepo-main-abcd1234")
  [ "$result" = "main:1" ]
}

@test "find_existing_window: session 指定時はその session 内のみ探索する（他 session の同名を掴まない）" {
  source "$SESSION_NAME_SH"

  # tmux スタブ: '-t =proj' なら proj 内のみ、'-a' なら全 session を返す
  cat > "${STUB_BIN}/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"-t =proj"* ]]; then
  echo "proj:1 wt-shared-name"
elif [[ "$*" == *"-a"* ]]; then
  echo "other:3 wt-shared-name"
  echo "proj:1 wt-shared-name"
fi
EOF
  chmod +x "${STUB_BIN}/tmux"

  # session 省略（従来）: 全 session 横断の先頭一致 = other:3
  result=$(find_existing_window "wt-shared-name")
  [ "$result" = "other:3" ]

  # session 指定: proj 内のみ = proj:1
  result=$(find_existing_window "wt-shared-name" "proj")
  [ "$result" = "proj:1" ]
}

@test "find_existing_window: 指定 session が不在なら空文字（エラーにしない）" {
  source "$SESSION_NAME_SH"

  # tmux スタブ: 不在 session への -t はエラー（実 tmux 同様 stderr + 非0）
  cat > "${STUB_BIN}/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"-t =nosuch"* ]]; then
  echo "can't find session: nosuch" >&2
  exit 1
fi
EOF
  chmod +x "${STUB_BIN}/tmux"

  result=$(find_existing_window "wt-any" "nosuch")
  [ -z "$result" ]
}

@test "find_existing_window: session 不在でも set -euo pipefail 下で exit 0（silent 死しない・ccs-y9h e2e 実証）" {
  # tmux スタブ: 不在 session への -t は exit 1（実 tmux 同様）
  cat > "${STUB_BIN}/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"-t =nosuch"* ]]; then
  echo "can't find session: nosuch" >&2
  exit 1
fi
EOF
  chmod +x "${STUB_BIN}/tmux"

  # 呼び出し元（cld-spawn）と同じ set -euo pipefail 環境で実行して exit status を検証する
  run bash -c "set -euo pipefail; source '$SESSION_NAME_SH'; find_existing_window wt-any nosuch; echo RC-OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RC-OK"* ]]
}
