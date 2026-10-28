# 委譲プロンプトの禁止事項が判定役へ転記されず、禁止された操作が撃たれた

## 経緯

harness を足す委譲で、委譲プロンプトに「実際に issue を起票しない」と書いてあった。委譲先は
実装後に `pr-review-automerge` を回したが、判定役（`pr-judge`）へ渡すプロンプトにはこの制約が
含まれていなかった。判定役は fresh context なので制約を知らず、検証のつもりで実 repo へ
`gh issue create --label <未作成の label>` を撃った。label が未作成だったため失敗し、作られた
issue は 0 件で、実害は無かった。

事後に skill を確かめると、穴は 2 段だった。

- **書く側**: `delegate-to-worktree` のプロンプト雛形は `## やること（WHAT）` / `## 設計（HOW）` /
  `## 進め方` の 3 節だけで、禁止事項を書く節も義務も無かった。当該プロンプトの
  `## 絶対にやらないこと` は委譲元がその場で足したものだった。禁止領域の名指しを求める唯一の
  記述は並列委譲時の担当領域の宣言で、目的は conflict 回避なので破壊的操作は射程外だった
- **渡す側**: `implement-and-review` に、WHAT の制約を実装 subagent や判定役・修正役へ転記せよ
  という記述が無かった

## 観測

判定役の実行したコマンドは `gh issue create --label <未作成>` の形で、label が無いことで失敗した
（作成 0 件）。skill 側は `dot/claude/skills/delegate-to-worktree/SKILL.md` と
`dot/claude/skills/implement-and-review/SKILL.md` を読み、「禁止」「制約」の節・転記の規定が
無いことを確かめた。

## 直し方

- 書く側: 雛形へ `## 禁止事項` 節を足し、スコープ外の破壊的・不可逆・外向きの操作があれば必ず書く
  不変条件を置く。並列委譲の担当領域の宣言はこの節の特殊ケースとして繋ぐ。節名は強度を名前に
  埋め込まない `禁止事項` にする
- 渡す側: `## 禁止事項` 節があれば、実装役・判定役・修正役のプロンプトへ原文のまま転記する

片方だけでは塞がらない。転記元が任意記述のままなら、委譲元が書き忘れた回は何も転記されない。

## 反映先

- `dot/claude/skills/delegate-to-worktree/SKILL.md` 不変条件・手順 2 の雛形
- `dot/claude/skills/implement-and-review/SKILL.md` 手順 2・手順 4
