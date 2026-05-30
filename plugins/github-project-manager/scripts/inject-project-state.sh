#!/bin/bash
# SessionStart: プロジェクト状態を Claude のコンテキストに包括的に注入
# Claude が整合性を判断し、矛盾があればバックグラウンドで修復できるよう全状態を出力する
# stdout の内容が Claude のコンテキストに追加される

source "$(dirname "$0")/lib.sh"

has_jq || { echo "⚠ jq が見つかりません"; exit 0; }
has_gh || { echo "⚠ gh CLI が未認証または未インストールです"; exit 0; }

echo "## プロジェクト状態（自動注入）"
echo ""

if ! get_repo_info; then
  echo "⚠ リポジトリ情報を取得できませんでした"
  exit 0
fi

echo "リポジトリ: $REPO"
echo ""

# === プロジェクト（1回の GraphQL で全件取得: Open / Closed 両方） ===
echo "### プロジェクト"

PROJECT_QUERY='
  {
    projectsV2(first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        title number id closed
        repositories(first: 50) {
          nodes { nameWithOwner }
        }
        items(first: 100) {
          nodes {
            fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            }
            content {
              ... on Issue {
                number state
                repository { nameWithOwner }
              }
            }
          }
        }
      }
    }
  }'

PROJECTS_RAW=$(gh api graphql -f query="{
  organization(login: \"$OWNER\") $PROJECT_QUERY
}" 2>/dev/null)
PROJECTS_JSON=$(echo "$PROJECTS_RAW" | jq '.data.organization.projectsV2.nodes // empty' 2>/dev/null)

if [ -z "$PROJECTS_JSON" ] || [ "$PROJECTS_JSON" = "null" ]; then
  PROJECTS_RAW=$(gh api graphql -f query="{
    viewer $PROJECT_QUERY
  }" 2>/dev/null)
  PROJECTS_JSON=$(echo "$PROJECTS_RAW" | jq '.data.viewer.projectsV2.nodes // []' 2>/dev/null)
fi

if [ -n "$PROJECTS_JSON" ] && [ "$PROJECTS_JSON" != "null" ] && [ "$PROJECTS_JSON" != "[]" ]; then
  echo "$PROJECTS_JSON" | jq -r --arg repo "$REPO" '
    .[] |
    (if (.repositories.nodes // [] | map(select(.nameWithOwner == $repo)) | length) > 0 then "✓" else "✗" end) as $link |
    ([.items.nodes[] | select(.content.repository.nameWithOwner == $repo)]) as $items |
    ($items | length) as $total |
    ([$items[] | select(.fieldValueByName.name == "Done")] | length) as $done |
    ([$items[] | select(.fieldValueByName.name == "In Progress")] | length) as $in_progress |
    ([$items[] | select(.fieldValueByName.name == "Todo")] | length) as $todo |
    (if .closed then "[Closed]" else "[Open]" end) as $state |
    (if $total == 0 then
      "- \(.title) (#\(.number)) \($state) — アイテムなし | リポリンク:\($link)"
    elif $total == $done and $total > 0 then
      "- \(.title) (#\(.number)) \($state) — \($done)/\($total) Done 全完了 | リポリンク:\($link)"
    else
      "- \(.title) (#\(.number)) \($state) — \($done)/\($total) Done, \($in_progress) In Progress, \($todo) Todo | リポリンク:\($link)"
    end),
    ($items[] | select(.content.state == "OPEN" and .fieldValueByName.name == "Done") | "  - Issue #\(.content.number) [Open] Status:Done"),
    ($items[] | select(.content.state == "CLOSED" and .fieldValueByName.name != "Done" and .fieldValueByName.name != null and .fieldValueByName.name != "") | "  - Issue #\(.content.number) [Closed] Status:\(.fieldValueByName.name)")
  ' 2>/dev/null
else
  echo "（プロジェクトなし）"
  echo ""
  echo "ヒント: 紐付け先 Project が必要なら \`/new-project\` で作成 + リポリンクできます。"
fi
echo ""

# === オープン Issue（15件に制限） ===
echo "### オープン Issue"
gh issue list --state open --limit 15 \
  --json number,title,labels,assignees \
  --jq '.[] | "#\(.number) [\(.labels | map(.name) | join(","))] \(.title) @\(.assignees | map(.login) | join(","))"' 2>/dev/null
echo ""

# === オープン PR（マージ待ちの可視化: auto mode で滞留させないため） ===
echo "### オープン PR"
PR_JSON=$(gh pr list --state open --limit 20 \
  --json number,title,isDraft,mergeable,reviewDecision,statusCheckRollup,headRefName,body 2>/dev/null)
if [ -n "$PR_JSON" ] && [ "$PR_JSON" != "[]" ] && [ "$PR_JSON" != "null" ]; then
  echo "$PR_JSON" | jq -r '
    def checkstate:
      (.statusCheckRollup // []) as $c
      | if   ($c | length) == 0 then "checks:none"
        elif ($c | map(select((.conclusion // .state // "") | test("FAIL|ERROR|CANCEL|TIMED"))) | length) > 0 then "checks:✗"
        elif ($c | map(select(((.status // "COMPLETED") != "COMPLETED") or ((.state // "") == "PENDING"))) | length) > 0 then "checks:pending"
        else "checks:✓" end;
    .[] |
    ([.headRefName | scan("#[0-9]+")] | (.[0] // "?")) as $issue |
    ((.body // "") | test("(?i)(close[sd]?|fix(es|ed)?|resolve[sd]?) +#[0-9]+")) as $hasCloses |
    "- PR #\(.number) \(.title)\n    Issue:\($issue) | \(if .isDraft then "draft" else "ready" end) | mergeable:\(.mergeable) | review:\(.reviewDecision // "NONE") | \(checkstate)\(if $hasCloses then "" else " | ⚠Closes未記載" end)"
  ' 2>/dev/null
else
  echo "（オープン PR なし）"
fi
echo ""

# === 直近完了 + チェックリスト未完了×Closed の異常検知 ===
echo "### 最近完了 (5件)"
RECENT_CLOSED=$(gh issue list --state closed --limit 5 \
  --json number,title,closedAt,body 2>/dev/null)

if [ -n "$RECENT_CLOSED" ]; then
  echo "$RECENT_CLOSED" | jq -r '.[] | "#\(.number) \(.title) (\(.closedAt[:10]))"'

  # 異常検知: 本文に未完了チェック `- [ ]` を含む Closed Issue を列挙
  ANOMALIES=$(echo "$RECENT_CLOSED" | jq -r '
    .[] | select(.body | test("(?m)^\\s*- \\[ \\]")) |
    "- #\(.number) \(.title) — 未完了チェックあり"
  ' 2>/dev/null)

  if [ -n "$ANOMALIES" ]; then
    echo ""
    echo "**⚠ 異常: チェックリスト未完了で Closed の Issue**"
    echo "$ANOMALIES"
  fi
fi
echo ""

# === 親子関係（直近 Open 30 件） ===
RELATIONS_JSON=$(gh api graphql -f query='
  query($owner: String!, $repo: String!) {
    repository(owner: $owner, name: $repo) {
      issues(first: 30, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
        nodes {
          number title body
          parentIssue { number }
        }
      }
    }
  }
' -f owner="$OWNER" -f repo="$REPO_NAME" 2>/dev/null)

if [ -n "$RELATIONS_JSON" ] && [ "$RELATIONS_JSON" != "null" ]; then
  RELATIONS_OUT=$(echo "$RELATIONS_JSON" | jq -r '
    .data.repository.issues.nodes[]? |
    (.body // "" | split("\n") | map(select(test("^\\s*- \\[[ x]\\]"))) | map(scan("#([0-9]+)")) | flatten | unique) as $refs |
    select(.parentIssue.number != null or ($refs | length) > 0) |
    "- #\(.number) \(.title)"
    + (if .parentIssue.number then "\n    parent: #\(.parentIssue.number)" else "" end)
    + (if ($refs | length) > 0 then "\n    body チェックリスト参照: \($refs | map("#" + tostring) | join(", "))" else "" end)
  ' 2>/dev/null)

  if [ -n "$RELATIONS_OUT" ]; then
    echo "### 親子関係（直近 Open 30 件）"
    echo "$RELATIONS_OUT"
    echo ""
  fi
fi

# === Git 状態 ===
echo "### Git"
echo "branch: $(get_current_branch)"
UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
echo "uncommitted: ${UNCOMMITTED}件"
if [ "$UNCOMMITTED" -gt 0 ] && [ "$UNCOMMITTED" -lt 10 ]; then
  git status --porcelain 2>/dev/null
fi
echo ""
echo "recent:"
git log --oneline -3 2>/dev/null
echo ""

# === 整合性監査指示 ===
cat <<'AUDIT'
### 整合性監査
上記のプロジェクト状態とワークフロールール（issue-lifecycle Skill）を照合し、
矛盾や不整合があれば issue-manager サブエージェントをバックグラウンド
（run_in_background: true）で起動して修復すること。

代表的な異常パターン:
- Closed プロジェクトに Open Issue が残っている
- リポリンク切れ（リポリンク:✗）
- Open Issue なのに Status:Done / Closed Issue なのに Status:Todo 等のステータス乖離
- **親子関係の不整合**（上記「親子関係」セクションを参照）
  - 親 A の body チェックリストに #B あり、だが #B の parent が A でない → 紐付け漏れ
  - #B の parent が A、だが A の body チェックリストに #B なし → 親記述漏れ
- **チェックリスト未完了で Closed**（= 作業が終わっていないのに閉じている）
  → reopen してチェックを埋めるか、ユーザーに「意図的に閉じたか」を確認
- **マージ待ち PR の滞留**（上記「オープン PR」セクション参照）
  - `checks:✓` かつ review が承認/不要で `ready` な PR → マージして Issue を閉じ、ワークフローを完了させる
  - PR は merge 済みなのに対応 Issue が Open / Status≠Done → Issue を閉じ Status を Done に揃える
  - Issue が In Progress なのに open PR も最近の commit も無い → 停滞。状況を確認し再開 or クローズ

**auto mode（自律実行）での完了駆動 — 重要:**
PR 作成で作業を止めないこと。プラグインの hook は「悪い操作を止める」防御であり、
完了まで前進させるのは Claude の責務。`checks:✓` で `ready` な PR は
`/finish #N`（または `gh pr merge` → 必要なら `gh issue close`）で
**マージ → Issue クローズ → Status:Done まで駆動**し、ワークフローを完了させる。

矛盾がなければ監査スキップ。メインの作業はブロックしないこと。
AUDIT
