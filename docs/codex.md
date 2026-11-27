# Codex CLI で dotrc を使う

1. Codex CLI にログインし、普段使う dotrc の checkout から `bin/deploy.sh` を実行する。
2. dotrc の `bin/` が PATH にあるシェルから `codex` を起動する。`/skills` で `proofread-doc`、`my-commit`、`my-create-pr` を確認する。commit と PR 作成はそれぞれ `$my-commit`、`$my-create-pr` で明示的に呼び出す。
3. `/hooks` で `claude-hook-git-guard` の定義を確認して信頼する。この hook は他 branch が所有する stash の取り出し・削除を検査する。実行には `git` と `jq` が必要。

deploy は [共通の規約と hook](../dot/codex/) を `${CODEX_HOME:-$HOME/.codex}` に、個々のスキルを `~/.agents/skills/` にリンクする。同名のファイルやスキルが既にあれば、メッセージを出してスキップする。既存の `AGENTS.md` や hook 設定を使っている場合は、必要な規約と hook 定義を手元の設定に取り込む。hook は `hooks.json` と `config.toml` のどちらか一方に登録する。

統合ブランチへの直接 commit を検査する [pre-commit](../githooks/pre-commit) は clone ごとに導入する。手順は [repo-baseline の pre-commit 節](../dot/claude/skills/repo-baseline/SKILL.md#6-pre-commit-hook) を参照。Codex のツールシェルでは `CODEX_THREAD_ID` を使って判定する。

スキルは Codex の sandbox と承認設定に従って動く。PR 作成は `gh-pr-create` の既存の mise 経由の認証を使う。
