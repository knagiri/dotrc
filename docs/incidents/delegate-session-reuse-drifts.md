# 委譲先の session を使い回すと文脈が膨らみ、元の目的から乖離する

## 経緯

委譲先は実装 → 自動 review → merge 待ちまで進めて委譲元へ完了を報告する。人の review で修正が
要るとき、完了報告を受けた委譲先をそのまま再開して指摘を渡す運用だと、同じ session に実装時の
文脈と review 対応の文脈が積み重なる。利用者は、文脈が膨らむほど指摘への対応が元の目的から
逸れていくと判断し、使い回さない方針を決めた。逸れた session の記録は残していないので、この帰結は
再現していない。

PR 監視による自動再開（`claude-queue watch`）を入れると、review が付くたびに session が起こされる。
使い回しの運用のままだと、このループが回るほど同じ session の文脈が増え続ける。

あわせて、running な session へ指示を渡す手段として `tmux send-keys` を検討したが、入力欄が空かを
判定できなかった。

## 観測

`tmux send-keys` の検討で、委譲元が 2026-10-26 に Claude Code 2.1.310 で観測した結果:

```
tmux capture-pane -p -t <pane>
...
❯ Reply with exactly: FIVE
```

この行は利用者が打った文字列ではなく、入力欄に表示された次の入力候補だった。`capture-pane` の
出力からは、打ちかけの文字列と区別できない。

`claude-worktree` の再利用については `bin/claude-worktree` を読んで確かめた。既存の worktree dir は
`worktree dir already exists, reusing` で再利用し、拒否するのはその worktree で background session が
動いているとき（`a background session is already running`）だけである。

## 直し方

- 委譲元は完了報告を受けたら必ず `claude-stop-bg` で委譲先を閉じる
- review で修正が要るときは、同じ worktree・同じ branch に新しい委譲先を起こし、「既存 PR #N の
  指摘への対応」だけを渡す。新しい委譲先は既存 PR の branch に push し、PR は作らない
- running な session には打ち込まない。休眠と同じ手順で止めてから、指示文を最初の入力にして resume する

## 反映先

- `dot/claude/rules/worktree-scope.md` §6（委譲元が閉じる理由と、修正は新しい session で行う理由）
- `dot/claude/skills/delegate-to-worktree/SKILL.md` 手順 6
- `dot/claude/skills/implement-and-review/SKILL.md` 手順 4
- `docs/design/claude-queue-lifecycle.md`「PR 監視と自動再開」
