# doc の PR で、doc を正確にする指摘を判定役が「担当外」として見送った

## 経緯

`pr-review-loop` の判定役が、正しく価値もある指摘を「担当外」（`out_of_scope: true`）として
見送っていないかを調べるため、委譲元が判定役の verdict から指摘を標本抽出して評価した。独立した
opus の subagent に、PR の当時のコードと突き合わせて「指摘は正しいか・直す価値はあるか・判定役の
直す／見送る判断は妥当か」を判定させた。

- dotrc（標本 60 件）: 直す判断 20/20 が妥当。見送り 40 件は妥当 36、判断が分かれる 4、誤り 0。
  見送ったものの大半は「正しいが価値が低い」指摘だった
- bot を有効にしている別の repo（標本 49 件）: 誤り 0。ただし bot 由来で重大度が medium 以上の
  見送り 9 件のうち 4 件が判断の分かれるものだった

判断の分かれた見送りは、次の形をしていた。

- ADR の PR で、リスクの書き方が楽観的という指摘と、rollback した後の接続の状態が書かれていないと
  いう指摘を、どちらも 1 巡目で `out_of_scope: true` として見送った。理由は「記述内容の変更になる
  ので担当外」「ADR の決定内容への追記になるので担当外。実装 PR で詰めてもよい」。最終版の ADR には
  該当の記述が入っている
- designdoc の PR で、job の完了前に画像を取得したときのエラー時の挙動という、その designdoc が
  決めるべき事柄の指摘を、1 巡目で「後段の実装の設計に関わるので担当外」として見送った
- CodeRabbit が Major と付けた指摘が、`threads_pending` に重大度を持つ欄が無い仕様のため重大度が
  空のまま扱われ、判定役も orchestrator も重大度を見ていなかった

3 巡目以降に `findings_to_fix` を correctness と安全性に絞る規定は原因ではなかった。該当の見送りは
すべて 1〜2 巡目だった。

原因は、判定役がレビュー対象の doc への追記を一律に「決定内容の変更」とみなして担当外にしたこと
にある。実際の指摘は「既に決めたことを正確に・漏れなく書く」もので、新しい設計判断を足す話では
なかった。doc の PR では記述そのものが成果物なので、記述の修正を担当外にすると PR が担当している
作業そのものを見送ることになる。

標本の verdict・指摘本文は業務 repo のものを含むので、ここには写さない。評価の手順と件数は委譲元の
報告値をそのまま写したもので、この doc を書いた委譲では再実行していない。

## 観測（bot の重大度の表記）

bot の重大度を verdict に残すため、CodeRabbit が重大度を指摘本文のどこにどう書くかを、公開 repo の
PR で read-only に確かめた。

```
$ gh search prs --reviewed-by "coderabbitai[bot]" --limit 15 --sort updated --json repository,number
$ gh api repos/<owner>/<repo>/pulls/<N>/comments --jq '.[] | select(.user.login|test("coderabbit")) | .body'
<!-- coderabbit-ai-generated:v1 -->

**<picture><img src=".../review-comment-icons-v1/major-16.svg" ... alt=""></picture> Major** · **Stability & Availability** · **Quick win**
```

inline の review comment（thread の起点）は本文冒頭の太字に `Critical` / `Major` / `Minor` /
`Trivial` 等の語を置く。review 本文（`gh pr view <N> --json reviews`）の "Outside diff range
comments" / "Nitpick comments" に入る指摘も、個々の指摘に同じ形の重大度が付いていた。標本の PR で
観測した値は `Major` / `Minor` / `Trivial` で、`Critical` は観測していない。

## 直し方

`pr-review-loop` の判定 subagent prompt を 2 点改めた。

- 担当領域の段落に、doc が成果物の PR での基準を足した。doc が既に決めている事柄の記述の誤り・
  楽観的すぎる記述・漏れを直すことは担当内で、担当外になるのは新しい設計判断を足す必要がある
  ときだけ。その場合も却下にせず、人間の判断待ちか後回しの処置にする
- verdict の各要素に `bot_severity` を足し、bot が書いた重大度を写させた。bot が Major 以上とした
  指摘を `decline` にするときは、その重大度を覆す根拠を `reason` に書かせる。収束条件・継続判定は
  変えず、最終サマリでの報告にだけ使う

## 反映先

- `dot/claude/skills/pr-review-loop/SKILL.md`（判定 subagent prompt の担当領域の段落・手順 5.5・
  verdict のスキーマと `bot_severity` の説明、verdict スキーマ節の報告の扱い）
