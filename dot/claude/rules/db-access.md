## DB 操作の接続の作法（repo に慣習が無ければ `db-query`）

agent が DB にクエリを投げるときの接続の作法。DB を触る場面は repo を問わず起こり、特定ファイルの
編集を伴わないので `paths` を付けず常時ロードする。層分けの判断は
`dotrc/docs/design/mise-config-layering.md` を参照。

### 1. repo に既存の接続の慣習があればそちらに従う

repo が DB 接続の手段を既に持っている（`.env` と、それを読む script / `docker compose exec` で
DB コンテナに入る / repo 固有の task 等）なら、一般にそちらを使い、以下の作法を持ち込まない。
接続先・権限・データの扱いはその repo の運用で決まっていて、別経路を足すとどちらが正かが
割れるため。

### 2. 無ければ `usql` を `db-query` 経由で使う

```
db-query -c 'select count(*) from users'
db-query -J -c "$(cat query.sql)"
```

`db-query`（`bin/`）は `mise.db.local.toml` だけを読む mise 経由で `usql ... "$DATABASE_URL"` を実行する。
`DATABASE_URL` が無ければ exit 2、usql が無ければ exit 3、mise が config を読めなければ（未 trust 等）
exit 4、`DATABASE_URL` が server 型 DB の URL でなければ exit 5、mise 自体が無ければ exit 127 で、それ以外は usql の終了コードをそのまま返す。呼び出し側の env にある `DATABASE_URL` は捨て、mise config の値だけを
使う。settings.json で allow 済み。

受け付けるのは `-c <sql>` 1 つと出力形式の flag（`-J` / `-C` / `-t` / `-x` / `-q`）だけで、`\` を
含む SQL は拒否する。usql は `\!`（shell コマンドの実行）・`\o` / `\w`（ファイルへの書き込み）の
ような meta-command を `-c` の中・SQL の後ろ・`-f` のファイル・stdin のどこからでも実行するので、
引数を素通しすると allow 済みの `db-query` が承認なしに任意のコマンドを実行する経路になるため。
SQL の文字列リテラルに `\` が要るクエリは `db-query` では投げられないので、人の承認を経て usql を
直接使う。

実例: dotrc/docs/incidents/usql-meta-command-allowlist-escape.md

### 3. 値は repo の `mise.db.local.toml` に置く

usql の version と接続 URL は、各 repo の root に置く untracked な `mise.db.local.toml` に書く。
`db-query` は `MISE_OVERRIDE_CONFIG_FILENAMES=mise.db.local.toml` を付けて mise を呼ぶので、
このファイルが読まれ、`mise.toml` / `mise.local.toml` の `DATABASE_URL` は使われない。

```toml
[tools]
usql = "0.21.6"

[env]
DATABASE_URL = "postgres://readonly@localhost:5432/example"
```

置いたら repo root で一度 `MISE_OVERRIDE_CONFIG_FILENAMES=mise.db.local.toml mise trust` を実行する
（環境変数なしの `mise trust` は `mise.db.local.toml` を対象にしない）。main checkout の root に置けば
`<repo>/.worktrees/<name>` からも親を辿って読まれ、worktree が自分の `mise.toml` に `DATABASE_URL` を
持っていても `mise.db.local.toml` が優先されるので、委譲先の worktree へ seed は要らない。mise の global
config の `DATABASE_URL` だけは override 下でも読まれるので、そこには置かない。
`mise.local.toml` / `mise.*.local.toml`（先頭に `.` の付く形も）は global な git ignore に入っている。

`DATABASE_URL` を `mise.local.toml` や shell の rc のような常時ロードされる場所に一般に置かない。
Rails・Prisma・各種 migration ツールなどは `DATABASE_URL` を既定で読むので、env に載った時点で
その repo の app・test・migration がエラー無しにその DB へ向く。`mise activate` 経由で載った値は
background 委譲先にも配られる（[worktree-scope.md](./worktree-scope.md) §6）。`db-query` の override で
絞れば、値が env に載るのは `db-query` の 1 回の呼び出しの中だけになる。

### 4. agent に渡す接続は read-only な DB user に限る

`mise.db.local.toml` に書く接続は、一般に read-only 権限の DB user にする。DB に対して何が
できるかの境界は `db-query` ではなく DB の権限である。`db-query` が縛るのは usql の meta-command
だけで、SQL の中身は見ないので、書き込み権限のある user を渡せば `DELETE` も `DROP` も通る。
allowlist で wrapper を許可していることは、クエリの中身を何も制限しない。

この境界が成り立つのは network 越しの server 型 DB（postgres / mysql / sqlserver / oracle / clickhouse
等）だけである。sqlite・duckdb のような埋め込み型は usql のプロセス内でローカル user の権限のまま
動くので、SQL だけで任意のパスへのファイル作成・書き込み（`ATTACH`、`COPY ... TO`）や読み出しができ、
境界になる DB user が無い（usql 0.21.6 で実測）。承認なしのファイル書き込みは任意コマンドの実行へ
つながりうる。そのため `db-query` は URL の scheme を server 型の許可リストと照合し、外れれば exit 5 で
止める。拒否リストでなく許可リストなのは、usql の scheme alias が多く、漏れた別名が黙って素通りするため。

password は URL に直書きせず、usql の password file（権限 600）に置くことを勧める。`db-query` は
URL を usql の引数として渡すので、URL に書いた password はプロセス一覧に出るため。`db-query` は
`-w` で prompt を止めるが password file は読まれる（実測: `USQLPASS` で指した file の password が
`-w` 付きでも送られた。HOME 配下の既定位置に置いた file は同じ環境で読まれなかったので、置き場所は
環境ごとに確かめる）。
