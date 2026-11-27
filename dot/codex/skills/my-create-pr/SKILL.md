---
name: my-create-pr
description: 指定された branch のコミットから本文を作成し、gh-pr-create で GitHub の Pull Request を開く。
---

1. 現在の branch と `git status --short` を確認する。未コミットの変更があれば、その変更を含めるか、今回の PR から外すか、中止するかをユーザーに確認する。
2. base はユーザーが指定した値を優先し、未指定なら `gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'` で取得する。`git fetch origin <base>` の後で `git log --oneline origin/<base>..HEAD` と `git diff origin/<base>...HEAD` を読む。
3. tracked の PR テンプレートがあれば、見出し、順序、HTML コメントを維持する。テンプレートがなければ `## Summary`、必要に応じて `## Why` と `## Refs` を使う。変更の説明は diff と commit から書き、会話からは背景や関連リンクを補う。タイトルは Conventional Commits 形式とし、description は日本語にする。
4. 本文を読み返し、差分や参照先で主張を確かめる。tracked の textlint 設定がある repo では `node_modules/.bin/textlint --stdin --stdin-filename pr-body.md --ignore-path /dev/null` に本文を渡して検査する。利用できなければ、最終応答でその旨を伝える。
5. 本文をユーザーに提示する。upstream がなければ `git push -u origin HEAD` で公開し、公開済みの branch なら未 push の commit がある場合に push する。`gh-pr-create --title <title> --body-file <file> --base <base>` で作成し、URL を返す。ここで作業を終える。
