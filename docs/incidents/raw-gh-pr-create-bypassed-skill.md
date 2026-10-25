# allow 済みの `my-create-pr` skill を使わず、生の `gh pr create` で PR を作った

## 経緯

`implement-and-review` に委譲された作業で、repo に `my-create-pr` skill があり settings.json で
allow 済みだったのに、生の `gh pr create` で PR を作っていた。base の決定（既定ブランチを
取得する）、diff の基準（remote ref の 3 点表記）、`--base` の常時明示といった、skill 側に集約された
作法が丸ごと迂回された。skill が使える状態でも、手元で撃てる生のコマンドのほうへ手が伸びた。

## 観測

コマンド出力は残っていない。観測は、委譲ランの記録で PR が `gh pr create` の直接呼び出しで
作られており、`my-create-pr` が呼ばれていなかったこと。迂回によって実害が出たかは確かめていない。

## 直し方

`implement-and-review` の review→merge 手順に、PR は既定で `my-create-pr` を通し、生の
`gh pr create` を直接叩かないと明記した。

## 反映先

- `dot/claude/skills/implement-and-review/SKILL.md` 手順 4（`my-create-pr` を既定にする）
