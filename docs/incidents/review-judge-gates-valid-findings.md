# 判定役が妥当と認めた指摘を `low` に付け直し、`blocker: false` の gate に回して収束させていた

## 経緯

`pr-review-loop` の判定役は、専門レビュー agent（pr-review-toolkit）の指摘の多くを
`findings_gated`（`blocker: false`）へ回していた。`blocker: false` は merge を止めず、orchestrator は
それだけなら収束させ、`pr-automerge` も gate を見ない。つまり gate に回った指摘は、誰にも読まれ
ないまま直されずに merge されていた。

原因は判定 prompt 手順 5 の次の bullet だった。

> 修正の価値が薄い低 severity / 低 confidence の指摘は、`findings_to_fix` ではなく
> `findings_gated`（`blocker: false`）に寄せてよい（`findings_to_fix` が非空だと必ず次
> イテレーションが走るため、瑣末な指摘を積むと 5 回の上限を使い切ってしまう）。

判定役はこれを、妥当と認めた指摘を見送る裁量として使っていた。severity を `low` に付け直して
gate に回し、理由には「穴の指摘は正しいが…修正の価値が薄い」「案は妥当だが優先度は低い」のように
妥当と認めたうえで見送った旨を書いていた。5 回の上限は終わらない往復を止めるためのもので、
到達しても人間へ報告して止まるだけなので、上限を守るために妥当な指摘を見送るのは向きが逆である。
同じ手順 5 の「取捨選択は orchestrator と人間が gate を見て行える」も、merge 前に gate を読む工程が
無いので根拠として成り立っていなかった。

## 観測

委譲元が個人 config dir の transcript から集計した値を写す。この doc を書いた委譲では再集計して
いない。

**対象**: `pr-review-loop` 判定役の verdict 156 件。各 subagent transcript の最終メッセージ
（`SubagentHandback` の `input.message`、無ければ最後の assistant text）から JSON を取り出し、
`jq` で集計した。専門 agent の subagent transcript は `agentType` 別に code-reviewer 49 /
comment-analyzer 48 / pr-test-analyzer 33 / silent-failure-hunter 19 / type-design-analyzer 2 件あり、
専門レビューは skip されずに走っていた。

**専門 agent 由来（`source` が `pr-review-toolkit:*`）の項目の行き先**:

| 行き先 | 件数 |
|---|---|
| `findings_to_fix` | 約 169 |
| `findings_gated`（`blocker: false`） | 300（判定役の severity `low` 287、`medium` 13） |
| `findings_gated`（`blocker: true`） | 3 |

**`blocker: false` の却下理由**（理由文のキーワードで分類）: 「価値が薄い / 軽微 / 低優先」系 約 61、
「担当外 / 既存」系 約 54（うち `out_of_scope: true` が 39）、「誤り / 当たらない」系 約 20。
担当外の指摘は、妥当なら `blocker: true, out_of_scope: true` にする規定が既にあったが、
`blocker: false, out_of_scope: true` で却下されたものが多かった。

**巡目**: `medium` 以上を `blocker: false` で gate したものは全件 1 巡目だった。3 巡目以降の判定は
11 件しかなく、3 巡目以降に `findings_to_fix` を correctness / 安全性に絞る規定の寄与は小さい。

**上位の指摘の追跡**: 5 PR（#185, #191, #216, #227, #234）で、専門 agent が上位に置いた指摘
38 件（code-reviewer Important、comment-analyzer Critical、pr-test-analyzer Critical Gaps / Important、
silent-failure-hunter HIGH、type-design-analyzer 優先度 1）を 1 件ずつ追跡した。

| 結果 | 件数 |
|---|---|
| 直した（全件修正済み） | 17 |
| 妥当だが価値低・先送りとして gate | 19 |
| 妥当でないとして gate | 0 |
| 担当外 | 1 |
| 判定役の出力から脱落 | 1 |

gate されたのは pr-test-analyzer の Important 全 15 件と、#191 の silent-failure-hunter HIGH 3 件
など。理由は「網羅性の改善に留まる」「誤動作は見えていない」「費用対効果が低い」だった。
#191 では pr-test-analyzer の 4 件が 1 項目に束ねられて gate され、#234 では comment-analyzer の
Critical 1 件が判定役の出力から落ちていた。

## 直し方

- `blocker: false` の gate を「妥当でない」と判断したもの専用にした。妥当で担当内の指摘は
  severity / confidence に依らず `findings_to_fix` に入れ、「価値が薄い」「誤動作は見えていない」
  「費用対効果が低い」「網羅性の改善に留まる」を gate の理由にしない。bot の指摘の `decline` も
  「妥当でない」に限った。3 巡目以降の correctness / 安全性への絞り込みは変えていない
- 担当外であることは却下の理由にならない、という規定を doc の PR に限らず手順 5 本体に置いた
- 専門 agent に重大度ラベルを付けて返させ、verdict に `specialist_severity` として写させた。上位
  2 段の指摘を gate にするときは、その agent の根拠を覆す理由を `reason_gated` に書かせる
- 専門 agent の各指摘が必ずどれかのバケットに 1 回現れること、別々の指摘を 1 項目に束ねないことを
  明示した

## 反映先

`dot/claude/skills/pr-review-loop/SKILL.md`

- 手順 2.a-0.5（専門 agent への prompt に重大度ラベル）
- 判定 subagent prompt の担当領域の段落、手順 5（仕分け）、手順 5.5 の処置表（`decline`）、
  verdict 出力のフィールド説明（`findings_gated` / `severity` / `specialist_severity` / `source` /
  `mergeable`）
- verdict スキーマ（orchestrator 側の判定基準）の報告用フィールド
