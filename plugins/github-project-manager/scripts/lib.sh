#!/bin/bash
# 共通ユーティリティ。各 hook スクリプトから source して使う。
# 使い方: source "$(dirname "$0")/lib.sh"
# taxonomy.sh も一緒に読み込まれるため、taxonomy_* 関数も利用可能。

# taxonomy.sh を自動 source
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/taxonomy.sh"

# --- 前提条件 ---

has_jq() { command -v jq &>/dev/null; }
has_gh() { command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; }

# --- stdin (Hook input) 読み取り ---

read_command()              { jq -r '.tool_input.command // ""'; }
read_tool_name()            { jq -r '.tool_name // ""'; }
read_tool_response_stdout() { jq -r '.tool_response.stdout // ""'; }
read_tool_response_raw()    { jq -r '.tool_response // ""'; }
read_tool_file_path()       { jq -r '.tool_input.file_path // .tool_input.filePath // ""'; }

# --- コマンド解析 ---

# 先頭行が pattern にマッチするか。コミットメッセージ内の文字列誤検知を避ける。
# usage: is_first_line_cmd "$CMD" '^\s*gh\s+issue\s+close\b'
is_first_line_cmd() {
  local cmd="$1" pattern="$2"
  echo "$cmd" | head -1 | grep -qE "$pattern"
}

# テキストから #N パターンで Issue 番号を抽出（重複排除）
# usage: extract_issue_nums "$TEXT"
extract_issue_nums() {
  echo "$1" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -u
}

# closes/fixes/resolves #N から Issue 番号を抽出
# usage: extract_closing_refs "$TEXT"
extract_closing_refs() {
  echo "$1" | grep -oiE '(closes?|fix(es)?|resolves?)\s+#[0-9]+' | grep -oE '[0-9]+' | sort -u
}

# --label / その他オプションの値をコマンドから抽出
# usage: extract_option_value "$CMD" "label"
extract_option_value() {
  local cmd="$1" opt="$2" val
  val=$(echo "$cmd" | grep -oE "\-\-${opt}[= ]\"[^\"]+\"" | head -1 | sed -E "s/^--${opt}[= ]\"//; s/\"$//")
  [ -z "$val" ] && val=$(echo "$cmd" | grep -oE "\-\-${opt}[= ]'[^']+'" | head -1 | sed -E "s/^--${opt}[= ]'//; s/'$//")
  [ -z "$val" ] && val=$(echo "$cmd" | grep -oE "\-\-${opt}[= ][^ ]+" | head -1 | sed -E "s/^--${opt}[= ]//")
  echo "$val"
}

# --- Git ---

get_current_branch() { git rev-parse --abbrev-ref HEAD 2>/dev/null; }

# 現在ブランチから Issue 番号を抽出
get_branch_issue() {
  get_current_branch | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | head -1
}

# --- 工数（worklog） ---

# 工数データの保存先（ユーザーリポジトリの .claude/worklog）
worklog_dir() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
  echo "$root/.claude/worklog"
}

# --- GitHub リポジトリ ---

# 成功時 REPO / OWNER / REPO_NAME をエクスポート
get_repo_info() {
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)
  [ -z "$REPO" ] && return 1
  OWNER=$(echo "$REPO" | cut -d'/' -f1)
  REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)
  return 0
}

# --- Issue ---

get_issue_body()  { gh issue view "$1" --json body --jq '.body' 2>/dev/null; }
get_issue_state() { gh issue view "$1" --json state --jq '.state' 2>/dev/null; }
get_issue_title() { gh issue view "$1" --json title --jq '.title' 2>/dev/null; }

# 本文から未完了のチェックリスト行を抽出
unchecked_items_in_body() {
  echo "$1" | grep -E '^\s*- \[ \]' || true
}

# Issue の未完了チェックリスト行を取得
get_unchecked_items() {
  local body; body=$(get_issue_body "$1")
  [ -z "$body" ] && return 0
  unchecked_items_in_body "$body"
}

# --- PR ---

get_pr_body()   { gh pr view "$1" --json body --jq '.body' 2>/dev/null; }
get_pr_number_current() { gh pr view --json number --jq '.number' 2>/dev/null; }

# --- GitHub Projects v2 ---

# Issue に紐づく全プロジェクトアイテムを列挙
# 出力: ITEM_ID|PROJECT_ID|PROJECT_TITLE|CURRENT_STATUS（1行1アイテム）
list_issue_project_items() {
  local issue_num="$1"
  get_repo_info || return 1
  gh api graphql -f query='
    query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        issue(number: $number) {
          projectItems(first: 5) {
            nodes {
              id
              project { id title }
              fieldValueByName(name: "Status") {
                ... on ProjectV2ItemFieldSingleSelectValue { name }
              }
            }
          }
        }
      }
    }
  ' -f owner="$OWNER" -f repo="$REPO_NAME" -F number="$issue_num" 2>/dev/null \
    | jq -r '.data.repository.issue.projectItems.nodes[]? | "\(.id)|\(.project.id)|\(.project.title)|\(.fieldValueByName.name // "")"'
}

# 指定アイテムの Status を名前付きオプションに更新
# usage: set_project_status "$PROJECT_ID" "$ITEM_ID" "In Progress"
set_project_status() {
  local project_id="$1" item_id="$2" status_name="$3"
  local field_info field_id option_id

  field_info=$(gh api graphql -f query='
    query($projectId: ID!) {
      node(id: $projectId) {
        ... on ProjectV2 {
          field(name: "Status") {
            ... on ProjectV2SingleSelectField {
              id
              options { id name }
            }
          }
        }
      }
    }
  ' -f projectId="$project_id" 2>/dev/null)

  field_id=$(echo "$field_info" | jq -r '.data.node.field.id // ""')
  option_id=$(echo "$field_info" | jq -r --arg n "$status_name" '.data.node.field.options[]? | select(.name == $n) | .id')

  if [ -z "$field_id" ] || [ -z "$option_id" ]; then
    return 1
  fi

  gh api graphql -f query='
    mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $projectId
        itemId: $itemId
        fieldId: $fieldId
        value: { singleSelectOptionId: $optionId }
      }) {
        projectV2Item { id }
      }
    }
  ' -f projectId="$project_id" -f itemId="$item_id" -f fieldId="$field_id" -f optionId="$option_id" >/dev/null 2>&1
}

# 指定プロジェクトの Number フィールド ID を取得（無ければ作成）
# usage: ensure_project_number_field "$PROJECT_ID" "工数(h)"
ensure_project_number_field() {
  local project_id="$1" field_name="$2" fid
  fid=$(gh api graphql -f query='
    query($p: ID!) {
      node(id: $p) {
        ... on ProjectV2 {
          fields(first: 50) {
            nodes { ... on ProjectV2FieldCommon { id name dataType } }
          }
        }
      }
    }' -f p="$project_id" 2>/dev/null \
    | jq -r --arg n "$field_name" '.data.node.fields.nodes[]? | select(.name == $n and .dataType == "NUMBER") | .id' | head -1)
  if [ -z "$fid" ]; then
    fid=$(gh api graphql -f query='
      mutation($p: ID!, $n: String!) {
        createProjectV2Field(input: { projectId: $p, dataType: NUMBER, name: $n }) {
          projectV2Field { ... on ProjectV2Field { id } }
        }
      }' -f p="$project_id" -f n="$field_name" 2>/dev/null \
      | jq -r '.data.createProjectV2Field.projectV2Field.id // ""')
  fi
  echo "$fid"
}

# Number フィールドの値を更新
# usage: set_project_number "$PROJECT_ID" "$ITEM_ID" "$FIELD_ID" 3.4
set_project_number() {
  local project_id="$1" item_id="$2" field_id="$3" num="$4"
  [ -z "$field_id" ] && return 1
  gh api graphql -f query='
    mutation($p: ID!, $i: ID!, $f: ID!, $v: Float!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $p, itemId: $i, fieldId: $f, value: { number: $v }
      }) { projectV2Item { id } }
    }' -f p="$project_id" -f i="$item_id" -f f="$field_id" -F v="$num" >/dev/null 2>&1
}

# Issue の全プロジェクトアイテムのステータスを遷移させる
# usage: transition_issue_status 77 "In Progress" [FROM_STATUS]
#   FROM_STATUS が指定されている場合は現在ステータスが一致するもののみ遷移
transition_issue_status() {
  local issue_num="$1" target="$2" from="$3"
  local updated=0

  while IFS='|' read -r item_id project_id project_title current; do
    [ -z "$item_id" ] && continue
    [ -n "$from" ] && [ "$current" != "$from" ] && continue
    [ "$current" = "$target" ] && continue
    if set_project_status "$project_id" "$item_id" "$target"; then
      updated=1
    fi
  done < <(list_issue_project_items "$issue_num")

  [ $updated -eq 1 ]
}
