# レビュー指摘が委譲の範囲外に及んだとき、直す範囲が委譲先の判断に委ねられていた

## 経緯

flaky テストの修正を任された委譲先が、既存 PR の branch で作業した。その PR には前の委譲先が
積んだ commit があり、レビューでそちらのバグ（session の再開時に古い `pin_seen_at` が残る）が
指摘された。委譲プロンプトの担当は flaky テストの修正だけで、この指摘を直すかどうかは書かれて
いなかった。委譲先は自分の判断で直した。

結果は妥当だった。merge しようとしている PR 自身のバグを見送れば、そのまま main に入る。
ただし判断の根拠は委譲先の裁量にしか無く、逆の判断（担当外として見送る、または差分の外まで
直しに行く）もありえた。

`dot/claude/agents/pr-judge.md` の仕分けは既に「この PR の diff 自体が作り込んだ欠陥は、どの
ファイルにあっても担当内」と定めていた。欠けていたのは、同じ branch に前の委譲先が積んだ
commit もこの diff に含まれるという点で、担当領域が一部の修正に限られた委譲では、diff を
「今回の委譲先が足した分」と読む余地が残っていた。

## 観測

`dot/claude/agents/pr-judge.md` 手順 5 と `dot/claude/skills/pr-review-loop/SKILL.md` の
「判定 subagent prompt」を読み、担当内外の線引きが「直すにはこの PR の担当を超える作業が
要るか」で、diff の範囲の定義は無いことを確かめた。担当外で妥当な指摘は
`blocker: true, out_of_scope: true` になり、それだけが残ると orchestrator は停止して報告する
（委譲元へは `implement-and-review` 手順 6 の中断報告で届く）。差分の外のバグを「直さず委譲元へ
報告」する経路は既存の仕組みで足りている。

## 直し方

- PR の差分の中のバグは、委譲の担当外でも直す。差分は PR の base からの差分全体で、前の委譲先の
  commit を含む
- 差分の外のバグは直さず委譲元へ報告する。直すかどうかと誰に任せるかは委譲元が決める

委譲プロンプトに毎回書く欄は設けず、判定役の手順（`pr-judge.md` と判定 subagent prompt）に置く。委譲先が受けた指摘をすべて
抱えると session が元の目的から乖離する（`delegate-session-reuse-drifts.md`）ためである。

## 反映先

- `dot/claude/skills/pr-review-loop/SKILL.md` 判定 subagent prompt（担当領域の段落）
- `dot/claude/rules/worktree-scope.md` §6（review で修正が要るときの箇条から参照）
