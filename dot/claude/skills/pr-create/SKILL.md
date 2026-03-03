---
name: pr-create
description: Push the current branch and create a GitHub pull request. Use when the user asks to create a PR, push and make a PR, or says "PR作成して".
---

# Push & PR 作成

現在のブランチをリモートに push し、GitHub Pull Request を作成する。

## 手順

1. デフォルトブランチを取得: `gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'`
   - 以降このブランチ名を `<base>` とする
2. `git status` で未コミットの変更がないか確認
   - 未コミットの変更がある場合、先にコミットするか確認する
3. `git log --oneline <base>..HEAD` でこのブランチの全コミットを確認
4. `git diff <base>...HEAD` で差分の全体像を把握
5. designdoc を探索し、PR 分割戦略を決定する（後述）
6. 分割判定の結果に応じて push & PR 作成:
   - **分割なし**: `git push -u origin HEAD` → `gh pr create`
   - **分割あり**: 分割案をユーザーに提示し、承認後に各 PR を順次作成
     - `git push origin $(git branch --show-current):<remote-branch>` で push（`git pas` 相当）
     - `gh pr create --head <remote-branch>` で PR 作成
7. 作成された PR の URL を表示

## PR 分割戦略

### designdoc の探索

リポジトリルートから以下のパターンで designdoc / ADR を探す:

```
**/docs/adr/**
**/docs/designdoc/**
```

見つかった場合、現在の作業に関連するドキュメントを特定する（ブランチ名・変更ファイルのパスから推測）。

### 分割判定

- **designdoc に PR 分割の記述がある場合**: その指示に従って分割する。各 PR のスコープ（どのファイル・機能を含むか）を designdoc から読み取る
- **designdoc はあるが分割の記述がない場合**: 変更差分から判断する（以下のルール）
- **designdoc が見つからない場合**: 変更差分から判断する（以下のルール）

### 差分ベースの分割判定ルール

`git diff <base>...HEAD` の内容を分析し、以下の観点で分割を提案する:

1. **機能的な独立性**: 異なる機能に属する変更は別 PR にする
2. **レビュー負荷**: 差分が大きすぎる場合（目安: 400行超）は分割を検討
3. **依存関係の方向**: 基盤的な変更（型定義、共通ユーティリティ等）を先に、それを利用する変更を後に

分割が必要と判断した場合:
1. 分割案をユーザーに提示する（各 PR のスコープとリモートブランチ名の案）
2. ユーザーの承認を得てから実行

## PR フォーマット

- **タイトル**: 日本語、30文字以内、Conventional Commits の type プレフィックス付き
- **本文**: 日本語で記述

### テンプレートの確認

まず git リポジトリのルートに `.github/PULL_REQUEST_TEMPLATE.md` が存在するか確認する。

- **存在する場合**: テンプレートの構造とセクションに従って本文を作成する
- **存在しない場合**: 以下のデフォルトフォーマットを使う

### デフォルトフォーマット

```
gh pr create --title "<title>" --body "$(cat <<'EOF'
## 概要
<変更内容の要約を箇条書き>

## 変更点
<主な変更ファイルと内容の説明>

## テスト
<テスト方法や確認事項>
EOF
)"
```

## 注意事項

- デフォルトブランチから直接 PR を作成しない。現在のブランチがデフォルトブランチの場合はユーザーに確認する
- draft PR を作成したい場合は `--draft` フラグを使う（ユーザーが指示した場合のみ）
- ベースブランチは明示的な指示がなければデフォルトブランチを使う
