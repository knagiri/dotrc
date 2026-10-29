# linked worktree の `--show-toplevel` で PATH 上の dotrc `bin/` を外そうとして外れなかった

## 経緯

テストを HOME・台帳・PATH 上の `claude-queue` から隔離する helper（`test/lib/sandbox.sh`）を
実装した委譲先が、PATH から dotrc の `bin/` を外す処理を `git rev-parse --show-toplevel` の
`bin/` で書いた。委譲先は linked worktree で動いており、そこでは `--show-toplevel` が worktree
自身の root を返す。PATH に載っているのは `bin/deploy.sh` を実行した main working tree の
`bin/` なので、外したつもりの `bin/` が PATH に残った。エラーは出ない。

## 観測

この doc の作成時に linked worktree で実行した出力（パスは一般化した）:

```
$ git rev-parse --show-toplevel --path-format=absolute --git-common-dir
<repo>/.worktrees/<name>
<repo>/.git
```

`--show-toplevel` は worktree を、`--git-common-dir` の親は main working tree（`<repo>`）を指す。
main working tree で実行すると両者は一致するので、そこで試す限り取り違えは見えない。

## 直し方

`--path-format=absolute --git-common-dir` の親から main working tree を引き、その `bin/` も PATH
から外した（現在の `test/lib/sandbox.sh` はさらに `claude-queue` を持つディレクトリを一律に外す）。

## 反映先

- `dot/claude/rules/worktree-scope.md` §1「deploy 済みの checkout と比べるときは `--show-toplevel` を使わない」
