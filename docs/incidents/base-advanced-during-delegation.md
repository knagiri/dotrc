# 委譲中に base が進んで conflict したまま PR を出し、レビュー 1 周を消費した

## 経緯

`implement-and-review` に委譲された作業で、実装中に base（`origin/main`）が 40 コミット以上
進んだ。そのうち 1 つが、自分が編集していたファイルの同じ段落を変更していた。テストは手元で
通っていたので base の進行を確かめずに PR を出し、GitHub 側は `mergeStateStatus: DIRTY` になった。
`pr-review-automerge` の判定役が conflict を発見し、修正役が解消するまでで 1 イテレーションを
まるごと消費した。修正役は他人の変更を conflict 解決越しに扱うことになり、内容欠落のリスクも乗った。

同じ委譲ランでは、repo に `my-create-pr` skill があり settings.json で allow 済みだったのに、
生の `gh pr create` で PR を作っていた（base の決定・diff の基準などの作法が迂回された）。

## 観測

コマンド出力は残っていない。観測は次の 2 点。

- PR 作成時点で `mergeStateStatus` が `DIRTY` だった
- 判定役の verdict が conflict を blocker として挙げ、修正役のイテレーションが 1 回費やされた

## 直し方

PR を出す前に base の現在地を見る手順を足した。

```
git fetch origin
git log --oneline HEAD..origin/<base>
git diff --name-only HEAD...origin/<base>
```

自分が触ったファイルが base 側でも変わっていれば、PR 前に取り込む。あわせて PR 作成は
既定で `my-create-pr` を通すと明記した。

## 反映先

- `dot/claude/skills/implement-and-review/SKILL.md` 手順 3「base の進行も確認する」
- `dot/claude/skills/implement-and-review/SKILL.md` 手順 4（`my-create-pr` を既定にする）
