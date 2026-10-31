# PR フローの無い個人 repo で agent が委譲を検討せず main に直接 commit した

## 経緯

remote が無い、または remote はあるが PR を使わず main へ直接 push している個人 repo で、
agent が実装作業を main working tree のまま進め、main に直接 commit していた。
`worktree-scope.md` §5（main working tree での実装は既定で委譲する）は常時ロードされていたが、
agent は委譲を検討した形跡すら残していなかった。

§5 の委譲先は PR を出し、review と CI を経て merge する流れを前提にしている。PR フローの無い repo
では委譲の行き先が成り立たず、agent はその前提の欠落を問題として認識しないまま、main への直接
commit という repo の既存の運用に合わせていた。規約が効く前提を repo 側が満たしていないことは、
規約をいくら常時ロードしても検出されない。

## 観測

session の transcript から commit 系の tool_use を抜いた。

```
jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .input.command // empty' <transcript>.jsonl | rg 'git commit'
```

main working tree 上での `git commit` がヒットした。同じ transcript の思考に「委譲」「worktree」への
言及は無かった（当時のコマンド出力そのものは残っていない）。

## 直し方

- remote・PR フロー・CI が欠けた repo に気づいたら、baseline の適用を提案する
- baseline（GitHub の設定・CI・doc の配置）を当てる手順を skill にまとめ、repo ごとの手作業を無くす

main への commit を機械的に止める hook は別 issue（#182）で扱う。

## 反映先

- `dot/claude/rules/repo-docs.md`「baseline の欠けた repo」
- `dot/claude/skills/repo-baseline/SKILL.md`
