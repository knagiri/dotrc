# mise config の層分け

dotrc は tracked な mise config を持たない。mise が読むのは checkout 直下の untracked な
local ファイルだけで、どちらも `bin/deploy.sh` が無ければ雛形を作る（gitignore 済み）。

| ファイル | 中身 | 読まれる条件 |
|---|---|---|
| `mise.local.toml` | `CLAUDE_CONFIG_DIR = "{{env.HOME}}/.claude-personal"` | 常時（mise の既定） |
| `mise.gh.local.toml` | `~/.config/gh/personal.env`（`GH_TOKEN`）を `_.file` で読む | `MISE_ENV=gh` のときだけ |

## 分ける軸

### 1. tracked に置けるか

- **秘密の値**（GitHub PAT）は、この repo が public なので tracked には置けない
- **秘密でない値**（`CLAUDE_CONFIG_DIR` のパス）も、マシンによって要否が違うので tracked から
  外す。account を分けたいのは複数の Claude Code account を使い分けるマシンだけである。
  tracked に置くと不要なマシンでも fresh checkout のたびに `mise trust` を求められる。mise の
  trust は config ファイルの存在に対してかかるので、中身を条件分岐させてもプロンプトは消えない

### 2. env var をどこまで広く効かせるか

- `GH_TOKEN` は `gh` の呼び出しにしか要らない。常時ロードすると checkout 内の全プロセス
  （background 委譲先を含む）の env に載ってしまうので、`gh-*` wrapper が `MISE_ENV=gh` で
  呼ぶときだけ読む（`bin/lib/gh-mise.sh`、経緯は `dot/claude/rules/worktree-scope.md` §6）
- `CLAUDE_CONFIG_DIR` は逆に、checkout 内の claude / mise 呼び出しすべてに効くことが機能の
  本体なので、無条件にロードされる `mise.local.toml` に置く

結果として `mise.gh.local.toml` は「tracked から外す」と「読み込みを絞る」の二重ゲート、
`mise.local.toml` は前者だけの一重ゲートになる。

## trust

`bin/deploy.sh` を実行していない checkout には mise config が 1 つも無いので、trust を
聞かれない。実行すると雛形生成と同時に checkout が `trusted_config_paths` に path prefix で
登録されるので、生成された config にも `.worktrees/*` 配下からの解決にも trust が効く。
account を分けないマシンで deploy した後は、`mise.local.toml` を空にしておけばよい
（消すと再実行で再生成されるが、既にあるファイルは触らない）。worktree から親の config がどう解決されるかは `dot/claude/rules/worktree-scope.md` §6、
新しいマシンでの手順は `dot/claude/rules/dotrc-deploy.md` §6 を参照。
