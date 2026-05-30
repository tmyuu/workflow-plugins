---
name: issue-lifecycle
description: "Issue ライフサイクルのルール。コミット・Issue 作成・PR・マージ時に自動適用される。"
user-invocable: false
---

# Issue ライフサイクルルール

プラグインは以下の **4 つの制御軸**で GitHub を型に沿って使わせる。
分類基準（フェーズ / 重要度 / タイプ / ステータス）の一次情報は `config/taxonomy.json`。

---

## 軸 1: 型通りに作る

### Issue 作成（/new-issue, /new-minutes, /new-acceptance）
- 作成前に**既存オープン Issue を確認**し、重複を避ける
- タイトルは**クライアントが読む**前提（技術用語を最小限に）
- 本文は**後から見返して経緯がわかる**（背景 / 目的 / 完了条件 / アクションアイテム）
- アクションアイテムは**チェックリスト形式**で分解

### Label / Type の切り分け（重要）

| 軸 | 意味 | 値（taxonomy.json） |
|----|------|------|
| **Label（2 軸必須）** | いつ・どれくらい重要か | フェーズ（ヒアリング/見積もり/開発/テスト/納品）＋ 重要度（重要度:高/中/低） |
| **Type（Issue Types）** | Issue の性質 | Task / Bug / Feature / Minutes / Acceptance |

- **Type 語（bug/task/feature/minutes/acceptance/バグ/機能 等）を Label として使わない** — `guard-issue-create.sh` がブロック
- 個人リポジトリでは Issue Type が使えないのでスキップ（Label のみ）

### コミット
- メッセージに **必ず Issue 番号（#N）を含める** — `guard-commit.sh` がブロック
- 対応 Issue がなければ先に Issue を立てる

### ブランチ（/start #N 推奨）
- `feature/#N-description` or `fix/#N-description` — `guard-branch.sh` がブロック
- ブランチ切替時に Issue の**実在・状態(open)を検証**
- `/start #N` で ブランチ作成 + Status In Progress を一発で

### PR
- 本文に `Closes #N` を必須 — `guard-pr-create.sh` がブロック
- Label / Project は対応 Issue と同じ
- PR タイトルは短く（70 文字以内）

### 完了させる（/finish #N 推奨）
- **PR 作成で止めない**。`/start` で始めた作業は `/finish` で終わらせる
- `/finish #N`: 未完了チェック確認 → PR マージ → Issue クローズ → Status:Done を一括駆動
- **auto mode（自律実行）では特に重要**: hook は「悪い操作を止める」防御であり、
  完了まで前進させるのは Claude の責務。`checks:✓` で `ready` な PR は放置せずマージまで進める
- SessionStart の「オープン PR」セクションでマージ待ちを可視化 → 滞留を検出して完了させる

---

## 軸 2: 親子関係を最適に保つ

- 親子関係は **GitHub Sub-issues API** で設定する（`Parent: #N` テキストは使わない）
  ```bash
  CHILD_ID=$(gh api repos/{owner}/{repo}/issues/{child} --jq '.id')
  gh api repos/{owner}/{repo}/issues/{parent}/sub_issues -F sub_issue_id="$CHILD_ID"
  ```
- **親 Issue のチェックリストに子 #N を必ず記載**（`- [ ] #123 子の概要`）
- 子クローズで親チェックリストを**自動連動**（`auto-update-parent-checklist.sh`）
- SessionStart で **親子整合性を監査**（以下の矛盾を LLM に見せる）
  - 親 body チェックリストに #B あり、だが #B の parent が親でない → 紐付け漏れ
  - #B の parent が親、だが親 body チェックリストに #B なし → 親記述漏れ

### 作業の分割判断（子 Issue に切り出す）

以下に該当したらサブ Issue に分割:
- **独立した変更が複数ある**
- **スコープが膨らんでいる**
- **作業中に別の問題を発見した**

### Relationships 使い分け
- **Sub-issues**: 親タスクの一部
- **Blocks / Blocked by**: 依存関係（例: 実装 → テスト → 検収 → 納品）
- **Duplicates**: 重複 Issue（`gh issue close --reason "not planned"` と併用）

---

## 軸 3: ステータスを作業実態に合わせる

- Status: **Todo → In Progress → Done**（taxonomy.json `status.flow`）
- 自動遷移（`auto-status-transition.sh`）:
  - commit（Todo 時）→ In Progress
  - gh issue close → Done
  - gh pr merge → Done（Closes #N の対象、または PR ブランチ由来の Issue）
- 手動変更も尊重（すでに In Progress / Done なら素通り）
- **GitHub Projects v2** のみ対応。プロジェクトに紐付いていない Issue は遷移しない

> **構造的注意（hook の限界）**: 自動遷移は `gh pr merge` / `gh issue close` を **コマンドで実行した時のみ**発火する。
> GitHub の Web UI・auto-merge・モバイルでマージ/クローズすると PostToolUse hook は発火せず、
> **Status が In Progress のまま乖離**する。これは hook では原理的に塞げないため、
> **SessionStart の整合性監査での照合・修復が唯一の担保**（「Closed Issue × Status≠Done」「Open Issue × Status:Done」を検出）。
> なるべくマージ/クローズはコマンド（`/finish` 等）経由で行うこと。

### プロジェクト管理
- プロジェクトは**既存のものに紐付ける**のが原則（直接の `gh project create` は `guard-project-create.sh` でブロック）
- 新規 Project が必要な場合は **`/new-project` を使う**（作成 + リポジトリリンクを一括、`CLAUDE_NEW_PROJECT_ALLOW=1` で例外通過）
- リポリンクなしの Project を放置しない（SessionStart で `リポリンク:✗` として検出される）
- Issue は `--project` で紐付け

### 検収（Acceptance）のステータス運用
- `/new-acceptance` 作成時は Todo
- 前工程完了で `/update-issue` で In Progress に遷移（= クライアント通知）
- **承認 / 差し戻しはクライアントが GitHub 上で手動実施**（プラグインは介入しない）

---

## 軸 4: チェックリストを潰さずにクローズしない

- クローズ前に未完了チェックリストを**全経路でハードゲート検証**（`guard-close.sh`）
  - `gh issue close N`
  - `gh issue edit N --state closed`
  - `gh pr merge`（PR 本文の Closes #N、無ければブランチ由来 Issue を推測）
  - `gh api graphql ... closeIssue / updateIssue {state: CLOSED}` → ブロック（誘導のみ）
- SessionStart で **チェック未完了 × Closed** を異常として検出・LLM 修復
- 完了した項目は都度 `/update-issue` でチェックを埋めていく（溜めない）

---

## 工数記録（worklog）

「LLM に向き合っていた時間」を Issue 単位で自動計測する。

- **計測**: `UserPromptSubmit` / `Stop` hook（`worklog-heartbeat.sh`）が対話のたびに
  `epoch 時刻 + ブランチ(→#N)` を `.claude/worklog/heartbeats.jsonl` に無音追記
- **集計**: `/worklog [#N]` で連続ハートビート間の差分を `min(差分, IDLE_CAP=15分)` でクランプ加算
  - 離席・夜跨ぎは上限でカットされ過大計上しない（= 厳密な実時間ではなく「向き合っていた時間」の近似）
  - Issue 帰属は `feature/#N` ブランチから解決
- **保存先**: ローカル `.claude/worklog/issue-<N>.json`（生ログは gitignore、閾値変更で再集計可）
  ＋ Issue コメント `<!-- worklog -->` の冪等 upsert ＋ Project Number フィールド「工数(h)」

## やってはいけないこと

- Issue 番号なしのコミット
- **未完了チェックリストのままクローズ**（全経路でブロックされる）
- **Type 語を Label として使う**（`guard-issue-create.sh` がブロック）
- **親子関係をテキストで表現**（`Parent: #N` は使わない → Sub-issues API）
- ラベルやタイプの後からの変更（原則。typo 修正は可）
- ユーザーに確認せずに Issue をクローズ
- `git push --force` を main ブランチに実行
- プロジェクトをリポジトリにリンクせずに放置
- `feature/#N` ブランチ上で **Issue #N の範囲外の作業**を始める（範囲外なら /new-issue で別 Issue）
