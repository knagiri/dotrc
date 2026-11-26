# main への直接 commit の検出が `cd` を追わず、linked worktree への commit で承認を求めた

## 経緯

main working tree の統合先 branch への直接 commit は、PreToolUse hook（`bin/claude-hook-git-guard`
の commit 判定）が Bash のコマンド文字列から commit 先の dir を推測し、承認プロンプト（ask）を
出して検出していた。推測は hook 入力の cwd を `git -C` で動かすだけで、`cd` は追わない。

main checkout で動く session が `cd .worktrees/<wt> && git commit ...` を撃ったところ、実際の
commit 先は linked worktree の feature branch なのに「main に直接 commit する」と判定され、
承認プロンプトが出た。逆向きの `cd <main checkout> && git commit`（linked worktree の session から）
は素通りする。こちらは実際には起きておらず、コードを読んで導き、下の使い捨て repo で再現した。

コマンド文字列から実行先を当てる方式では、`cd`・`sh -c`・alias・make 等の経路を追うたびに
推測が増え、追い切れない。commit が実際に走る repo の中で判定すれば推測自体が要らない。

## 観測

使い捨て repo（`r` は main を checkout した main working tree、`r/.worktrees/wt` は feat を
checkout した linked worktree）で、旧 hook（`git show origin/main:bin/claude-hook-git-guard`）に
PreToolUse の入力を与えた。

```
# cwd=r, command="cd .worktrees/wt && git commit -m x"
ask
# cwd=r/.worktrees/wt, command="cd ../.. && git commit -m x"
（出力なし = 素通り）
```

同じ 2 つを `githooks/pre-commit` を入れた clone で `CLAUDECODE=1` を付けて実際に commit した。

```
# cwd=r から cd .worktrees/wt して commit
exit=0
# cwd=r/.worktrees/wt から cd ../.. して commit
pre-commit: commit を止めた: main working tree の統合先 branch 'main' への直接 commit。
exit=1
```

## 直し方

検出を git の pre-commit hook（`githooks/pre-commit`）へ移した。git は hook を commit 先の repo の
中で実行するので、判定条件（main working tree・統合先 branch・origin がある・HEAD がある）は
旧 hook と同じまま、dir の推測だけが無くなる。`CLAUDECODE` が空なら何もしないので、人間の commit
は妨げない。

承認を求める形をやめ、拒否（exit 1）にした。pre-commit には承認プロンプトを出す経路が無く、
main への直接 commit を許す正当な場面も無いため。§5 の例外（「この場でやって」）でも branch を
切ってから commit すれば足りる。

main への混入そのものは repo-baseline の ruleset（PR 必須・直接 push 不可）がサーバー側で塞いで
いる。pre-commit の役割は push で弾かれる前に commit の時点で気づかせることだけなので、
`--no-verify` で回避できることは許容する。導入範囲は baseline を当てた repo の clone とし、
repo-baseline skill の手順で clone ごとに `.git/hooks/pre-commit` へ symlink する。

global な `core.hooksPath` に置く案は採らなかった。global に設定すると各 repo の `.git/hooks` を
黙って無効にし、git-lfs や pre-commit framework の hook、dotrc 自身の `githooks/post-merge` が
効かなくなるため。

## 反映先

- `githooks/pre-commit` と `test/pre-commit-hook.test.sh`
- `dot/claude/skills/repo-baseline/SKILL.md`（baseline の表、手順「6. pre-commit hook」）
- `bin/claude-hook-git-guard`（commit の判定を削除し、stash の判定だけを残した）
