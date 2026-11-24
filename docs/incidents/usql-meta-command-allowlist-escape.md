# usql の引数を素通しする wrapper の allow が任意コマンド実行の grant になりかけた

## 経緯

DB 操作用の wrapper `bin/db-query` を、当初 `usql "$DATABASE_URL" "$@"` と引数を素通しする形で書き、
`Bash(db-query *)` を allowlist に足した。安全の境界は DB user の権限（read-only）に置く設計だった。

push 後の自動セキュリティレビューが、usql の backslash meta-command で shell に抜けられると指摘した。
usql は SQL client であると同時に `\!` で shell コマンドを実行でき、`\o` / `\w` でファイルへ書き、
`\i` でファイルを読む。DB 権限はこれらを何も縛らないので、allow 済みの `db-query -c '\! <cmd>'` は
承認なしの任意コマンド実行になる。wrapper 名から見えるのは「DB にクエリを投げる」だけで、grant の
実際の広さが settings.json の差分からは読めなかった。

## 観測

usql 0.21.6 と sqlite の一時 DB で確かめた。

```
$ usql sq:./t.db -c '\! echo SHELL-ESCAPE-RAN'
SHELL-ESCAPE-RAN
$ usql sq:./t.db -c "select 1; \! echo MID-LINE"
...
(1 row)

MID-LINE
$ printf 'select 2;\n\\! echo FROM-STDIN\n' | usql sq:./t.db
...
FROM-STDIN
$ usql sq:./t.db -c "select 'a\b' as x"
 a\b
$ printf 'select 1;\n\\! echo FROM-F\n' > m.sql; usql sq:./t.db -f m.sql
...
FROM-F
```

`-c` の先頭・SQL の後ろ・`-f` のファイル・stdin のいずれからも meta-command が実行される。文字列リテラル内の `\` は
meta-command にならない。

## 直し方

`bin/db-query` は引数を素通しせず、`-c <sql>` 1 つと出力形式の flag（`-J` / `-C` / `-t` / `-x` /
`-q`）だけを受ける。`\` を含む SQL は文字列リテラル内かを解析せず一律に拒否し、usql の stdin は
`/dev/null` にして読まず、init script を読まない `-X` と password prompt を出さない `-w` を固定で付ける。
`test/db-query.test.sh` に、backslash を含む SQL・`-f` / `-o` 等の未対応引数の拒否・stdin を渡さないことのケースを足した。
backslash の拒否・未対応引数の拒否・stdin を閉じること・空 SQL の拒否には、そのガードを外した変異版で
落ちることを確かめるケースも付けた。

## 反映先

- `bin/db-query`（header コメント）
- `dot/claude/rules/db-access.md`「2. 無ければ `usql` を `db-query` 経由で使う」
- `docs/design/mise-config-layering.md`「他 repo の DB 接続（`mise.db.local.toml`）」
