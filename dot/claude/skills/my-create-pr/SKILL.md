---
name: my-create-pr
description: コンテキストに基づいた説明付きで GitHub Pull Request を作成する
allowed-tools: Bash(git status *), Bash(git diff *), Bash(git log *), Bash(git rev-parse *), Bash(git fetch *), Bash(git push *), Bash(git ls-files *), Bash(gh repo view *), Bash(gh pr create *), Bash(echo *), Read, Glob, Grep, AskUserQuestion
---

## Pre-fetched context

!`git rev-parse --abbrev-ref HEAD`
!`git status --short`
!`git ls-files ':(top,icase).github/pull_request_template.md' ':(top,icase).github/pull_request_template/*.md' ':(top,icase)pull_request_template.md'`

## Instructions

Pull Request を作成する。以下のフローに従うこと。本文確認のためのユーザー介入は行わない（step 2 の未コミット変更チェックは別ゲートとして維持する）。

1. **コンテキスト収集**: base ブランチを決め、その **remote ref** を基準に diff / commit log を集める。

   - **base の決定**: ユーザーが base を明示していればそれを優先する。無ければ `gh repo view --json defaultBranchRef --jq ".defaultBranchRef.name"` で既定ブランチを取得する。既定ブランチ名は repo ごとに異なる（`main` とは限らず `develop` 等もある）ため、ブランチ名を決め打ちにしない。
   - **remote ref の更新**: `git fetch origin <base>` を実行する。
   - **収集**: 以下を実行する。
     - `git log --oneline origin/<base>..HEAD`
     - `git diff --stat origin/<base>...HEAD`
     - `git diff origin/<base>...HEAD`

   ローカル追跡ブランチ（`main` / `develop` 等）を diff の基準に使わないのは、`git fetch` しても
   ローカル側は merge されず古いままになりうるためで、古い基準で取った diff には base 側で進んだ
   無関係な変更が混ざり、PR 説明が別作業の内容で汚染される。diff に 3 点表記（`...` = merge-base
   からの差分）を使うのは、GitHub の Files changed と一致させ、base 側の後続コミットを PR の変更として
   取り込まないため。

2. **未コミットの変更**: 上の `git status` に出力がある場合、コミットするか・無視するか・中止するかをユーザーに確認する。回答があるまで先に進まない。
   - **コミットした場合の再収集**: ここでコミットすると HEAD が進み、手順 1 で集めた `git log` / `git diff` の結果が古いままになる。その状態で手順 4 の本文ドラフトへ進むと、実際にはコミット済みの変更が本文に反映されない。手順 3 へ進む前に、手順 1 の収集（`git log --oneline origin/<base>..HEAD` / `git diff --stat origin/<base>...HEAD` / `git diff origin/<base>...HEAD`）だけを再実行する（base の決定・`git fetch` はやり直し不要）。

3. **PR テンプレート**:
   - 上の `git ls-files` 出力にテンプレートがあれば `Read` で読み込み、見出し・構成順序・HTML コメント (`<!-- -->`) はそのまま維持する。
   - テンプレートが無い場合は本文を `## Summary`（diff から）→ `## Why`（あれば）→ `## Refs`（参照リンクがあれば）の順でフォールバック構成にする。セクション見出しは英語のまま。

4. **本文ドラフト**: 以下の構成ルールに従って本文を作成する。
   - **一次ソースは diff/commit/変更ファイル**。本文の骨格は手順 1 で収集した `git diff origin/<base>...HEAD` と `git log --oneline origin/<base>..HEAD` から組み立てる。
   - **会話からの情報は why に限定する**。why = diff/commit log を読んだだけでは推測できない動機・設計判断・制約・背景（例: なぜ今やったか、代替案を退けた理由、関連 incident、依存する締切）。
   - **会話中の造語・略語は本文に持ち込まない**。diff/commit/code に同じ語が存在しない限り使わない。書く必要があれば一行で定義を補う。
   - **参照リンク（Issue / docs / 関連 PR）は持ち込み OK**。会話で言及されたものを積極的に含める。
   - タイトル: Conventional Commits 形式で日本語で記述する。`type(scope)` トークンは標準形（`feat`, `fix` 等）のまま維持し、ローカライズするのは description 部分のみ。

5. **Self-check**: ドラフトを読み返し、以下 3 観点で点検する。問題があれば自分で直す。block しない、ユーザーには確認しない。再度 self-check を回す必要はない。
   - **裏付けスキャン**: 本文の技術用語・固有名詞・主張を一つずつ取り上げ、`git diff` / commit message / 変更ファイル / 参照リンク先のドキュメントのいずれかに同じ語または同等の概念が存在するか確認する。存在しないものは削除するか一行で定義を補う。
   - **会話依存スキャン**: 「あの」「例の」「先ほど」「セッション中で議論した」のような会話前提を示す表現が残っていないか確認。残っていれば独立して読める形に書き直す。
   - **why の有無**: diff からは読み取れないが書ける why があれば補う。無理に書かない。

6. **表示 → Push → 作成**:
   - 完成した本文を画面に表示する（情報提供。block しない）。
   - 未プッシュのコミットがある場合（`git log @{upstream}..HEAD`）のみ `git push -u origin HEAD` を実行する。
   - `gh pr create --title ... --body ...` で PR を作成し、URL を返す。手順 1 でユーザー指定の base を採用した場合は必ず `--base <手順 1 の base>` を付ける（省略すると GitHub 側の既定ブランチ宛になり、手順 1 で集めた diff と PR の base がズレるため）。手順 1 で base 未指定のまま既定ブランチを採った場合は、既定ブランチと一致するので `--base` を省略してよい。
   - push 失敗・PR 作成失敗時は素直に止めてエラーを表示する。skill 側でリトライしない。
