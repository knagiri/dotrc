## DB 操作の接続の作法（repo に慣習が無ければ `db-query`）

agent が DB にクエリを投げるときの作法。DB を触る場面は repo を問わず、ファイル起点でもないので
`paths` を付けない。設定の手順と仕組みは `dotrc/docs/design/mise-config-layering.md`
「他 repo の DB 接続（`mise.db.local.toml`）」と `dotrc/bin/db-query` のヘッダにある。

### 1. repo に既存の接続の慣習があればそちらに従う

`.env` を読む script・`docker compose exec`・repo 固有の task 等があれば、一般にそちらを使う。
別経路を足すとどちらが正かが割れるため。

### 2. 無ければ `usql` を `db-query` 経由で使う

```
db-query -c 'select count(*) from users'
db-query -J -c "$(cat query.sql)"
```

受け付けるのは `-c <sql>` 1 つと出力形式の flag（`-J` / `-C` / `-t` / `-x` / `-q`）だけで、`\` を
含む SQL は拒否される（meta-command が任意コマンド実行になるため）。`\` が要るクエリは
人の承認を経て usql を直接使う。接続先は `mise.db.local.toml` の値だけで決まり、`DATABASE_URL=... db-query`
のように env で渡した値は捨てられる。終了コードの全一覧は `dotrc/bin/db-query` のヘッダ。

実例: dotrc/docs/incidents/usql-meta-command-allowlist-escape.md

### 3. `mise.db.local.toml` は人が設定する

接続は repo root の untracked な `mise.db.local.toml` から読まれる。agent は一般に書き換えない。trust が内容に結びついていて、編集すると人が中身を確かめて再 trust するまで exit 4 で
止まる。このゲートは allow 済みの `db-query` 経由の任意コマンド実行を塞ぐ。
`DATABASE_URL` は `mise.local.toml` や shell の rc など常時ロードされる場所に一般に置かない（app・ORM・
migration が黙ってその DB へ向く）。ファイルが無い、または `db-query:` で始まる stderr とともに
exit 2〜5 で止まるとき（4 は未 trust・編集後。usql の終了コードと重なるので stderr で見分ける）は、人に設定を頼む。

### 4. 境界は DB の権限であって `db-query` ではない

`db-query` は SQL の中身を見ないので、書き込み権限のある DB user なら `DELETE` も `DROP` も通る。
allow 済みであることを安全の根拠にせず、設定を頼むときは read-only な DB user を勧める。
