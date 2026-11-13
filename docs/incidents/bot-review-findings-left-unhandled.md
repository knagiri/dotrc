# bot のレビュー指摘が「non-blocker なので何もしない」まま PR に残った

## 経緯

`pr-review-loop` で回した PR で、bot（CodeRabbit / Copilot 等）のレビュー指摘のうち直さない
ものが、PR 上では未解決の thread のまま理由も残らずに放置されていた。PR を見ても、各指摘が
対応済みなのか対応不要と判断されたのかが分からず、人間が全件を読み直す必要があった。

原因は skill の仕様にあった。

1. 修正役は `findings_to_fix` 由来の thread しか resolve しない。gate に入った thread は
   「探さない・resolve しない」と定めていた
2. reply は skill の不変条件と `dot/claude/rules/gh-commands.md` §3 で禁じていた
3. `blocker: false` の gate は収束を止めない
4. 判定の結果は session の最終メッセージにしか出ず、PR には何も残らない

つまり「直さない」と判定した指摘には、PR 上で処置を残す経路そのものが無かった。

## 観測

委譲元が `~/.claude/projects` と `~/.claude-personal/projects` の subagent transcript から、
判定役の verdict JSON（`SubagentHandback` の `input.message`、または assistant の text に
含まれる `findings_gated` を持つ JSON）を `jq` で抜き出して集計した。この集計はこの doc を
書いた委譲では再実行していない。

- 626 verdict / 305 session。うち bot 由来の指摘を含むのは 88 session
- 件数は verdict ごとの延べ数で、同じ指摘が複数イテレーションで再掲されたものは重複して数える
- bot（source が coderabbit / copilot 等）由来の指摘の内訳: `findings_to_fix` 20、
  `findings_gated` で `blocker: false` 147、`threads_pending` で `blocker: false` 97、
  `blocker: true` 合計 7
- `blocker: false` の bot 指摘 176 件を `reason_gated` / `summary` のキーワードで粗く分類すると、
  指摘ではない（skip 通知・walkthrough 等）57、既に解消済み・古い HEAD 宛て 19、担当外・後回し 33、
  却下・軽微・その他 48、既裁定の再掲 19。分類の内訳は委譲元の報告値をそのまま写したもので、
  176 と 147+97 の関係（重複除去の有無等）は集計側の記録に無い

bot の指摘のうち直したのは延べ 20 件で、`blocker: false` のまま何も残さなかった指摘は、
いずれの母数で数えても直した件数を大きく上回った。

reply を bot の thread に限るため、bot の reviewer が GraphQL 上どう見えるかを公開 repo の PR で
read-only の query により確かめた。

```
$ gh api graphql -f query='{ search(query:"is:pr is:public commenter:copilot-pull-request-reviewer[bot] comments:>3", type:ISSUE, first:10){ nodes{ ... on PullRequest{ reviewThreads(first:20){ nodes{ comments(first:1){ nodes{ author{ __typename login } } } } } } } } }'
... {"author":{"__typename":"Bot","login":"copilot-pull-request-reviewer"}} ...
$ gh api graphql -f query='{ c:search(query:"is:pr is:public reviewed-by:coderabbitai[bot]", type:ISSUE, first:5){ nodes{ ... on PullRequest{ reviewThreads(first:10){ nodes{ comments(first:1){ nodes{ author{ __typename login } } } } } } } } }' \
    --jq '[.data.c.nodes[] | [.reviewThreads.nodes[].comments.nodes[0].author | "\(.__typename) \(.login)"]] | flatten | unique'
["Bot chatgpt-codex-connector","Bot coderabbitai"]
```

人間が起こした thread の起点は `__typename: User` で返り、存在しない node id は gh が
`Could not resolve to a node with the global id of '...'` で exit 1 になった。

## 直し方

bot が起こした thread に限って reply するラッパー `bin/gh-reply-thread` を足した。thread の
起点コメントの author を引き、`__typename` が `Bot` のときだけ `addPullRequestReviewThreadReply`
を撃つ。それ以外は mutation 前に拒否するので、人間が起こした thread への reply はこのラッパーでは撃てない（起点コメントしか見ないため、bot 起点の thread に人間が返信している場合は止まらず、そこへ reply しないのは利用側の責務）。
`gh-commands.md` §3 に、`pr-review-loop` の処置記録に限ってこの経路で bot の thread へ reply して
よい例外を足し、allowlist に `Bash(gh-reply-thread *)` を加えた。

そのうえで `pr-review-loop` に処置を義務づけた。判定役は bot の指摘すべてに `fix` / `decline` /
`defer` / `stale` / `human` / `not_a_finding` のいずれかを割り当て、修正役が `decline` / `defer` /
`stale` を実行する（thread なら reply して resolve、thread にならない指摘は PR 本文の
「レビュー指摘への対応」節に追記、`defer` は issue か TODO コメントを記録先にする）。処置を
実行した回は前進として扱い、実行すべき処置が残っている間は収束させない。thread の起点が bot か
どうかを判定役が見分けられるよう、`gh-list-threads` の出力に author の `__typename` を足した。

## 反映先

- `bin/gh-reply-thread`（新設）と `test/gh-wrappers.test.sh`
- `dot/claude/rules/gh-commands.md` §3（例外 — `pr-review-loop` の処置記録）・§4・§5 の表
- `dot/claude/settings.json` の allow
- `dot/claude/skills/pr-review-loop/SKILL.md`（冒頭・不変条件・手順 2.a-2 / 2.a-3 / 2.c・4、判定 subagent
  prompt の手順 2 / 4 / 5 / 5.5 と verdict、修正 subagent prompt の手順 5 と verdict、verdict スキーマ）
- `bin/gh-list-threads`（author の `__typename`）
