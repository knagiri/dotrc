# remote-tracking ref から切ったブランチの upstream が黙って origin/main になった

## 経緯

`bin/claude-worktree` の新規ブランチ base 解決で、`git worktree add -b <branch> <path> origin/HEAD`
のように remote-tracking ref を start point に渡す形を入れた。`branch.autoSetupMerge` の既定
（`true`）により、start point が remote-tracking ref のときは新規ブランチの upstream がそれに
設定される。結果として新規ブランチの upstream は自分の名前の remote ブランチではなく
`origin/main` になり、`@{upstream}` を使う判定や `git status` の ahead/behind が `origin/main`
基準で出た。エラーは出ないので、man を読んでいても組み合わせの実効値を見るまで気づけない。

当時の症状は 2 つあった。素の `git push` が "The upstream branch of your current branch does
not match the name of your current branch" で fatal になったこと、そして `@{upstream}` の成否で
「未 push か」を判定する箇所が、upstream が `origin/main` に付いているせいで未 push を push 済みと
誤判定しうること。下の観測は後日の使い捨て repo での再現で、当時の症状とは別物である。再現では
push 前は `origin/main` 基準で見えるので push 済みに見え、`git push origin <branch>` 後は
`origin/main` との差分が残って未 push に見える。どちらの向きでも判定が狂うが、当時 push 済みと
誤判定した実際の挙動は再現で確かめていない。

## 観測

`branch.autoSetupMerge` 未設定の使い捨て repo で再現した（`origin/HEAD` は `origin/main` を指す）。

```
$ git worktree add -q -b feat ../feat origin/HEAD
$ cd ../feat
$ git rev-parse --abbrev-ref feat@{upstream}
origin/main
$ git commit -q --allow-empty -m one
$ git push -q origin feat
$ git status -sb | head -1
## feat...origin/main [ahead 1]
$ git log --oneline @{upstream}..HEAD
3ca7f03 one
```

`git push origin feat` で push 済みなのに、`@{upstream}..HEAD` は空にならず、`git status -sb` も
`[ahead 1]` のまま残る。push 済みの commit が未 push に見える。

素の `git push`（引数無し）が fatal になったのは当時の観測で、上の使い捨て repo では再現していない
（`push.default=simple` の既定が upstream 名とブランチ名の不一致を止める、という `git-config(1)`
の記述と整合する）。これはエラーで止まるので黙って壊れるクラスではなく、黙って壊れるのは
upstream が `origin/main` に付くこと自体と、それを読む判定のほうである。

## 直し方

`bin/claude-worktree` の新規ブランチ作成を `git worktree add --no-track -b` にし、upstream を
未設定のままにした。既存ブランチ（ローカル、または `origin/<branch>` の追跡 checkout）は従来どおり
追跡させる。`test/claude-worktree.test.sh` に、新規ブランチに upstream が付かないことの assert を
足した（`--no-track` を外すとこの assert が落ちることを確認した）。

rule 側では、
同型の「config 既定に依存して黙って付く副作用」を、黙って壊れるクラスの 1 つとして rule に
名指しした。あわせて、man を読むだけで終えず実効値を出すコマンド（作った直後の
`git rev-parse --abbrev-ref <branch>@{upstream}` 等）で確かめる指針を置いた。

## 反映先

- `bin/claude-worktree`（新規ブランチ作成の `--no-track`）
- `test/claude-worktree.test.sh`（upstream 未設定の assert）
- `dot/claude/rules/evidence-over-guesswork.md`「1. 公式ドキュメントを確認する前に計画・実装を開始しない」
