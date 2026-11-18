# incident doc に結論を支えない具体値が写されていた

## 経緯

`docs/incidents/review-judge-gates-valid-findings.md` の「## 観測」節が膨らんでいた。結論を
支えていたのは「gate したものが直したものより多く、ほぼすべて判定役の severity が `low` だった」
「`medium` 以上を gate したものは全件 1 巡目だった」「5 PR の追跡結果」だけだった。それ以外に、
判定 verdict の総数、agent 種別ごとの実行回数、却下理由のキーワード分類の件数と内訳が並び、
「委譲元から渡されておらず不明」「〜は今回の数値に影響しない」のような作成過程の注記も
付いていた。ユーザーの指摘は「doc 全般に言えることだけど、重要でない具体値はいらない」。

並んでいた値のうち verdict の総数は、判定役ではない修正役の verdict を含んでいて誤っていた。
結論に効かない値だったので、誤りのまま review を通っていた。

原因は 2 つある。

- 委譲元が集計した実測値を委譲プロンプトに渡し、委譲先がそれを doc へそのまま写した
- 規約がどれも値を全部写す方向に読めた。`rule-authoring.md` の incident doc の書き方は
  「実測は…実行したコマンドと観測した出力を併記する」、`delegate-to-worktree` は「spec / plan に
  実測を書くときは…併記する」と書くだけで、何を写さないかを言っていなかった。
  `doc-authoring.md` 観点 4 の取捨選択の基準は design doc の実装台帳を想定しており、
  incident doc の観測値には当てはまらなかった

## 観測

削った差分は、結論を支える 3 点を残して他の値と注記を落としたものである。

```
$ git show 73d9deb --format=%B --no-patch | sed -n 3,5p
判定 verdict の総数・agent 種別ごとの実行回数・キーワード分類の件数と、
作成過程の注記を消す。総数 156 件は修正役の verdict 36 件を含む誤りだったが、
結論に効かないので直さず書かない。指摘の件数・追跡結果・結論は変わらない。

$ git show 73d9deb -- docs/incidents/review-judge-gates-valid-findings.md | rg '^-' | rg '156|不明|影響しない'
-prompt 固有の文言に絞り、出力に `n_fix` と `specialist_severity` を残すようにした。156 件に修正役の
-`specialist_severity` は 156 件の導入前のフィールドなので、今回の数値には影響しない（再集計用）。
-**対象**: `pr-review-loop` 判定役の verdict 156 件。専門 agent の subagent transcript は
-その内訳は委譲元から渡されておらず、不明である。
```

## 直し方

- この差分で消えた値（総数・実行回数・キーワード分類）は、改訂後の `doc-authoring.md` 観点 4 の
  付随ルールでは結論に効かない集計値として削る側に入り、消えた注記は観点 1 の「出典・検証の
  注記」に入る
- 具体値は結論を支えるものだけ残す、を doc の種別を問わない一般則として観点集に足した
- incident doc の実測の書き方を「結論を支える観測に絞り、それを得たコマンドと出力を併記する」
  に改めた。再現性の要件は残した
- 委譲で実測を渡すときは、どの値が結論を支えるかを明示するようにした

## 反映先

- `dot/claude/rules/doc-authoring.md`「観点 4: 内容の取捨選択（実装台帳の解体）」の付随ルール
- `dot/claude/rules/rule-authoring.md`「由来は一般化して本文に書き、経緯は incident doc に置く」
- `dot/claude/skills/delegate-to-worktree/SKILL.md` の「spec / plan に実測を書くとき」の段落
