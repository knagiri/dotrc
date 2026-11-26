# mise config の層分け

dotrc は tracked な mise config を持たない。`bin/deploy.sh` が雛形を作る mise config は checkout
直下の untracked な `mise.gh.local.toml` だけで、無ければ作る（gitignore 済み）。

| ファイル | 中身 | 読まれる条件 |
|---|---|---|
| `mise.gh.local.toml` | `~/.config/gh/personal.env`（`GH_TOKEN`）を `_.file` で読む | `MISE_ENV=gh` のときだけ |

## 分ける軸

### 1. tracked に置けるか

秘密の値（GitHub PAT）は、この repo が public なので tracked には置けない。

### 2. env var をどこまで広く効かせるか

`GH_TOKEN` は `gh` の呼び出しにしか要らない。常時ロードすると checkout 内の全プロセス
（background 委譲先を含む）の env に載ってしまうので、`gh-*` wrapper が `MISE_ENV=gh` で
呼ぶときだけ読む（`bin/lib/gh-mise.sh`、経緯は `dot/claude/rules/worktree-scope.md` §6）。

結果として `mise.gh.local.toml` は「tracked から外す」と「読み込みを絞る」の二重ゲートになる。

## trust

`bin/deploy.sh` は雛形生成と同時に checkout を `trusted_config_paths` に path prefix で
登録するので、`mise.gh.local.toml` にも、worktree が自分で持つ config（tracked な `mise.toml`
等）にも trust が効く。`mise trust` は subdirectory の config を覆わないので、prefix での登録が
要る。worktree から親の config がどう解決されるかは `dot/claude/rules/worktree-scope.md` §6 を
参照。

新しいマシンでは `bin/deploy.sh` を実行し、雛形として作られた `~/.config/gh/personal.env`
（権限 600）の `GH_TOKEN` に個人 PAT を入れる。

## node の package manager（corepack の yarn / pnpm）

`packageManager` で yarn 等を固定した repo は、git hook や script から `yarn` を直接呼ぶ。
`mise activate` が発火しない非対話 shell（background 委譲先を含む）でも、mise の node の `bin/` は
daemon や `mise exec` 経由で PATH に載るので、corepack の shim がその `bin/` にあれば `yarn` は
解決する。そこで `bin/deploy.sh` は mise の global setting `node.corepack` を `true` にし、以後の
node の install で mise が `corepack enable` を走らせるようにする。この setting は install 時に
しか効かないので、既に入っている version のうち `bin/yarn` が無いものには deploy が
`corepack enable` を撃つ。shim を session ごとの一時ディレクトリに作って PATH に足す形は、PATH を
整える手当てが session ごとに要るので採らない。

## 他 repo の DB 接続（`mise.db.local.toml`）

`bin/db-query` は同じ二重ゲートを各 repo の DB 接続に当てる。値（usql の version、
`DATABASE_URL`）はその repo の root に置く untracked な `mise.db.local.toml` に書き、`db-query` が
`MISE_OVERRIDE_CONFIG_FILENAMES=mise.db.local.toml` で呼ぶ mise の中でだけ読む。運用の規約は `dot/claude/rules/db-access.md`。

`DATABASE_URL` を絞る理由は `GH_TOKEN` より強い。`GH_TOKEN` が常時載っても読むのは gh だけだが、
`DATABASE_URL` は app framework・ORM・migration ツールが既定で読むので、常時ロードすると
その repo の app・test・migration がエラー無しにその DB へ向く。同じ理由で `db-query` は
呼び出し側の env にある `DATABASE_URL` を捨て、mise config の値だけを使う。

業務 repo には dotrc の `.gitignore` が効かないので、`mise.local.toml` / `mise.*.local.toml` は
global な git ignore（`dot/git/ignore`）で無視する（先頭に `.` の付く形も mise は読むので含める）。

`MISE_ENV=db` ではなく override を使うのは、`MISE_ENV` が `mise.db.local.toml` を通常の config 連鎖
へ足すだけで、連鎖の近い側が勝つため。worktree が自分の `mise.toml` に `DATABASE_URL` を持つと
main の `mise.db.local.toml` を黙って上書きし、`mise.db.local.toml` が無いときも別の config の値が
使われて exit 2 にならない（実測、mise 2026.4.28）。override 下では `mise.db.local.toml` が
`mise.toml` 系の連鎖の代わりに読まれ、`MISE_ENV` が無くても読まれ、worktree の `mise.toml` や
root の `mise.toml` の値は使われない。mise の global config の `DATABASE_URL` は override 下でも
読まれるので、global には置かない。

main checkout の root に置いた `mise.db.local.toml` は、`<repo>/.worktrees/<name>` から override を
付けて呼んでも親を辿って読まれる（実測）。

mise は `mise.db.local.toml` の中身（`[env]` の `{{ exec(command=...) }}`、`_.source`、usql を差し替える
`_.path`）を評価する。既定の trust は path 単位で内容の変更では外れないので、一度 trust された後に
agent がこのファイルを書き換えると、allow 済みの `db-query` が承認なしに任意コマンドを実行する
（実測）。そこで `db-query` は `MISE_PARANOID=1` を付けて mise を呼ぶ。paranoid 下の trust は内容の
hash に結びつき、trust 後の書き換えは `Config files in .../mise.db.local.toml are not trusted.` で
失敗する（実測）。`mise trust` は allowlist に無いので再 trust は人の承認になる。trust は repo root で
`MISE_TRUSTED_CONFIG_PATHS= MISE_PARANOID=1 MISE_OVERRIDE_CONFIG_FILENAMES=mise.db.local.toml mise trust`
を実行して与える。`MISE_PARANOID=1` が無いと path 単位の trust になり、paranoid の呼び出しでは通らない
（実測）。`MISE_TRUSTED_CONFIG_PATHS` を空にするのは、信頼済み path の prefix が paranoid 下でも効いて
hash を迂回するため（実測: env でも `trusted_config_paths` setting でも）。prefix が覆っていると
`mise trust` は hash を書かず "No untrusted config files found" で終わる。`db-query` も同じ変数を空にして
呼ぶ。`[tools] usql` の install・解決は trust 後の paranoid 下でも従来どおり動く（実測、mise 2026.4.28）。
未 trust・編集後のままだと `db-query` は mise の message と trust の手順を添えて exit 4 で止まる。

`db-query` は usql の引数を素通しせず、`-c <sql>` と出力形式の flag だけを受け、`\` を含む SQL を拒否し、
stdin は `/dev/null` にして読まない。usql の meta-command は shell の実行（`\!`）やファイルの読み書き（`\i` / `\o` /
`\w`）ができ、`-c`・`-f`・stdin のどれからでも、SQL の後ろに続けても実行される（実測: `-c 'select 1;
\! echo X'` で `X` が出る）。素通しすると `Bash(db-query *)` の allow が承認なしの任意コマンド実行に
なる。一方 SQL の中身は wrapper では縛らず、DB に対して agent に何を許すかは `DATABASE_URL` の
DB user の権限で決める。これは network 越しの server 型 DB でだけ成り立つ。sqlite・duckdb 等の埋め込み型は
usql のプロセス内でローカル user の権限のまま動き、SQL だけで任意のファイルを読み書きできる（`ATTACH`、
`COPY ... TO`）ので、DB user という境界が無い。`db-query` は scheme を server 型の許可リストと照合し、
外れれば exit 5 で止める。拒否リストにしないのは、usql の scheme alias が多く、漏れが素通りになるため。

接続先が複数（dev / stg 等）ある場合は扱わない。override するファイル名を接続ごとに分けるか、`db-query` に
接続名の引数を持たせるかは、必要になった時点で決める。
