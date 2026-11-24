## DB 操作は `db-query` 経由で行う

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
db-query -f query.sql
```

`db-query`（`bin/`）は `MISE_ENV=db mise exec -- usql "$DATABASE_URL" "$@"` 相当で、usql の引数は
素通しする。`DATABASE_URL` が無ければエラーで exit 2 する。呼び出し側の env にある
`DATABASE_URL` は捨て、mise config の値だけを使う。settings.json で allow 済み。

### 3. 値は repo の `mise.db.local.toml` に置く

usql の version と接続 URL は、各 repo の root に置く untracked な `mise.db.local.toml` に書く。
mise はこのファイルを `MISE_ENV=db` のときだけ読む。

```toml
[tools]
usql = "0.21.6"

[env]
DATABASE_URL = "postgres://readonly@localhost:5432/example"
```

置いたら repo root で一度 `MISE_ENV=db mise trust` を実行する（素の `mise trust` は
`mise.db.local.toml` を対象にしない）。main checkout の root に置けば
`<repo>/.worktrees/<name>` からも親を辿って読まれるので、委譲先の worktree へ seed は要らない。
`mise.local.toml` / `mise.*.local.toml` は global な git ignore に入っている。

`DATABASE_URL` を `mise.local.toml` や shell の rc のような常時ロードされる場所に一般に置かない。
Rails・Prisma・各種 migration ツールなどは `DATABASE_URL` を既定で読むので、env に載った時点で
その repo の app・test・migration がエラー無しにその DB へ向く。`mise activate` 経由で載った値は
background 委譲先にも配られる（[worktree-scope.md](./worktree-scope.md) §6）。`MISE_ENV=db` で
絞れば、値が env に載るのは `db-query` の 1 回の呼び出しの中だけになる。

### 4. agent に渡す接続は read-only な DB user に限る

`mise.db.local.toml` に書く接続は、一般に read-only 権限の DB user にする。安全の境界は
`db-query` ではなく DB の権限である。`db-query` は usql の引数を素通しするので、書き込み権限の
ある user を渡せば `DELETE` も `DROP` も通る。allowlist で wrapper を許可していることは、
クエリの中身を何も制限しない。

password は URL に直書きせず、`~/.usqlpass`（権限 600）等に置くこともできる。`db-query` は
URL を usql の引数として渡すので、URL に書いた password はプロセス一覧に出るため。
