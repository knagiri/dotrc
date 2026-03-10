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
6. コードレビュー & 修正ループ（後述）
7. 分割判定の結果に応じて push & PR 作成:
   - **分割なし**: `git push -u origin HEAD` → `gh pr create`
   - **分割あり**: 分割案をユーザーに提示し、承認後に各 PR を順次作成
     - `git push origin $(git branch --show-current):<remote-branch>` で push（`git pas` 相当）
     - `gh pr create --head <remote-branch>` で PR 作成
8. 作成された PR の URL を表示

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

## コードレビュー & 修正ループ

push 前に CodeRabbit でコードレビューを実行し、指摘事項を修正する。

### 前提チェック

```bash
coderabbit --version 2>/dev/null && coderabbit auth status 2>&1 | head -3
```

結果に応じてレビュー手段を決定する:

- **CodeRabbit が利用可能**: CodeRabbit でレビュー（後述）
- **CLI 未インストールまたは未認証**: ユーザーに CodeRabbit が使えない旨を通知し、**Claude Code の sub-agent（`coderabbit:code-reviewer` タイプ）で代替レビューを実施する**（後述）

### レビュー実行: CodeRabbit

```bash
coderabbit review --plain --base <base>
```

### レビュー実行: Claude Code sub-agent（フォールバック）

CodeRabbit が利用できない場合、Task ツールで `coderabbit:code-reviewer` サブエージェントを起動し、`git diff <base>...HEAD` の差分を渡してレビューさせる。

サブエージェントには以下の観点でレビューを依頼する:
- セキュリティ脆弱性（インジェクション、認証・認可の不備等）
- バグになりうるパターン（エラーハンドリング漏れ、エッジケース等）
- コード品質（重複、複雑度、命名等）

結果は CodeRabbit と同じフォーマット（Critical / Suggestions）で報告させる。

### 結果の判定と対応

レビュー結果（CodeRabbit / sub-agent いずれの場合も同様）を **Critical（セキュリティ・バグ）** と **Suggestions（改善提案）** に分類する。

- **Critical な指摘がある場合**:
  1. 指摘内容と修正方針をユーザーに報告
  2. ユーザーの承認を得てコードを修正
  3. 修正を commit
  4. 再度レビューを実行（同じ手段を使う）
  5. Critical な指摘がなくなるまで繰り返す（最大3回）
  6. 3回で解消しない場合、残りの指摘を報告して続行するか確認する
- **Suggestions のみの場合**: 指摘内容をユーザーに報告し、対応するか確認する
  - 対応する場合: 修正 → commit → 再レビュー
  - スキップする場合: 次の手順へ進む
- **指摘なしの場合**: そのまま次の手順へ進む

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
