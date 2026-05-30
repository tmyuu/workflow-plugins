---
description: "作業を完了させる。チェックリスト確認 → PR マージ → Issue クローズ → Status Done を一括駆動する /start と対称のエントリポイント。"
---

指定された Issue の作業を**完了まで駆動**してください。`/start` の対になるコマンドで、
auto mode で PR が滞留したり Issue が閉じ忘れられるのを防ぐ終端です。

## 引数

$ARGUMENTS

引数は Issue 番号（例: `88` または `#88`）。**省略された場合は現在ブランチ `feature/#N-...` から推測**し、推測できなければユーザーに確認すること。

## 手順（issue-manager に委譲可能）

### 1. 対象の特定・前提検証

- `$ARGUMENTS` から数字を取り出す。無ければ `git rev-parse --abbrev-ref HEAD` の `#N` から推測
- `gh issue view N --json number,title,state,body` で取得。取得不可ならエラー報告し中断
- **未完了チェックリストの確認**: 本文に `- [ ]` が残っていれば中断し、ユーザーに提示
  - 完了済みなら先に `/update-issue` でチェックを埋めてから再実行を促す
  - 対応不要な項目があればユーザーに確認（勝手に潰さない）

### 2. PR の特定・整備

- 現在ブランチ、または Issue に紐づく open PR を `gh pr list --head <branch> --json number,body,isDraft,mergeable,statusCheckRollup,reviewDecision` で特定
- PR が存在しなければ「先に PR を作成してください」と報告し中断（PR 作成はこのコマンドの責務外）
- **PR 本文に `Closes #N` が無ければ追記**（`gh pr edit N --body ...`）。これが無いとマージで Issue が自動クローズされない
- `isDraft` なら ready 化（`gh pr ready N`）するかユーザーに確認
- **checks が失敗/保留なら中断**し状況を報告（緑になってからマージ）。review が必須で未承認ならユーザーに確認

### 3. マージ

- `gh pr merge N --squash --delete-branch`（リポの方針があれば従う）
- `guard-close.sh` が未完了チェックリストを再検証する。ブロックされたら手順1へ戻る

### 4. クローズ・ステータス確認

- マージで `Closes #N` により Issue が自動クローズされたか `gh issue view N --json state` で確認
- 閉じていなければ `gh issue close N`（`guard-close.sh` のチェックを通す）
- `auto-status-transition.sh` が Status を Done に遷移させる。反映されていなければ `/update-issue` 相当で Done に揃える

### 5. 後片付け・完了報告

- `git checkout main && git pull` でメインを最新化（ローカルブランチは削除済みなら何もしない）
- 端的に報告:
  - Issue #N タイトル / マージした PR #M
  - Issue state（Closed）と Status（Done）
  - 親 Issue があればチェックリスト連動の結果（`auto-update-parent-checklist.sh`）
  - 次アクション提案（残りの In Progress / Todo Issue があれば提示）

## 禁止事項

- **未完了チェックリストのまま完了させない**（手順1で必ず止める）
- PR が無い状態でマージを試みない（PR 作成はユーザー or 別フロー）
- checks 失敗・未承認 review を無視してマージしない（ユーザー確認なしに強行しない）
- ユーザーに確認せず複数 Issue を一括クローズしない（対象は引数 / 現在ブランチの 1 件）
