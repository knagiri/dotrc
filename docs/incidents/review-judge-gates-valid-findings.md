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

`<config dir>/projects/*/<session>/subagents/` にある判定役の transcript の最終メッセージから
verdict JSON を取り出し、指摘ごとの行き先を jq で数えた。5 PR については、専門 agent の最終
メッセージと 1 巡目の判定 verdict を手で突き合わせた。

各 transcript に下の式を `jq -c -s -f verdicts.jq <file>` で当て、出力を `items.jsonl` に溜めれば集計できる。jq の `//` は
`false` も欠損扱いにするので、`.blocker // null` と書くと `blocker: false` が `null` に化ける。
下の式は `has("blocker")` で分岐している。

```jq
# Input: one subagent transcript (jsonl) slurped with -s. Emits one JSON object per finding item
# from the judge's final verdict, or nothing if this transcript is not a judge prompt
# (the fixer prompt also mentions 判定役, so match the judge prompt's own phrase).
def prompt_text:
  [ .[] | select(.type=="user") | .message.content
    | if type=="string" then . else (map(select(.type=="text") | .text) | join("")) end ][0] // "";

def final_text:
  ( [ .[] | select(.type=="assistant") | .message.content[]?
      | select(.type=="tool_use" and .name=="SubagentHandback") | .input.message ] | last )
  // ( [ .[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text ] | last )
  // "";

def extract_json:
  # take from first "{" to last "}"
  (index("{")) as $s | (rindex("}")) as $e
  | if $s == null or $e == null then null else .[$s:$e+1] end;

prompt_text as $p
| select($p | test("独立した立場でレビューする\\*\\*判定役\\*\\*"))
| ($p | capture("PR #`?(?<pr>[0-9]+)`?") .pr // "?") as $pr
| ($p | capture("`?(?<it>[0-9]+)`? 巡目") .it // "?") as $it
| ($p | test("専門レビュー agent の findings")) as $has_spec_slot
| ($p | test("なし（専門レビューは skip / 全失敗）")) as $spec_skipped
| (final_text | extract_json | (try fromjson catch null)) as $v
| if $v == null then {pr:$pr, it:$it, bucket:"PARSE_FAIL"}
  else
    ( ($v.findings_to_fix // [])[] | {bucket:"fix"} + . ),
    ( ($v.findings_gated // [])[] | {bucket:"gated"} + . ),
    ( ($v.threads_pending // [])[] | {bucket:"pending"} + . ),
    ( ($v.pr_dispositions // [])[] | {bucket:("disp:" + (.action // "?"))} + . ),
    {bucket:"_verdict", n_fix:(($v.findings_to_fix//[])|length)}
    | {pr:$pr, it:$it, spec_slot:$has_spec_slot, spec_skipped:$spec_skipped,
       bucket, n_fix:(.n_fix // null), source:(.source // null), severity:(.severity // null),
       specialist_severity:(.specialist_severity // null),
       blocker:(if has("blocker") then .blocker else null end),
       oos:(if has("out_of_scope") then .out_of_scope else null end),
       bot_severity:(.bot_severity // null),
       summary:((.summary // "")[0:120]), reason:(((.reason_gated // .reason) // "")[0:200])}
  end
```

集計の例（gate の `blocker` × 判定役の severity × 出所）:

```sh
jq -r 'select(.bucket=="gated") | [.blocker, .severity, (.source // "null")] | @tsv' items.jsonl | sort | uniq -c
```

結果は次の 3 点である。

- 専門 agent 由来の指摘は、直したもの（約 170）より `blocker: false` で gate したもの（300）の
  ほうが多く、gate したもののほぼすべては判定役が severity を `low` に付け直していた。却下理由には
  「誤動作は見えていない」「費用対効果が低い」のように、妥当と認めたうえで見送ったものが多かった。
- `medium` 以上を gate したものは全件 1 巡目で、3 巡目以降の絞り込みの寄与は小さい。
- 5 PR（#185, #191, #216, #227, #234）で専門 agent が上位に置いた指摘を追うと、下表のとおり
  妥当でないとして gate したものは無かった。gate に回ったのは主に pr-test-analyzer の Important
  Improvements と silent-failure-hunter の HIGH である。#191 では別々の指摘が 1 項目に束ねられ、
  #234 では指摘が判定役の出力から落ちていた。

| 結果 | 件数 |
|---|---|
| 直した | 17 |
| 妥当だが価値低として gate | 19 |
| 妥当でないとして gate | 0 |
| 担当外 | 1 |
| 判定役の出力から脱落 | 1 |

## 直し方

- `blocker: false` の gate を「妥当でない」と判断したもの専用にした。妥当で担当内の指摘は
  severity / confidence に依らず `findings_to_fix` に入れ、「価値が薄い」「誤動作は見えていない」
  「費用対効果が低い」「網羅性の改善に留まる」を gate の理由にしない。bot の指摘の `decline` も
  「妥当でない」に限った。3 巡目以降の correctness / 安全性への絞り込みは変えていない
- 担当外であることは却下の理由にならない、という規定を doc の PR に限らず手順 5 本体に置いた
- 専門 agent に重大度ラベルを付けて返させ、verdict に `specialist_severity` として写させた。上位
  （agent ごとに含める段階は SKILL.md の判定 subagent prompt の手順 5）の指摘を gate にするときは、
  その agent の根拠を覆す理由を `reason_gated` に書かせる
- 専門 agent の各指摘が必ずどれかのバケットに 1 回現れること、別々の指摘を 1 項目に束ねないことを
  明示した

## 反映先

`dot/claude/skills/pr-review-loop/SKILL.md`

- 手順 2.a-0.5（専門 agent への prompt に重大度ラベル）
- 判定 subagent prompt の担当領域の段落、手順 5（仕分け）、手順 5.5 の処置表（`decline`）、
  verdict 出力のフィールド説明（`findings_gated` / `severity` / `specialist_severity` / `source` /
  `mergeable`）
- verdict スキーマ（orchestrator 側の判定基準）の報告用フィールド
