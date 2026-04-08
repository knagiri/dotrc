---
name: my-create-pr
description: コンテキストに基づいた説明付きで GitHub Pull Request を作成する
allowed-tools: Bash(git status *), Bash(git diff *), Bash(git log *), Bash(git rev-parse *), Bash(git push *), Bash(git ls-files *), Bash(gh repo view *), Bash(gh pr create *), Bash(echo *), Read, Glob, Grep, AskUserQuestion
---

## Pre-fetched context

!`git rev-parse --abbrev-ref HEAD`
!`git status --short`
!`git ls-files ':(top,icase).github/pull_request_template.md' ':(top,icase).github/pull_request_template/*.md' ':(top,icase)pull_request_template.md'`

## Instructions

Pull Request を作成する。以下のフローに従うこと。

1. **コンテキスト収集**: `git log --oneline main..HEAD`、`git diff --stat main..HEAD`、`git diff main..HEAD` を実行する。

2. **未コミットの変更**: 上の `git status` に出力がある場合、コミットするか・無視するか・中止するかをユーザーに確認する。回答があるまで先に進まない。

3. **PR テンプレート**:
   - タイトル・本文を書く前に template を `Read` で読み込む。
   - テンプレートの見出し・構成順序・HTML コメント (`<!-- -->`) はそのまま維持する。

4. **PR の作成**:
   - タイトル: Conventional Commits 形式で日本語で記述する。
       - `type(scope)` トークンは標準形（`feat`, `fix` 等）のまま維持し、ローカライズするのは description 部分のみ。
   - 本文: テンプレートのセクションを埋める。
   - 会話の中で見つかった参照リンク（Issue、ドキュメント、関連 PR）を積極的に含める。

5. **確認**: PR のタイトルと本文の全文を提示する。リンクの追加や編集の希望がないか確認し、修正があれば反映して再度確認する。承認されるまで push・作成しない。

6. **Push と作成**: 未プッシュのコミットがある場合（`git log @{upstream}..HEAD`）のみ `git push -u origin HEAD` を実行する。`gh pr create` で PR を作成し、PR の URL を返す。
