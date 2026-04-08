---
name: my-commit
description: Conventional Commits 形式で変更をステージ・commitする
allowed-tools: Bash(git status *), Bash(git diff *), Bash(git log *), Bash(git add *), Bash(git commit *), Bash(echo *), Read, Glob, Grep
---

## Pre-fetched context

!`git status --short`
!`git diff --stat`
!`git log --oneline -5`

## Instructions

変更をcommitする。完了後にまとめを出力しないこと。

1. **変更を論理単位に分割する。** 原則は分割。結合するのは、片方がなければもう片方が意味をなさないほど密結合な場合のみ。各ファイル・ハンクを以下の観点で分類する:
   - **スコープ**が異なる（例: 異なるアプリ、異なるパッケージ） → 別commit
   - **意図**が異なる（例: バグ修正 vs 新機能 vs リファクタリング vs ドキュメント） → 別commit
   - 構造的整理と振る舞いの変更が混在 → 別commit（構造整理を先にする）
   - 迷ったら分割する。小さいcommitのほうがレビューもリバートも容易。
   - このPRと関係のない変更はcommitしない
2. commitごとに: `git add <files>` → `git diff --cached --stat` → commit
3. メッセージ: Conventional Commits 形式 (`type(scope): description`)、**常に英語**（ユーザーの言語によらず）、命令形。
   - body にはその変更を行った**理由**や背景を簡潔に記述する。将来の読み手が diff を読み直さなくても動機を理解できる程度に。
   - subject line だけで自明な場合（例: typo 修正）に限り body を省略してよい。
4. ユーザーへの確認が必要なのは以下の場合**のみ**: 無関係な変更が多数あり分類が不明確、シークレットの可能性がある、commitすべきでない生成ファイルが含まれる。
