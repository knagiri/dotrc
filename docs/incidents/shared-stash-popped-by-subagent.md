# 修正役 subagent が共有 stash を pop し、別 session の entry を自分の worktree に展開した

## 経緯

業務 repo での委譲作業で、委譲先が修正役 subagent を起こして PR を直していた。その subagent が
`git stash pop` を実行し、別 session が積んでいた stash entry がその worktree に展開された。

stash stack は common git dir（`refs/stash` とその reflog）にあり、main checkout と全 linked
worktree で共有される。ある worktree の `git stash pop` は、どの worktree で積まれた entry でも
先頭から取る。

親 session の system prompt には worktree session 向けの stash の注意書きが入っていたが、Agent tool
で起こした subagent の文脈には伝わっていなかった。注意書き（rule・prompt）は渡し手が転記して初めて
効くので、転記されなかった経路では何も止まらない。

展開された内容は `origin/main` の削除履歴と突き合わせると main 側で意図的に削除済みの古い状態
だったので、ユーザー承認を得て破棄して復旧した。生きた作業中の entry だった場合、積んだ側の
session から見ると変更が黙って消える。

## 観測

当時のコマンド出力は残っていない。共有されること自体は使い捨て repo で再現した。main で積んだ
entry が、別 branch の linked worktree の `stash list` に見え、そこで `pop` すると取れる。

```
git -C r stash push -q -m from-main     # r は main を checkout した main working tree
git -C wt stash list                    # wt は feat を checkout した linked worktree
# stash@{0}: On main: from-main
git -C wt stash pop                     # 展開され、entry は Dropped
git -C wt diff --stat
#  f | 1 +
git -C r stash list | wc -l
# 0
```

entry の message には積んだときの branch が `On <branch>: …` / `WIP on <branch>: …` の形で残る。

## 直し方

PreToolUse hook（matcher `Bash`）で、Bash tool のコマンド中の `git stash pop|apply|drop|branch|clear`
を見て、対象 entry の branch が対象 dir の現在 branch と違えば deny する。git は同一 branch を
2 つの worktree で同時に checkout させないので、branch が worktree の識別子になる。
持ち主が判定できない（detached HEAD、または entry の message から branch を読めない）ときや、対象 dir を判定できない（`-C` の引数が変数・
`$(...)`・バッククォート・存在しないパス）ときも deny に倒す。積む操作と閲覧は通す。コマンド文字列の検出は
`;` `&&` `||` `|` 改行で素朴に分割して各部分の先頭の git を見るだけで、quote や `cd` は
解釈しない。誤検知（quote 内の文字列を拾う等）でも何も取られず、deny になるのは git が持ち主を他 branch と
答えたとき、または持ち主・対象 dir を判定できないときだけである。

hooks docs（https://code.claude.com/docs/en/hooks）には、settings 由来の hook は subagent の中でも
動き、subagent が tool を呼ぶと PreToolUse が main conversation と同じ設定で発火するとある。
実機での確認は未了で、PR の人間確認項目に入れている。

## 既知の限界

識別子になるのは worktree であって session ではない。同じ worktree を共有する複数の session
（main working tree の interactive session と spin-off した session、親と Agent tool の subagent）
は同じ branch を持つので、互いの entry を区別せず通す。

## 反映先

- `bin/claude-hook-git-guard`（stash の判定）
- `dot/claude/settings.json` の `hooks.PreToolUse`
- `test/claude-hook-git-guard.test.sh`
