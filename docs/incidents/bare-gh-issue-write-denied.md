# ラッパーの無い issue 書き込みを素の `gh` で撃ち、権限不足で失敗した

## 経緯

dotrc の個人用アクセストークン（Issues: Read and write を持つ）は `MISE_ENV=gh` のときだけ読まれる
`mise.gh.local.toml` に置かれ、shell の env には載らない。`bin/` の `gh-*` ラッパーは
`bin/lib/gh-mise.sh` 経由でそれを読むが、ラッパーの無い書き込み操作をどう呼ぶかは常時ロードされる
rule に書かれていなかった。agent が issue へのコメントを素の `gh issue comment` で撃ち、
`~/.config/gh/hosts.yml` のトークン（issue への書き込み権限を持たない）に落ちて失敗した。

## 観測

素の `gh issue comment <N> ...` が次で失敗した。

```
GraphQL: Resource not accessible by personal access token (addComment)
```

同じコマンドを `MISE_ENV=gh mise exec -- gh issue comment <N> ...` で再実行すると成功した。

## 直し方

ラッパーの無い書き込み操作は `MISE_ENV=gh mise exec -- gh ...` の形で呼ぶ、と常時ロードされる
rule に明記した。投稿してよいかの判断（reply ポリシー）と allowlist は変えていない。

## 反映先

- `dot/claude/rules/gh-commands.md` §1（末尾の段落）

## 追記: rule が定める label 付け替えも同じ理由で失敗した

`issue-workflow.md` §3 は、着手した側が `gh issue edit <N> --remove-label status/ready --add-label status/delegated`
で label を付け替えると定め、「allowlist に無いので承認プロンプトを踏む」とだけ書いていた。承認しても
素の `gh` は hosts.yml の token に落ちるので、付け替え自体が通らない。

観測（closed の issue で実行）:

```
$ gh issue edit <N> --remove-label status/triage --add-label status/delegated
GraphQL: Resource not accessible by personal access token (removeLabelsFromLabelable)
# exit 1、label は変わらない
$ MISE_ENV=gh mise exec -- gh issue edit <N> --remove-label status/triage --add-label status/delegated
# exit 0、付け替わった（確認後に元へ戻した）
```

直し方: `ready → delegated` だけを行う `bin/gh-issue-mark-delegated` を足し、allowlist に載せた。
`gh issue edit` は現在の label を確かめないので、ラッパーは `status/*` がちょうど `status/ready` 1 個で
あることを読んでから付け替え、それ以外は拒否する。同一ターンで起票と実装を指示された経路の
`triage → delegated` は、ラッパーでは指示の有無を区別できないので通さず、上の
`MISE_ENV=gh mise exec -- gh issue edit ...` で承認プロンプトを通す。

反映先:

- `docs/design/agent-issue-workflow.md` の allowlist 節
- `dot/claude/rules/issue-workflow.md` §3（ラッパーへ）、§6.2（triage 経路の呼び方）
- `dot/claude/rules/gh-commands.md` §1 の表、§4、§5 の表
- `dot/claude/settings.json`（`Bash(gh-issue-mark-delegated *)`）
- `dot/claude/skills/delegate-to-worktree/SKILL.md` 手順 1（§3 への参照に落とした）
