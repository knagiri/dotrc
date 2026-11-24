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
