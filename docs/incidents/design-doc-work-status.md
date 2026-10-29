# design doc に作業管理の情報（実装状況）が書かれた

## 経緯

新しい design doc を書かせたところ、冒頭に「> 実装状況: 未着手。」という引用ブロックが入った。
実装状況は issue / PR が持つ作業管理の情報で、design doc に書くと正典が 2 つになり、進捗のたびに
片方だけ更新されて食い違う。

design doc の template も、design doc に何を書かないかの規約も無かった。既存の
`docs/design/claude-queue-lifecycle.md` が冒頭に同じ形の「実装状況」行を持っており、その形が
真似されたと考えられる（確かめてはいない。既存 doc に同じ形の行があったことだけが観測できている）。

## 観測

修正前の `docs/design` で作業管理の記述を探すと、該当は lifecycle doc の冒頭だけだった。

```
$ rg -n '実装状況' docs/design
docs/design/claude-queue-lifecycle.md:3:> 実装状況: 第 1 部（状態モデルの 2 軸化・gone の一覧表示・mark の持続・`claude-stop-bg` の done 書き込み・
```

語を広げても、作業管理に当たるのは同じ引用ブロックだけだった。もう 1 件の一致は
`claude-digest` の出力例の中身で、doc 自身の状況ではない。

```
$ rg -n -i '実装済み|未着手|TODO|未対応|次の PR|別 PR で' docs/design
docs/design/claude-digest.md:404:      委譲先が「ADR は follow-up に分離」と報告、未着手
docs/design/claude-queue-lifecycle.md:5:> の廃止）、PR 監視による自動再開は実装済み。
```

## 直し方

- 既存 doc の「実装状況」行を削り、真似される型を repo から無くした
- design doc に作業管理の情報（実装状況・TODO・担当・着手順・進行）を書かない旨を、書いた時点の
  外部状態を写した記述の一種として観点集に足した。設計上の依存関係・段階的な移行手順・実装者の
  裁量範囲は設計なので書いてよい、という区別も併記した

## 反映先

- `dot/claude/rules/doc-authoring.md`「観点 1: 作成過程の痕跡を消す」
