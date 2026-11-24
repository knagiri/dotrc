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
付けて呼んでも親を辿って読まれる（実測）。trust は repo root で
`MISE_OVERRIDE_CONFIG_FILENAMES=mise.db.local.toml mise trust` を一度実行して与える（実測: この
環境変数付きで通り、その後の `db-query` が URL を読めた）。未 trust のままだと mise が
`Config files in .../mise.db.local.toml are not trusted.` で失敗し、`db-query` は mise の message と
trust の手順を添えて exit 4 で止まる。

`db-query` は usql の引数を素通しせず、`-c <sql>` と出力形式の flag だけを受け、`\` を含む SQL を拒否し、
stdin は `/dev/null` にして読まない。usql の meta-command は shell の実行（`\!`）やファイルの読み書き（`\i` / `\o` /
`\w`）ができ、`-c`・`-f`・stdin のどれからでも、SQL の後ろに続けても実行される（実測: `-c 'select 1;
\! echo X'` で `X` が出る）。素通しすると `Bash(db-query *)` の allow が承認なしの任意コマンド実行に
なる。一方 SQL の中身は wrapper では縛らず、DB に対して agent に何を許すかは `DATABASE_URL` の
DB user の権限で決める。

接続先が複数（dev / stg 等）ある場合は扱わない。override するファイル名を接続ごとに分けるか、`db-query` に
接続名の引数を持たせるかは、必要になった時点で決める。
