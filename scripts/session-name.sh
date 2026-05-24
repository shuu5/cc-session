#!/usr/bin/env bash
# session-name.sh - 意味論的 tmux window 命名ヘルパー
#
# 提供関数:
#   generate_window_name <prefix> <worktree_path> <cwd>
#     → <prefix>-<repo>-<branch>[-i<issue>]-<h8> (max 50文字)
#   slugify <str> [<maxlen>]
#     → ASCII英数ハイフンのみのslug
#   find_existing_window <name>
#     → session:index (未発見なら空文字)
#
# Note: set -e なし（source 時の親スクリプトに影響しないため）
# Note: 本スクリプトは source で読み込む（直接実行不可）

# slugify <str> [<maxlen>]
# 英数ハイフンのみのslugを生成。非ASCII・禁止文字は'-'に変換。空文字時は'x'。
slugify() {
  local s="$1" maxlen="${2:-50}"
  s=$(printf '%s' "$s" | LC_ALL=C tr -c '[:alnum:]-' '-' | sed -e 's/--\+/-/g' -e 's/^-//' -e 's/-$//')
  [ -z "$s" ] && s="x"
  s="${s:0:$maxlen}"
  s="${s%-}"
  printf '%s' "$s"
}

# generate_window_name <prefix> <worktree_path> <cwd>
# tmux window名を決定的に生成する。
# - prefix: "wt"(spawn) / "fk"(fork)
# - worktree_path: gitリポジトリ/worktreeの絶対パス
# - cwd: 実際の作業ディレクトリの絶対パス
# Returns: 非ゼロ終了 → 非gitディレクトリなどで生成不可
generate_window_name() {
  local prefix="$1"
  local worktree_path="$2"
  local cwd="$3"

  # リポジトリ同定: bare+worktree 両対応
  local common_dir repo_root repo_name
  common_dir=$(git -C "$worktree_path" rev-parse --git-common-dir 2>/dev/null) || return 1
  # common_dir が相対パスの場合は worktree_path 起点で解決
  case "$common_dir" in
    /*) ;;
    *) common_dir="${worktree_path}/${common_dir}" ;;
  esac
  repo_root=$(dirname "$(realpath -m "$common_dir")")
  repo_name=$(basename "$repo_root")
  repo_name=$(slugify "$repo_name" 16)

  # ブランチ名 (detached HEAD fallback: short SHA)
  local branch
  branch=$(git -C "$worktree_path" symbolic-ref --short -q HEAD 2>/dev/null \
    || git -C "$worktree_path" rev-parse --short HEAD 2>/dev/null) || return 1
  branch=$(slugify "$branch" 24)

  # Issue 番号 (厳格パターン: slug後の末尾 -<NNN> または ^<NNN>)
  local issue=""
  if [[ "$branch" =~ (^|-|_)([0-9]+)$ ]]; then
    issue="${BASH_REMATCH[2]}"
  fi

  # canonical_context hash (sha256の先頭8文字)
  local ctx hash
  ctx="${worktree_path}|${cwd}|${prefix}"
  hash=$(printf '%s' "$ctx" | sha256sum | cut -c1-8)

  # 名前組み立て
  local name="${prefix}-${repo_name}-${branch}"
  [ -n "$issue" ] && name="${name}-i${issue}"
  name="${name}-${hash}"

  # 最大長 50: 超過時は branch を truncate（hash は末尾固定）
  if [ ${#name} -gt 50 ]; then
    local overflow=$(( ${#name} - 50 ))
    local new_branch_len=$(( ${#branch} - overflow ))
    [ "$new_branch_len" -lt 4 ] && new_branch_len=4
    branch="${branch:0:$new_branch_len}"
    branch="${branch%-}"
    name="${prefix}-${repo_name}-${branch}"
    [ -n "$issue" ] && name="${name}-i${issue}"
    name="${name}-${hash}"
  fi

  printf '%s' "$name"
}

# find_existing_window <name>
# 指定名のtmux windowを検索し、"session:index"形式で返す。未発見なら空文字。
find_existing_window() {
  local name="$1"
  tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name}' 2>/dev/null \
    | awk -v n="$name" '$2==n {print $1; exit}'
}
