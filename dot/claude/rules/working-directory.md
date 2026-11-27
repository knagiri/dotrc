## working directory がズレたら `/cd` を頼んで止まる

作業対象の dir が cwd と食い違うとき、`cd <dir> && …` や `git -C <dir>` で渡り歩いて回避
しない。cwd 自体を直すべきサインなので、ユーザーに `/cd <dir>` を頼んで止まる。作業の進め方
そのものなので `paths` を付けず常時ロードする。

### トリガー

- 編集・commit・実行したい先が cwd でない
- 同じ外部 dir へ 2 回以上 `cd` / `git -C` した
- repo 内のサブディレクトリへ `cd` した。エラーも警告も出ずに通り、以降の相対パスが黙って
  別の場所を基準にする（主 working directory は変わらず、移動先の CLAUDE.md もロードされない）

### アクション

止まって `/cd <dir>` を頼み、移動後は相対パスで進める。`/cd` はモデルから呼べないので、
agent にできるのは頼んで待つことだけである。委譲先など人間不在の session でも同じにする。
attach した人間が実行するまで遅れるだけで回収され、cryptic な承認プロンプトで止まるより
何を求めているかが明確なため。

上流では作業対象の dir から session を起動すればズレ自体が減る（`claude-worktree`）。

### 唯一の例外 — 別 repo の一度きりの read-only 覗き見

`cd` せずパスを引数で渡す（`rg <pattern> /abs/path`、[session-scope.md](./session-scope.md) §3）。
同じ dir を 2 回以上覗くなら一度きりではないので `/cd` へ切り替える。

### なぜ回避が詰まるのか

- `cd` が別 dir へ移って `git` を続ける複合コマンドは、移動先の git hooks が走りうるので承認
  プロンプトが出る（<https://code.claude.com/docs/en/permissions>）。コマンドの形への判定なので
  allowlist で抑えにくい
- working directory の外への `cd` は次のコマンドで巻き戻るので、毎回書き足して上の承認を
  繰り返し踏む

repo 内の `cd` はどちらも起きないが、摩擦という気づきの合図も無く静かに間違える（トリガー 3 つ目）。
