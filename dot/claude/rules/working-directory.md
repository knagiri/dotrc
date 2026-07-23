## working directory がズレたら `/cd` を頼んで止まる

作業対象のディレクトリが session の cwd と食い違っているとき、`cd <dir> && …` や
`git -C <dir>` でディレクトリを渡り歩いて回避しない。cwd そのものを直すべきサインなので、
ユーザーに `/cd <dir>` を一度実行してもらい、それまで止まる。

これは領域固有でなく「作業の進め方」そのものなので `paths` を付けず常時ロードする
（[evidence-over-guesswork.md](./evidence-over-guesswork.md) と同じ扱い）。

関連ルール: 承認が要るコマンドの回避一般は [bash-command-constraints.md](./bash-command-constraints.md)、
別 worktree・別 repo を read-only で覗く許可は [worktree-scope.md](./worktree-scope.md) §3 を参照。

### 大前提

`cd <dir> && …` でディレクトリを渡り歩かない。編集・commit・実行したい先が cwd でないなら、
その場しのぎで別ディレクトリへ潜るのではなく、cwd 自体を移す。

### トリガー — cwd が不適切なサイン

以下が出たら「cwd がそもそも作業対象からズレている」と判断する。

- 編集・commit・コマンド実行したい先が cwd でない（例: cwd が repo root のネスト下位にいて、
  root で作業したい）。
- 同じ外部ディレクトリへ 2 回以上 `cd` または `git -C` した。1 回きりの回避で済まず反復して
  いるなら、回避ではなく cwd を直す局面。

### アクション — `/cd` を頼んで止まる

トリガーが出たら、そこで止まってユーザーに `/cd <dir>` を一度実行するよう明示的に頼む。
移動後は相対パスで進める。

`/cd` はユーザー専用で、モデルからは呼べない（公式 docs:
"Cd is not a model-invocable tool: Claude can't call it"）。だから agent にできるのは
「頼んで待つ」だけで、代わりに `cd`/`git -C` で押し切らない。`/cd` は `/add-dir` の
参照追加と違い session の主 working directory を置き換え、移動先の CLAUDE.md がロードされ、
`--resume` もそこから引ける（Claude Code v2.1.169+）。

#### session 種別で分岐しない

fire-and-forget / 委譲先の session でも同じにする。人間が attach していなくても、
`cd`/`git -C` で押し切らず `/cd` を頼んで止まる。attach した人間が `/cd` を実行するまで
遅れるだけで、作業は必ず回収される。

cryptic な permission prompt（後述の no-op-cd ガード等）で止まるより、「`/cd <dir>` を
実行してください」と何を求めているか明示して止まるほうが、attach した人間がすぐ対応でき
回収が速いという利点もある。

### 唯一の例外 — 別 repo の一度きりの read-only 覗き見

cwd 移動が不要なのは、別 repo を一度だけ read-only で覗くときだけ。cwd を変えず、`cd` も
せず、パスを引数で渡す。

```
rg <pattern> /abs/path/to/other-repo      # cd しない。パスを引数で渡す
git -C /abs/path/to/other-repo log         # 一度きりの read-only 参照
```

この read-only 覗き見は [worktree-scope.md](./worktree-scope.md) §3 が既に許可している。
ただし §トリガーのとおり、同じ外部ディレクトリを 2 回以上覗くなら「一度きり」ではないので、
`/cd` へ切り替える。

### 補完 — 上流で正しい dir から起動する

そもそも作業対象の dir から session を起動すれば、この状況自体が減る（`claude-worktree` は
worktree dir で claude を起動するので原則ズレない。[worktree-scope.md](./worktree-scope.md) §6）。
例外ではなく、発生頻度を下げる補完として。

### なぜ `cd`/`git -C` 回避が詰まるのか

`cd <dir> && …` を避ける理由は、それが承認プロンプトか cwd リセットのどちらかで詰まるため。

- **git hooks 由来の承認プロンプト**: Claude Code は「`cd` が `git` の前でディレクトリを
  変える複合コマンド」を承認対象にする。移動先の untrusted な git hooks が走りうるためで、
  公式 docs も "Combining `cd` with `git` in one compound command prompts when the `cd`
  changes into a different directory, since running `git` in a new directory can execute
  that directory's hooks" と明記する。この no-op-cd ガード（同じ dir への no-op cd は
  prompt が出ないが、別 dir へ移る cd は出る）は、コマンドの形に対する判定なので
  allowlist エントリで抑えにくい。
- **cwd の巻き戻し**: working directory の外へ `cd` しても、その cwd は次のコマンドへ
  持ち越されず working directory にリセットされる（実測: 外部 dir へ `cd` した次の
  コマンドで "Shell cwd was reset to …" と戻される）。だから `cd <dir>` を毎回書き足す
  羽目になり、上の承認プロンプトを繰り返し踏む。

`/cd` はこの両方を根本から消す。session の cwd 自体が移動先になるので、以降は相対パスで
書け、`cd`/`git -C` の複合も要らなくなる。

---

由来: worktree/monorepo 作業中、agent が cwd と別ディレクトリを触るのに
`cd <絶対パス> && …` や `git -C <dir>` を多用し承認プロンプトを頻発させていた指摘から。
claude-queue の実データ（約 78 件）を分類すると、他 worktree への書き込みは 0 件で安全性の
問題ではなく、実害は「repo root への cd」「別 repo の read-only 調査」での承認プロンプトの
摩擦だった。根本原因は cwd が作業対象からズレていること。`cd`/`git -C` はその場しのぎの
回避で毎回守るのは期待薄なので、cwd 自体を `/cd` で直す規範へ寄せた。
