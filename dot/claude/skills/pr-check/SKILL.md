---
name: pr-check
description: Check PR review comments and CI status, then fix issues. Use when the user asks to check a PR, handle review feedback, or says "PR確認して".
argument-hint: "[PR number or remote-branch-name]"
---

# PR 確認 & 対応

現在のブランチ（または指定された PR）のレビューコメントと CI ステータスを確認し、必要に応じて修正する。

## 手順

### 1. 準備

- デフォルトブランチを取得: `gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'`
- PR の特定（以下の優先順で判定）:
  1. 引数が数値の場合: PR 番号として使う
  2. 引数が文字列の場合: リモートブランチ名として `gh pr view <branch-name>` で PR を取得
  3. 引数なしの場合: `gh pr view --json number,url` で現在のブランチの PR を取得
     - 見つからない場合、`git pas` で別名 push されている可能性がある。ユーザーにリモートブランチ名または PR 番号を確認する

### 2. レビューコメントの確認

```bash
gh pr view <number> --json reviews,comments --jq '.reviews[] | {author: .author.login, state: .state, body: .body}'
gh api repos/{owner}/{repo}/pulls/<number>/comments --jq '.[] | {path: .path, line: .line, body: .body, author: .user.login}'
```

- 全レビューコメントを一覧表示
- APPROVED / CHANGES_REQUESTED / COMMENTED の状態を報告
- 未解決の指摘事項をリストアップ

### 3. CI ステータスの確認

```bash
gh pr checks <number>
```

- **実行中のチェックがある場合**: `gh pr checks <number> --watch` で完了まで待機する
- 全チェック完了後、各チェックの成否を報告
- 失敗しているチェックがあればログを確認:
  ```bash
  gh run view <run-id> --log-failed
  ```

### 4. 問題への対応

レビュー指摘や CI 失敗がある場合:

1. 指摘内容・失敗内容をユーザーに要約して報告
2. 修正方針を提案
3. ユーザーの承認を得てからコード修正を実施
4. 修正後、commit & push
   - 元の PR が `git pas` で作成されている場合、同じリモートブランチ名に push する

### 5. 結果報告

以下を日本語で簡潔に報告:

- レビュー状況（承認済み / 指摘あり / 未レビュー）
- CI 状況（全パス / 失敗あり）
- 実施した修正の概要（修正した場合）
