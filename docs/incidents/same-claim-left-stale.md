# 名指しされた箇所だけを直し、同じ主張や複写を持つ箇所が古いまま残った

## 経緯

記述・雛形・見出しを直す作業で、依頼に名指しされた箇所だけを直し、同じ主張や複写を持つ別の
箇所を見落とす形が続けて 2 回起きた。どちらも PR のレビューで拾われ、修正に 1 巡ずつ余分に
使った。

1. 委譲プロンプトの雛形の見出しを変えた作業で、雛形本体だけを直した。その雛形を写していた
   agent 定義（`dot/claude/agents/pr-judge.md`）、`pr-review-automerge` の判定 prompt、
   「雛形と一致」と書いた箇所が古い見出しのまま残り、1 巡目の指摘 7 件の大半がこれだった
2. `claude-queue watch --dry-run` は DB を書かない、という誤った記述を Go の doc comment
   （`internal/watch` の `DryRun`）で直した作業で、同じ主張を持つ CLI の flag ヘルプ
   （`"report what would be hibernated; change nothing"`）を見落とした

## 観測

コマンドの実測は無い。観測したのはレビューの指摘と、後追いで入った修正 commit である。
2 件目は、doc comment を直した commit の後に、flag ヘルプだけを直す commit が別に入っている。

```
$ git show 7605fb8 | rg '^[-+]\s+dryRun'
-	dryRun := fs.Bool("dry-run", false, "report what would be hibernated; change nothing")
+	dryRun := fs.Bool("dry-run", false, "report what would be hibernated; skip reconcile, PR watch and stop (opening the DB may still write)")
```

どちらも、直す前に旧い文言（見出し・`change nothing`）を `rg` で repo 全体から洗っていれば
見つかる位置にあった。

## 直し方

複写しない側で防ぐ方針（正典を 1 つにして他は参照に落とす）は変えない。そのうえで、記述・
雛形・見出しを変える PR では、名指しされた箇所を直す前に同じ主張や複写を `rg` で洗う手順を
補完として足した。対象は既に存在する複写と、doc comment と flag ヘルプのようにコードと doc に
同じ主張が並ばざるを得ない箇所である。

## 反映先

- `dot/claude/rules/rule-authoring.md`「規約の正典は rule に置き、skill / agent 定義からは参照する」
