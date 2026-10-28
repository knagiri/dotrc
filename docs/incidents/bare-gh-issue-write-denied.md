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
