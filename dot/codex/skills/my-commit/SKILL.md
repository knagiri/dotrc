---
name: my-commit
description: 指定された変更を論理単位に分け、Conventional Commits 形式で stage・commit する。
---

1. `git status --short`、`git diff`、`git diff --cached`、`git log --oneline -5` で対象と既存の stage を確認する。無関係な変更は作業ツリーにも index にも手を加えずに残す。混ざっている変更の帰属が不明な場合や、シークレット・不要な生成物の疑いがある場合はユーザーに確認する。
2. スコープや意図の異なる変更は別々に commit する。対象ファイルを明示して stage する。同じファイルに別の変更が混ざっている場合は、書き込める一時ディレクトリに diff を取り、対象 hunk に絞った patch を `git apply --cached` で適用する。作業ツリーは保持する。
3. commit ごとに `git diff --cached` で index 全体を確認する。既存の無関係な stage を保ったまま対象だけを commit できない場合は、ユーザーに確認する。
4. メッセージの subject は英語・命令形の `type(scope): description` にする。理由が subject から自明でなければ body に書く。対象を commit し、残りの論理単位にも同じ手順を適用する。
