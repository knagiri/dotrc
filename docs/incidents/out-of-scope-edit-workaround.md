# スコープ外の操作を前提にした誘導を足し、スコープの原則の欠落を隠しかけた

## 経緯

`claude-settings.md` に `paths` を付けたとき、user レベルの rule の `paths` は session の主
working directory 基準で照合されることが分かった（Claude Code 公式 docs の memory ページ、
Path-specific rules 節）。他 repo の session で `~/.claude/settings.json` を編集しても、
`claude-settings.md` は発火しない。

その対策として、常時ロードの `bash-command-constraints.md` 冒頭に「cwd の外にある `~/.claude/`
配下を編集するときは `claude-settings.md` を先に Read する」という 3 行の誘導を足した。

ユーザーから、そもそも他 repo の session から `~/.claude/` を触るべきではない、と指摘された。
harness の変更は dotrc で行い、他 repo では起票に留める。基本はどの repo でも、作業用ディレクトリを
除き、指示なく repo の外を触らない。

確かめると、この原則は rule に書かれていなかった。当時の `worktree-scope.md` §2 にある
「ディレクトリ外への書き込みはスコープ外」は、同じ repo の別 worktree と main checkout が対象だった。
repo の外の任意のパス（`~/.claude/` など）は対象に入っていなかった。

他 repo の session から `~/.claude/` を実際に編集した事故は起きていない。起きかけたのは、
スコープ外の操作を前提にした誘導を常時ロードの rule に足したことである。

## 観測

誘導を足す前の時点の rules（`paths` 無しのものを含む全 rule と `dot/claude/CLAUDE.md`）で、
repo の外への書き込みを扱う記述を探した。

```
$ git grep -n -E 'repo 外|リポジトリ外|working directory の外|ディレクトリ外' <当時の commit> -- 'dot/claude/rules/*.md' dot/claude/CLAUDE.md
dot/claude/rules/working-directory.md:79:- **cwd の巻き戻し**: working directory の外へ `cd` しても、その cwd は次のコマンドへ
dot/claude/rules/working-directory.md:89:上の 2 つはいずれも working directory の外へ出る `cd` の話で、**repo 内**のサブディレクトリへの
dot/claude/rules/worktree-scope.md:93:worktree のディレクトリ外（絶対パスで他 worktree や main checkout を指すパス）への**書き込み**は、原則スコープ外とみなす。
```

該当したのは、別 worktree・main checkout を対象にした記述と、`cd` の挙動の記述だけだった。

## 一般化した失敗の型

スコープ外の操作で生じる不都合に、その操作を前提にした回避策（誘導・例外）を足すと、原則の欠落が
隠れる。回避策が効いている間は不都合が見えないので、そもそもその操作をすべきでない、という問いが
立たない。

## 直し方

回避策を足すのではなく、スコープの原則を明文化した。`worktree-scope.md` を `session-scope.md` へ
一般化し、session のスコープ（起動した cwd の repo）の外へは明示的な指示なしに書き込まないこと、
harness の変更は dotrc の session で行うことを書いた。`bash-command-constraints.md` の誘導は削除した。

## 反映先

- `dot/claude/rules/session-scope.md` 冒頭（session のスコープの原則）
- `dot/claude/rules/bash-command-constraints.md`（誘導を削除）
