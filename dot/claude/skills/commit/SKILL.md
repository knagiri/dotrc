---
name: commit
description: Create a git commit with staged/unstaged changes. Use when the user asks to commit, save changes, or says "commitして".
---

# Git Commit

変更内容を分析して Conventional Commits 形式で英語のコミットメッセージを作成する。

## 手順

1. `git status` で変更状況を確認（未ステージのファイルも含む）
2. `git diff` と `git diff --staged` で変更内容を把握
3. 変更が未ステージの場合、関連ファイルを `git add` する
   - `.env` やクレデンシャル系ファイルは除外すること
4. `git log --oneline -5` で直近のコミットスタイルを確認
5. 変更内容に基づいて Conventional Commits 形式のメッセージを作成
6. `git commit` を実行

## コミットメッセージ規約

- 形式: `<type>: <description>`
- type: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `style`, `perf`, `ci`
- description は英語、小文字始まり、末尾ピリオドなし
- 1行目は50文字以内を目指す
- 必要に応じて本文（body）を追加
- 要点を掻い摘んでシンプルなメッセージとする

## 例

```
feat: add user authentication middleware
fix: resolve null pointer in payment processing
chore: update dependency versions
refactor: extract validation logic into shared module
```
