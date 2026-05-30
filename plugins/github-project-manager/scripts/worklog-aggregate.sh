#!/bin/bash
# 工数の集計と GitHub 同期。
#   入力: .claude/worklog/heartbeats.jsonl（worklog-heartbeat.sh が追記）
#   計測: Issue 単位に、連続ハートビート間の差分を min(差分, IDLE_CAP) でクランプして加算
#         → 離席・夜跨ぎを過大計上せず「向き合っていた時間」に近づける
#   出力:
#     - ローカル: .claude/worklog/issue-<N>.json（一次データの集計結果）
#     - GitHub①: Issue コメント <!-- worklog --> を冪等 upsert（累計 + 日別内訳）
#     - GitHub②: Project Number フィールド「工数(h)」へ同期（無ければ作成）
#
# usage: worklog-aggregate.sh [ISSUE_NUMBER]   # 省略時は全 Issue
# env:   WORKLOG_IDLE_CAP（秒, 既定 900=15分） / WORKLOG_FIELD（既定 "工数(h)"） / WORKLOG_NO_GITHUB=1 でローカルのみ

source "$(dirname "$0")/lib.sh"

has_jq || { echo "⚠ jq が必要です"; exit 0; }

DIR=$(worklog_dir)
LOG="$DIR/heartbeats.jsonl"
[ -f "$LOG" ] || { echo "（ハートビート記録がありません: $LOG）"; exit 0; }

IDLE_CAP=${WORKLOG_IDLE_CAP:-900}
FIELD_NAME=${WORKLOG_FIELD:-"工数(h)"}
FILTER_ISSUE=$(echo "${1:-}" | grep -oE '[0-9]+')

# Issue 単位に稼働秒数（クランプ加算）と日別内訳を算出
SUMMARY=$(jq -s --argjson cap "$IDLE_CAP" '
  def clamped_sum(cap):
    sort | . as $ts
    | reduce range(1; length) as $i (0; . + ([($ts[$i] - $ts[$i-1]), cap] | min));
  map(.issue = (if (.issue == null or .issue == "") then "general" else .issue end))
  | group_by(.issue)
  | map(
      (.[0].issue) as $issue
      | ([.[].t]) as $ts
      | { issue: $issue,
          seconds: ($ts | clamped_sum($cap)),
          days: ( $ts | group_by(. / 86400 | floor)
                  | map({ date: (.[0] | gmtime | strftime("%Y-%m-%d")),
                          seconds: clamped_sum($cap) }) ) }
    )
' "$LOG" 2>/dev/null)

[ -z "$SUMMARY" ] || [ "$SUMMARY" = "null" ] && { echo "（集計対象なし）"; exit 0; }

USE_GITHUB=1
[ "${WORKLOG_NO_GITHUB:-0}" = "1" ] && USE_GITHUB=0
if [ "$USE_GITHUB" = "1" ]; then
  has_gh && get_repo_info || USE_GITHUB=0
fi

# actor を一度だけ解決（heartbeats は同一マシン＝同一人物なので集計時に確定できる）
# GitHub login を優先（請求の帰属に使う）、無ければ git の名前にフォールバック
ACTOR=$(git config user.name 2>/dev/null | tr ' ' '_')
if [ "$USE_GITHUB" = "1" ]; then
  GH_LOGIN=$(gh api user --jq '.login' 2>/dev/null)
  [ -n "$GH_LOGIN" ] && ACTOR="$GH_LOGIN"
fi
[ -z "$ACTOR" ] && ACTOR="local"

echo "$SUMMARY" | jq -c '.[]' | while read -r row; do
  ISSUE=$(echo "$row" | jq -r '.issue')
  [ -n "$FILTER_ISSUE" ] && [ "$ISSUE" != "$FILTER_ISSUE" ] && continue
  SEC=$(echo "$row" | jq -r '.seconds')
  HOURS=$(jq -rn --argjson s "$SEC" '(($s / 3600) * 10 | round) / 10')

  # --- ローカル集計結果を保存（actor 付き）---
  echo "$row" | jq --argjson h "$HOURS" --arg a "$ACTOR" '. + { hours: $h, actor: $a }' > "$DIR/issue-${ISSUE}.json"

  # --- コメント本文（人別マーカー: actor ごとに冪等 upsert）---
  DAYS=$(echo "$row" | jq -r '.days[] | "- \(.date): \(((.seconds / 3600) * 10 | round) / 10)h"')
  BODY="<!-- worklog actor=${ACTOR} hours=${HOURS} -->
⏱ 累計工数（@${ACTOR}）: ${HOURS}h
${DAYS}"

  echo "Issue #${ISSUE}: ${HOURS}h (@${ACTOR})"

  # general（非 Issue ブランチの作業）はローカルのみ。GitHub 同期は数値 Issue だけ
  case "$ISSUE" in ''|*[!0-9]*) continue ;; esac
  [ "$USE_GITHUB" = "1" ] || continue

  # --- GitHub①: 自分(actor)のコメントだけ冪等 upsert（他人の分は触らない）---
  COMMENTS=$(gh api "repos/$OWNER/$REPO_NAME/issues/${ISSUE}/comments" --paginate 2>/dev/null)
  CID=$(echo "$COMMENTS" | jq -r --arg a "$ACTOR" '.[] | select(.body | startswith("<!-- worklog actor=" + $a + " ")) | .id' 2>/dev/null | head -1)
  if [ -n "$CID" ] && [ "$CID" != "null" ]; then
    gh api -X PATCH "repos/$OWNER/$REPO_NAME/issues/comments/${CID}" -f body="$BODY" >/dev/null 2>&1
  else
    gh issue comment "$ISSUE" --body "$BODY" >/dev/null 2>&1
  fi

  # --- GitHub②: 全 worklog コメントを合算し Project フィールドへ（多人数合計・自己修復）---
  COMMENTS=$(gh api "repos/$OWNER/$REPO_NAME/issues/${ISSUE}/comments" --paginate 2>/dev/null)
  SUMH=$(echo "$COMMENTS" | jq -r '
    [ .[].body | (scan("<!-- worklog actor=[^ ]+ hours=([0-9.]+)") | .[0] | tonumber) ]
    | (add // 0) | (. * 10 | round) / 10' 2>/dev/null)
  [ -z "$SUMH" ] && SUMH="$HOURS"
  echo "  → Issue #${ISSUE} 合計: ${SUMH}h（全メンバー）"
  while IFS='|' read -r item_id project_id _title _status; do
    [ -z "$item_id" ] && continue
    FID=$(ensure_project_number_field "$project_id" "$FIELD_NAME")
    set_project_number "$project_id" "$item_id" "$FID" "$SUMH"
  done < <(list_issue_project_items "$ISSUE")
done

exit 0
