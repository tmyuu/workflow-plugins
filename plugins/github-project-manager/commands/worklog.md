---
description: "向き合っていた作業時間（工数）を集計し、ローカル保存 + GitHub（Issue コメント・Project 工数フィールド）へ同期する。"
---

工数を集計して記録してください。

## 引数

$ARGUMENTS

引数は Issue 番号（例: `87`）。**省略時は全 Issue を集計**する。

## 仕組み

`UserPromptSubmit` / `Stop` hook（`worklog-heartbeat.sh`）が、対話のたびに
`epoch 時刻 + ブランチ + Issue` を `.claude/worklog/heartbeats.jsonl` に記録している。
このコマンドは集計スクリプトを実行し、ローカルと GitHub の両方に反映する。

## 手順

1. 集計スクリプトを実行する（パスはプラグインに同梱）:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/worklog-aggregate.sh" $ARGUMENTS
   ```
   - `${CLAUDE_PLUGIN_ROOT}` が展開されない場合は、`github-project-manager` プラグインの
     `scripts/worklog-aggregate.sh` を探して実行する
   - 連続ハートビート間の差分を `min(差分, IDLE_CAP=15分)` でクランプして加算する
     （離席・夜跨ぎを過大計上しない）

2. スクリプトが行うこと（確認のみ。手動で再実行しない）:
   - ローカル: `.claude/worklog/issue-<N>.json` に集計結果を保存（actor 付き）
   - GitHub①: **人別コメント** `<!-- worklog actor=<login> hours=<H> -->` を冪等 upsert（累計 + 日別内訳）
   - GitHub②: Project の Number フィールド「工数(h)」へ、**その Issue の全メンバー合計**を同期（無ければ自動作成）

3. スクリプトの出力（Issue ごとの累計時間）を端的に報告する。

## オプション / 注意

- ローカルのみ更新したい場合: `WORKLOG_NO_GITHUB=1` を付けて実行
- アイドル閾値を変えたい場合: `WORKLOG_IDLE_CAP=600`（秒）等
- 生ログ `heartbeats.jsonl` は `.claude/worklog/.gitignore` で git 管理外。閾値を変えて再集計できる
- 計測は「向き合っていた時間」の近似であり、厳密な実時間ではない旨をユーザーに伝える
