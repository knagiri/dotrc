## DB 操作の接続の作法（repo に慣習が無ければ `db-query`）

agent が DB にクエリを投げるときの作法。DB を触る場面は repo を問わず、ファイル起点でもないので
`paths` を付けない。設定の手順と仕組みは `dotrc/docs/design/mise-config-layering.md`
「他 repo の DB 接続」と `bin/db-query` のヘッダにある。

### 1. repo に既存の接続の慣習があればそちらに従う

`.env` を読む script・`docker compose exec`・repo 固有の task 等があれば、一般にそちらを使う。
別経路を足すとどちらが正かが割れるため。

### 2. 無ければ `usql` を `db-query` 経由で使う

```
db-query -c 'select count(*) from users'
db-query -J -c "$(cat query.sql)"
```

受け付けるのは `-c <sql>` 1 つと出力形式の flag（`-J` / `-C` / `-t` / `-x` / `-q`）だけで、`\` を
含む SQL は拒否される（usql の meta-command が任意コマンドの実行になるため）。`\` が要るクエリは
人の承認を経て usql を直接使う。exit 2 は `DATABASE_URL` が無い、4 は `mise.db.local.toml` が未 trust
か編集後、5 は server 型 DB の URL でない。

実例: dotrc/docs/incidents/usql-meta-command-allowlist-escape.md

### 3. `mise.db.local.toml` は人が設定する

接続は repo root の untracked な `mise.db.local.toml` から読まれる。agent はこのファイルを一般に
書き換えない。trust が内容に結びついていて、編集すると人が中身を確かめて再 trust するまで exit 4 で
止まる。このゲートは、allow 済みの `db-query` 経由で任意コマンドを走らせる経路を塞ぐためにある。
ファイルが無い・exit 2 / 4 で止まるときは、人に設定を頼む。

### 4. 境界は DB の権限であって `db-query` ではない

`db-query` は SQL の中身を見ないので、書き込み権限のある DB user なら `DELETE` も `DROP` も通る。
allow 済みであることを安全の根拠にせず、設定を頼むときは read-only な DB user を勧める。
