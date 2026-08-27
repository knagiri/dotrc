## Claude Code settings.json 編集ルール

`.claude/settings.json` や `~/.claude/settings.json` の `permissions` を編集するときの注意。
公式仕様: <https://code.claude.com/docs/en/permissions#bash>

### Multi-wildcard pattern の罠（実測ベース）

複数の `*` を含む Bash permission rule は docs と挙動が一致しない部分がある。

| パターン | 期待 | 実際の挙動 |
|---|---|---|
| `Bash(A * B)` | `A x B` にマッチ | OK |
| `Bash(A * B *)` | `A x B`（trailing 無し）と `A x B y`（有り）両方 | **trailing 必須**。`A x B` 単体にはマッチしない |
| `Bash(A * B:*)` | docs では `A * B *` と等価のはず | **どの形にもマッチしない**（dead rule） |

`:*` 形が壊れているのは多重 wildcard との組み合わせのみ。単一 wildcard の `Bash(cmd:*)` は仕様通り機能する。

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

### Hot-reload

`.claude/settings.local.json` 等の編集は再起動なしに即時反映される（実測確認）。
