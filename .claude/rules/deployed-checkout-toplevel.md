---
paths:
  - "bin/**"
  - "test/**"
---

## deploy 済みの checkout と比べるときは `--show-toplevel` を使わない

dotrc の `bin/` スクリプトやテストで、`bin/deploy.sh` を実行した checkout と比べる処理を書くときの
規約。dotrc の checkout でだけ効けばよいので、`dot/claude/rules/` ではなく repo 直下の
`.claude/rules/` に置き、`paths` で `bin/` と `test/` に絞る。

linked worktree では `git rev-parse --show-toplevel` は worktree 自身の root を返し、
`bin/deploy.sh` を実行した checkout（PATH に載る `bin/`、`~/.claude` 配下の symlink の実体）を
指さない。それらと比べる・PATH から外す処理では、main working tree を
`git rev-parse --path-format=absolute --git-common-dir` の親ディレクトリから引く。これは
deploy を main working tree から実行している前提で、linked worktree から deploy した場合は
一致しない。前提が怪しいときは symlink の実体（例: `readlink -f ~/.claude/rules`）から引く。

取り違えてもエラーにはならず、PATH から外したつもりの `bin/` が残る、symlink の実体と一致しない、
という形で黙って壊れる。main working tree で試すと両者が一致するので、そこでのテストでも
気づけない。

実例: dotrc/docs/incidents/show-toplevel-in-linked-worktree.md
