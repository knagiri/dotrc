# claude-queue は `--dry-run` でも DB を開いた時点で書き込む

## 経緯

claude-queue の休眠（`claude-queue watch`）を実装した委譲先が、実データでの確認中に、
`watch --dry-run` でも DB を開くと `queue` view が作り直され、実 DB に書き込みが入ると気づいた
（委譲先の内省から）。`--dry-run` を「何も書かない」と読んで実 DB を直接指すと、確認のつもりの
実行が台帳を書き換える。その委譲先は読み取り専用で取ったコピーを `CLAUDE_QUEUE_DB` で指して
dry run した。

## 観測

`internal/db/open.go` の `Open` は PRAGMA の適用 → `Tables` → `migrate` → `migrateLifecycle` →
`View`（`DROP VIEW IF EXISTS queue; CREATE VIEW queue ...`）の順に毎回実行する。
`migrateLifecycle` は `PRAGMA user_version` で gate されており、適用済みなら書かない。

この doc の作成時に、実 DB のコピーで dry run 前後の mtime を見た:

```
$ sqlite3 ~/.claude/session-queue.db ".backup $T/q.db"
$ ls -l --time-style=+%T.%N $T/q.db
... 17:50:00.464085044 .../q.db
$ CLAUDE_QUEUE_DB=$T/q.db claude-queue watch --dry-run >/dev/null 2>&1; echo exit=$?
exit=0
$ ls -l --time-style=+%T.%N $T/q.db
... 17:50:01.514080031 .../q.db
```

dry run だけで DB ファイルの mtime が進んだ。実 DB を直接指して同じことは試していない
（書き込みが入ることを確かめる実験そのものが実 DB を書き換えるため）。

## 直し方

`sqlite3 -readonly <実 DB> ".backup <コピー先>"` で取ったコピーを `CLAUDE_QUEUE_DB` で指して
実行する。WAL モードの DB を一貫して写すため `cp` ではなく `.backup` を使う。

## 反映先

- `dot/claude/rules/dotrc-deploy.md` §7「claude-queue を実データで確かめるときは DB のコピーを指す」
