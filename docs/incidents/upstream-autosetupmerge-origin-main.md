# remote-tracking ref から切ったブランチの upstream が黙って origin/main になった

## 経緯

`bin/claude-worktree` の新規ブランチ base 解決で、`git worktree add -b <branch> <path> origin/HEAD`
のように remote-tracking ref を start point に渡す形を入れた。`branch.autoSetupMerge` の既定
（`true`）により、start point が remote-tracking ref のときは新規ブランチの upstream がそれに
設定される。結果として新規ブランチの upstream は自分の名前の remote ブランチではなく
`origin/main` になり、`@{upstream}` を使う判定や `git status` の ahead/behind が `origin/main`
基準で出た。エラーは出ないので、man を読んでいても組み合わせの実効値を見るまで気づけない。

## 観測

`branch.autoSetupMerge` 未設定の使い捨て repo で再現した（`origin/HEAD` は `origin/main` を指す）。

```
$ git worktree add -q -b feat ../feat origin/HEAD
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

素の `git push`（引数無し）は `push.default=simple` の既定なら upstream 名とブランチ名の不一致を
エラーで止めるので、こちらは黙って壊れるクラスに当たらない（再現はしていない。`git-config(1)`
の `push.default` の記述による）。

## 直し方

同型の「config 既定に依存して黙って付く副作用」を、黙って壊れるクラスの 1 つとして rule に
名指しした。あわせて、man を読むだけで終えず実効値を出すコマンド（作った直後の
`git rev-parse --abbrev-ref <branch>@{upstream}` 等）で確かめる指針を置いた。

## 反映先

- `dot/claude/rules/evidence-over-guesswork.md`「1. 公式ドキュメントを確認する前に計画・実装を開始しない」
