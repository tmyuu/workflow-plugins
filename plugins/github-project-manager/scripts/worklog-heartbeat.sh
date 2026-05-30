#!/bin/bash
# UserPromptSubmit / Stop: 工数計測のハートビートを記録する。
# 「向き合っていた時間」を後で算出するため、各イベントの epoch 時刻 + ブランチ + Issue を追記。
#   - 集計は worklog-aggregate.sh が連続ハートビート間の差分を IDLE_CAP でクランプして行う
#   - stdout には何も出さない（UserPromptSubmit の stdout はコンテキストに注入されるため無音必須）

source "$(dirname "$0")/lib.sh"

DIR=$(worklog_dir)
mkdir -p "$DIR" 2>/dev/null || exit 0

# 生ログは git 管理しない（自己完結 .gitignore）。集計結果 issue-<N>.json は追跡可能なまま残す。
if [ ! -f "$DIR/.gitignore" ]; then
  printf 'heartbeats.jsonl\n' > "$DIR/.gitignore" 2>/dev/null
fi

BRANCH=$(get_current_branch)
ISSUE=$(echo "$BRANCH" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | head -1)
T=$(date +%s)

printf '{"t":%s,"branch":"%s","issue":"%s"}\n' "$T" "$BRANCH" "$ISSUE" >> "$DIR/heartbeats.jsonl" 2>/dev/null

exit 0
