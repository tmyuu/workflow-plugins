# github-project-manager

GitHub を「型に沿って使いこなす PM」として振る舞う Claude Code プラグイン。

## 4 つの制御軸

プラグインが制御すべき観点を 4 つに集約:

```
┌────────────────────────────────────────────────────────────┐
│ 軸 1  型通りに作る                                          │
│   Issue/PR のタイトル・ラベル・タイプ・アサイン・プロジェクト│
│   コミット #N、ブランチ feature/#N-... or fix/#N-...        │
├────────────────────────────────────────────────────────────┤
│ 軸 2  親子関係を最適に                                      │
│   Sub-issues API で紐付け、親チェックリスト ↔ 子 Issue 整合 │
├────────────────────────────────────────────────────────────┤
│ 軸 3  ステータスを作業実態に合わせる                         │
│   Todo → In Progress → Done を commit / merge で自動追従     │
├────────────────────────────────────────────────────────────┤
│ 軸 4  チェックリストを潰さずにクローズしない                 │
│   全経路で未完了チェックリストのクローズをブロック           │
└────────────────────────────────────────────────────────────┘
```

各軸は **ハードゲート（bash で即ブロック）** と **LLM 推論型監査（SessionStart で状態注入 → Claude が整合性判断）** のハイブリッドで制御する。

## インストール

```
/plugin install github-project-manager@workflow-plugins
```

更新:
```
/plugin marketplace update workflow-plugins
/reload-plugins
```

**注**: Claude Code は `plugin.json` の `version` を見て再インストール要否を判定する。ユーザーに変更を配布するときは必ず **version を bump** する（セマンティックバージョニング推奨）。

## セットアップ

```
/init-workflow
```

CLAUDE.md 追記に加え、**taxonomy.json に沿って GitHub Label を同期**する（対話確認あり、破壊的変更なし）。

## ワークフロー

```
  [初期セットアップ]
   /new-project   → Project 作成 + リポジトリリンク（空リポからのブートストラップ）
   /init-workflow → CLAUDE.md 整備 + Label 同期

  [起点コマンド]                                [作業開始]
   ┌─ /new-issue       (Task/Bug/Feature) ─┐
   ├─ /new-minutes     (議事録)            │
   └─ /new-acceptance  (検収)              │       /start #N
                                           ▼          │
                                     [Issue 作成] ────┘
                                           │  ラベル/タイプ/プロジェクト設定
                                           │  ブランチ作成 + Status In Progress
                                           ▼
                                    [コミット／実装]
                                           │  コミットメッセージに #N 必須
                                           │  チェックリストを都度 /update-issue で埋める
                                           ▼
                                       [PR 作成]
                                           │  Closes #N 必須
                                           ▼          [作業完了]
                                   [PR マージ／クローズ] ◀──── /finish #N
                                           │  未完了チェックリストあればブロック
                                           │  マージ → クローズ → Status Done を一括駆動
                                           │  Status → Done に自動遷移
                                           │  親 Issue のチェックリストを自動連動
                                           ▼
                                      [Issue Closed]

  ※ Acceptance は作成後、検収作業（承認/差戻し）をクライアントが GitHub 上で手動実施
```

## 分類基準（taxonomy）

`config/taxonomy.json` が **分類基準の一次情報**。以下を定義:

| 軸 | 値 |
|----|-----|
| **Label: フェーズ** | ヒアリング / 見積もり / 開発 / テスト / 納品 |
| **Label: 重要度** | 重要度:高 / 重要度:中 / 重要度:低 |
| **Type**（Issue Types） | Task / Bug / Feature / Minutes / Acceptance |
| **Status** | Todo / In Progress / Done |

- **Label は 2 軸必須**（フェーズ + 重要度）。それ以外のカスタム Label は警告のみで許容
- **Type 語を Label にしない**（bug/task/feature/minutes/acceptance/バグ/機能 等はブロック）
- リポ固有カスタマイズは `.claude/workflow-taxonomy.json` でオーバーライド可

## Commands

| コマンド | 説明 |
|---------|------|
| `/new-project` | GitHub Project (v2) を作成 + リポジトリにリンク（空リポからのブートストラップ） |
| `/init-workflow` | CLAUDE.md を生成/更新。taxonomy に沿って GitHub Label を同期 |
| `/new-issue` | Task/Bug/Feature 向け汎用 Issue 作成 |
| `/new-minutes` | 議事録 md → Minutes Issue（md 未作成なら `docs/meetings/` にテンプレ生成） |
| `/new-acceptance` | 検収 Issue 作成（クライアントアサイン・前工程 Blocks by） |
| `/start #N` | 作業開始: Issue 検証 → ブランチ作成 → Status In Progress |
| `/finish #N` | 作業完了: チェック確認 → PR マージ → Issue クローズ → Status Done を一括駆動 |
| `/update-issue` | ステータス変更・アクションアイテム更新・子 Issue クローズ連動 |

## Hooks（軸ごとの実装）

| Hook | イベント | 担当軸 | 機能 |
|------|---------|--------|------|
| inject-project-state.sh | SessionStart | 横断 | プロジェクト/Issue/**オープン PR**/Git/**親子関係** 状態を注入、異常パターン（マージ待ち PR 滞留含む）を LLM に見せ完了まで駆動させる |
| review-prompt.sh | UserPromptSubmit | 1 | ブランチ状況に応じた行動指針、範囲外指示の警告 |
| guard-main-branch-edit.sh | PreToolUse(Edit/Write) | 1 | main 上のソースコード編集をブロック |
| guard-commit.sh | PreToolUse(Bash) | 1 | コミットメッセージの #N を検証 |
| guard-branch.sh | PreToolUse(Bash) | 1 | ブランチ名の #N + Issue 実在・状態(open)検証 |
| guard-issue-create.sh | PreToolUse(Bash) | 1 | **taxonomy 駆動**で Label/Type 検証、Type 語混入ブロック |
| guard-pr-create.sh | PreToolUse(Bash) | 1 | 必須オプション + Closes #N + **taxonomy 駆動 Label 検証** |
| guard-project-create.sh | PreToolUse(Bash) | 3 | プロジェクト新規作成をブロック（`/new-project` の `CLAUDE_NEW_PROJECT_ALLOW=1` で例外通過） |
| guard-close.sh | PreToolUse(Bash) | 4 | **全経路で未完了チェックリストのクローズをブロック** |
| review-issue-type.sh | PostToolUse(Bash) | 1 | org リポジトリでの Issue Type 設定リマインド |
| auto-status-transition.sh | PostToolUse(Bash) | 3 | commit → In Progress、close/merge → Done |
| auto-update-parent-checklist.sh | PostToolUse(Bash) | 2 | 子クローズで親チェックリストを自動連動 |
| auto-lint.sh | PostToolUse(Edit\|Write) | — | .ts/.tsx 編集後の自動 ESLint |

## Agents

| エージェント | 説明 |
|------------|------|
| issue-manager | Issue 作成・更新・クローズの専門エージェント |

## Skills

| スキル | 説明 |
|--------|------|
| issue-lifecycle | 4 軸構造のライフサイクルルール（常時読み込み） |

## 構成

```
github-project-manager/
├── config/
│   └── taxonomy.json                  # 分類基準の一次情報
├── hooks/
│   └── hooks.json
├── agents/
│   └── issue-manager.md
├── commands/
│   ├── new-project.md                 # Project 作成 + リポリンク
│   ├── init-workflow.md               # CLAUDE.md + Label 同期
│   ├── new-issue.md
│   ├── new-minutes.md
│   ├── new-acceptance.md
│   ├── start.md
│   ├── finish.md                     # 完了駆動: マージ→クローズ→Done
│   └── update-issue.md
├── skills/
│   └── issue-lifecycle/SKILL.md       # 4 軸構造
└── scripts/
    ├── lib.sh                         # 共通関数（taxonomy.sh を自動 source）
    ├── taxonomy.sh                    # taxonomy.json 読み出し
    ├── inject-project-state.sh
    ├── review-prompt.sh
    ├── review-issue-type.sh
    ├── guard-main-branch-edit.sh
    ├── guard-commit.sh
    ├── guard-branch.sh
    ├── guard-close.sh
    ├── guard-issue-create.sh
    ├── guard-pr-create.sh
    ├── guard-project-create.sh
    ├── auto-status-transition.sh
    ├── auto-update-parent-checklist.sh
    └── auto-lint.sh
```

## 設計方針

### ハードゲート（bash）
Issue 番号なしコミット、未完了クローズ、main 直接編集、**Type 語の Label 混入**、フェーズ/重要度の欠落など、
**ルール的に明確な違反**は hook で即ブロックし stderr で自己修正を促す。

### LLM 推論型監査（SessionStart で状態注入）
プロジェクト・Issue・Git・**親子関係**の状態を包括的に出力し、Claude 自身が整合性を判断する。
矛盾を見つけたら issue-manager サブエージェントをバックグラウンドで起動して修復。

> 「監査役が裏で常に回っている」イメージ。bash でパターン列挙するのではなく、
> 全状態をデータとして出し、LLM に推論させる。

## CLAUDE.md の書き方

プラグイン導入後、リポジトリの `.claude/CLAUDE.md` を以下のガイドラインで書く。

- **200 行以内**に収める（[Anthropic ベストプラクティス](https://code.claude.com/docs/en/memory)）
- Claude がコードから推測できない情報だけ書く
- 重要なルールには `IMPORTANT:` を付ける
- GitHub ワークフローの詳細はインポートで委譲: `@.claude/skills/issue-lifecycle/SKILL.md`

### 推奨セクション構成

```markdown
# プロジェクト名

一行説明。

## コマンド
## アーキテクチャ
## ハマりどころ

## GitHub ワークフロー

@.claude/skills/issue-lifecycle/SKILL.md
```
