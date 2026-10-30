# 名指しされた箇所だけを直し、同じ主張や複写を持つ箇所が古いまま残った

## 経緯

記述・雛形・見出しを直す作業で、依頼に名指しされた箇所だけを直し、同じ主張や複写を持つ別の
箇所を見落とす形が続けて 2 回起きた。どちらも PR のレビューで拾われ、修正に 1 巡ずつ余分に
使った。

1. 委譲プロンプトの雛形の見出しを変えた作業で、雛形本体だけを直した。その雛形を写していた
   agent 定義（`dot/claude/agents/pr-judge.md`）、`pr-review-automerge` の判定 prompt、
   「雛形と一致」と書いた箇所が古い見出しのまま残り、1 巡目の指摘 7 件の大半がこれだった
2. `claude-queue watch --dry-run` は DB を書かない、という誤った記述を、doc comment
   （`src/claude-queue/internal/watch/watch.go` の `Options.DryRun`）と
   `src/claude-queue/README.md` では直した（commit 854ec0c）が、同じ主張を持つ CLI の flag
   ヘルプ（`"report what would be hibernated; change nothing"`）を見落とした

## 観測

観測したのはレビューの指摘と、後追いで入った修正 commit である。2 件目は、doc comment と
README を直した commit 854ec0c の後に、flag ヘルプだけを直す commit 7605fb8 が別に入っている。

```
$ git show 7605fb8 | rg '^[-+]\s+dryRun'
-	dryRun := fs.Bool("dry-run", false, "report what would be hibernated; change nothing")
+	dryRun := fs.Bool("dry-run", false, "report what would be hibernated; skip reconcile, PR watch and stop (opening the DB may still write)")
```

1 件目は洗い出しを実測しておらず、旧い見出しを repo 全体で検索すれば見つかったはず、という
類推である。2 件目は flag ヘルプを直す前の commit 854ec0c で実測した。doc comment の文言（三単現の
`changes nothing`）をそのまま検索語にすると flag ヘルプの `change nothing` には一致しない。
語尾の揺れを許す検索なら、flag ヘルプに一致する。

```
$ git grep -n 'changes nothing' 854ec0c -- src/claude-queue/internal/watch/watch.go
(一致なし)
$ git grep -n 'change.\? nothing' 854ec0c -- src/claude-queue/internal/watch/watch.go
854ec0c:src/claude-queue/internal/watch/watch.go:153:	dryRun := fs.Bool("dry-run", false, "report what would be hibernated; change nothing")
```

（修正前の `854ec0c^` では前者が doc comment の 32 行目に一致する。）

## 直し方

複写しない側で防ぐ方針（正典を 1 つにして他は参照に落とす）は変えない。そのうえで、記述・
雛形・見出しを変える PR では、名指しされた箇所を直す前に同じ主張や複写を `rg` で洗う手順を
補完として足した。対象は既に存在する複写と、doc comment と flag ヘルプのようにコードと doc に
同じ主張が並ばざるを得ない箇所である。

## 反映先

- `dot/claude/rules/rule-authoring.md`「規約の正典は rule に置き、skill / agent 定義からは参照する」
