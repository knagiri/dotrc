## Claude Code settings.json 編集ルール

`.claude/settings.json` や `~/.claude/settings.json` の `permissions` を編集するときの注意。
公式仕様: <https://code.claude.com/docs/en/permissions#bash>

### Multi-wildcard pattern の罠（実測ベース）

複数の `*` を含む Bash permission rule は docs と挙動が一致しない部分がある。

| パターン | 期待 | 実際の挙動 |
|---|---|---|
| `Bash(A * B)` | `A x B` にマッチ | OK（マッチはする。ただし B が最初の subcommand なら起動時に警告される。後述） |
| `Bash(A * B *)` | `A x B`（trailing 無し）と `A x B y`（有り）両方 | **trailing 必須**。`A x B` 単体にはマッチしない |
| `Bash(A * B:*)` | docs では `A * B *` と等価のはず | **どの形にもマッチしない**（dead rule） |

`:*` 形が壊れているのは多重 wildcard との組み合わせのみ。単一 wildcard の `Bash(cmd:*)` は仕様通り機能する。

この表は「マッチするか」だけを扱う。`*` の位置による起動時警告の有無は別軸なので、次節を参照。

### Trailing 引数の有無を両方許可するには 2 行に分ける

```json
"Bash(git log * --oneline)",
"Bash(git log * --oneline *)"
```

`*` は**最初の subcommand より後ろ**に置く。それより前（＝オプションが入る位置）に `*` を置くと、
**コマンド種別に関わらず**起動時に警告される（実測: `Bash(aws --profile * s3 ls)` /
`Bash(docker --context * ps)` でも出る。`*` はコマンド名の直後とは限らず、`--profile` のような
オプションの後ろでも subcommand より前なら警告対象）。

逆に最初の subcommand より後ろなら、そこにオプションが挟まる形でも警告されない（実測:
`Bash(uv run --package * ruff format)` は出ない。`run` が subcommand なので `*` はその後ろ）。
上のように後続に literal トークンが続く多重 wildcard も同様。

git は subcommand より前の位置に `-c` / `--exec-path` を挿せるため危険度が特に高く、警告文にも
git 固有の一文が付く（次節末尾を参照）。

### allowlist 不要（auto-allow されるもの）

以下は permission rule を書いても dead code になる。

- 組み込み read-only コマンド: `ls`, `cat`, `head`, `tail`, `grep`, `find`, `wc`, `diff`, `stat`, `du`, `cd`, および `git status`/`log`/`diff`/`show` 等の read-only サブコマンド
- 自動剥がしされる process wrapper: `timeout`, `time`, `nice`, `nohup`, `stdbuf`, （フラグ無し）`xargs`

ただし `git -C <path>` を介すると read-only サブコマンドでも auto-allow が効かなくなる。この穴を
`Bash(git -C * <sub>)` で埋めることはできない。subcommand より前の `*` は `-c` / `--exec-path`
等のグローバルオプションにもマッチする。つまり `Bash(git -C * log)` は
`git -C <path> -c core.pager=<任意コマンド> log` のような呼び出しまで吸い、承認なしの任意コマンド
実行を通しうる（実質「git のグローバルオプション全部を allow」になる）。Claude Code 2.1.246 は
この形の rule を起動時に警告する（警告は最初の subcommand より前の `*` に対してコマンド種別に
関わらず出て、git ではこの理由に触れる一文が加わる）。

したがって既定の対処は allowlist の工夫ではなく cwd を直すこと。[working-directory.md](./working-directory.md)
に従い `/cd <dir>` を頼んで止まる。[worktree-scope.md](./worktree-scope.md) §3 が許す「別 repo の
一度きりの read-only 覗き見」で `git -C <絶対パス>` を使う場合は、承認プロンプトが出るのを
受け入れる（一度きりなので摩擦が小さい）。

由来: 2026-08-26、Claude Code 2.1.246 が起動時に user 設定（`~/.claude/settings.json`）の
`Bash(git -C * <sub>)` 32 行それぞれへ警告を出したのが発端。user 設定由来なので全 project で出る。
同 32 行を削除し、上の方針へ差し替えた。

### ファイル系 permission は Read/Edit の 2 ファミリでしか照合されない

ファイル系 permission rule はツール名単位ではなく「読み系」「書き系」の 2 ファミリで判定される。`Read(path)` は Grep/Glob 等の読み取り系ツールにも best-effort で適用され、`Edit(path)` は Edit/Write/MultiEdit/NotebookEdit 等の書き込み系ツールをまとめてカバーする（公式 docs "Read and Edit" セクション）。

| ツール名で書いた rule | 照合されるか |
|---|---|
| `Read(path)` | される（読み取り系に best-effort で適用） |
| `Edit(path)` | される（書き込み系をまとめてカバー） |
| `Write(path)` / `NotebookEdit(path)` / `Glob(path)` | **されない**。allow/deny/ask いずれで書いても起動時に警告が出る dead rule。この警告は Claude Code v2.1.210 以降でのみ出る（それ以前は無警告で dead rule のまま） |

このため書き込み系の rule は `Edit(path)` に、読み取り系の rule は `Read(path)` に寄せる。`Write(...)` / `Glob(...)` / `NotebookEdit(...)` 等の個別ツール名でパス付き rule を書いても永久にマッチしない。

なおパスを伴わない裸のツール名 deny（例: `Write`）はツール全体にマッチする一括 deny であり、この 2 ファミリ判定の対象外なので警告は出ない。

由来: PR #23 で `settings.json` から `Glob(...)` / `Write(...)` / `MultiEdit(...)` 形の dead rule 23 件を削除した際に判明。

### 3 層の使い分け — 委譲先に効かせたい rule は tracked に置く

permission rule の置き場所は 3 つあり、伝播の経路がそれぞれ違う（$HOME への展開 / repo の git
管理下 / その checkout 限り）。

| 置き場所 | 伝播経路 | 何を置くか |
|---|---|---|
| `~/.claude/settings.json`（dotrc の `dot/claude/settings.json`） | dotrc の git 管理下だが、効くのは `bin/deploy.sh` が張る symlink 経由（[dotrc-deploy.md](./dotrc-deploy.md) 参照）。linked worktree で編集しても、そのまま委譲先には効かない | 複数 repo で使うもの |
| `<repo>/.claude/settings.json` | **repo の git 管理下**。branch を checkout すれば載る | repo 固有で、worktree へ伝播させたいもの |
| `<repo>/.claude/settings.local.json` | 管理外 | その checkout 限りの一時的なもの |

`git worktree add` は branch を checkout するだけなので、git 管理外の `settings.local.json` は
新しい worktree に一切載らない。そして UI の「don't ask again」が書き込む先はこの
`settings.local.json` である。つまり対話中に溜めた許可は、[worktree-scope.md](./worktree-scope.md) §6 の
委譲先にはまったく効かない。

人間が同席していれば承認プロンプトはその場で捌けるが、background 委譲先は人間不在で走るので
そこで固まる。しかも承認は代理できない（cross-session permission laundering）ため、回収に
人手が要る。したがって**委譲先でも要る定型の検証コマンド**（テスト実行、`git fetch origin` 等）の
rule は、tracked な `<repo>/.claude/settings.json` へ昇格させる。その checkout 限りの実験や、
ローカルのパスに依存する許可は local に残してよい（他人の checkout では dead rule になるだけで、
伝播させる価値が無いため）。

由来: background 委譲が permission prompt で構造的に停止した実測 5 回。いずれも
`bash test/*.test.sh` / `go test` / `git fetch origin` という定型の検証コマンドだった。
`implement-and-review` は PR を出す前に必ず `git fetch origin` を撃つ設計なので、穴が塞がるまで
全委譲が必ず止まる状態だった。同種の rule は `.claude/settings.local.json` に個別に溜まって
いたが、git 管理外で伝播しなかったのが根本原因。repo 固有の `bash test/*` は tracked な
`<repo>/.claude/settings.json` を新設して解決し、複数 repo で使う `git fetch origin` / `go test`
は表の基準どおり `~/.claude/settings.json`（dotrc の `dot/claude/settings.json`）側へ足した
（PR #47）。

### Hot-reload

`.claude/settings.local.json` 等の編集は再起動なしに即時反映される（実測確認）。
