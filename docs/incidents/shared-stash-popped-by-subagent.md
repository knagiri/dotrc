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

## 当時の直し方（PreToolUse hook）

PreToolUse hook（matcher `Bash`、`bin/claude-hook-git-guard`）で、Bash tool のコマンド中の
`git stash pop|apply|drop|branch|clear` を見て、対象 entry の branch が対象 dir の現在 branch と
違えば deny した。git は同一 branch を 2 つの worktree で同時に checkout させないので、branch が
worktree の識別子になる。持ち主が判定できない（detached HEAD、または entry の message から branch
を読めない）ときや、対象 dir を判定できない（`-C` の引数が変数・`$(...)`・バッククォート・存在しない
パス）ときも deny に倒した。積む操作と閲覧は通した。コマンド文字列の検出は `;` `&&` `||` `|` 改行で
素朴に分割して各部分の先頭の git を見るだけで、quote や `cd` は解釈しなかった。

hooks docs（https://code.claude.com/docs/en/hooks）には、settings 由来の hook は subagent の中でも
動くとあった。実機での確認は未了のままだった。

## git-wt-stash への置き換え

hook は持ち主を共有スタック上の entry の message から推測する。branch を読めない entry を
deny に倒すのは過剰拒否（正当な操作を止める）であり、漏れではない。漏れは、コマンド文字列の素朴な
解析が `sh -c 'git stash …'` や git alias 経由の呼び出しを見落とす側にある。

そこで、entry の置き場所を worktree ごとの ref に分ける `bin/git-wt-stash` に置き換え、hook は撤去
した。保存先を隔離すれば他 worktree の entry はそもそも見えず、持ち主の判定もコマンドの解析も
要らない。生の `git stash` は permission で deny する。現行の設計と既知の限界は
`docs/design/git-wt-stash.md`。

## 置き換え時の観測

reflog の期限切れは linked worktree で再現した（git 2.56.1）。`GIT_COMMITTER_DATE=2026-01-01T00:00:00`
で `refs/stash` に `git stash push` で 2 件、`refs/worktree/stash` に `update-ref --create-reflog` で
2 件積み、`git reflog expire --all` と `git gc` を実行すると `refs/stash` は 2 件のまま、
`refs/worktree/stash` は 0 件になった。

2 つの ref 名だけを `never` にした構成では、linked worktree から `git reflog expire --all` と
`git gc` を回すと main working tree の entry（linked worktree からは `main-worktree/refs/worktree/stash`
の名前）が消え、ref だけが残った。3 つ目の名前を足して残ることを確かめた。

per-worktree ref の挙動は使い捨て repo で確かめた（git 2.56.1。main repo `r`、branch `feat` の
linked worktree `wt`）。

```
# wt で
echo x>>f; echo u>untracked
git stash push -q -u -m mine; sha=$(git rev-parse stash@{0}); git stash drop -q
git update-ref --create-reflog -m mine refs/worktree/stash $sha
git reflog show refs/worktree/stash        # 33059e8 refs/worktree/stash@{0}: mine
# r で
git reflog show refs/worktree/stash        # fatal: ambiguous argument
git stash list | wc -l                     # 0
# wt で
git stash apply -q refs/worktree/stash@{0}; git status --short
#  M f
# ?? untracked
git reflog delete --updateref --rewrite refs/worktree/stash@{0}
git rev-parse refs/worktree/stash          # sha を返す（最後の 1 件を消しても ref は残る）
```

最後の 1 件を消すと reflog は空になるが ref は残り、`refs/worktree/stash@{0}` も ref の値に解決される。
そのため `git-wt-stash` は reflog の件数で空を判定し、空になったら `git update-ref -d` で ref を消す。

## 反映先

- `bin/git-wt-stash`、`test/git-wt-stash.test.sh`、`docs/design/git-wt-stash.md`
- `dot/git/config` の `gc.<pattern>.reflogExpire(Unreachable)`
- `bin/git-reap-gone`、`test/git-reap-gone.test.sh`、`docs/design/claude-tmux-worktree.md`「委譲 worktree の後片付け」
- `dot/claude/settings.json` の `permissions.deny`（`git stash`）と `permissions.allow`（`git-wt-stash`）。
  `hooks.PreToolUse` の `claude-hook-git-guard`、`test/claude-hook-git-guard.test.sh` は削除
- `dot/claude/rules/session-scope.md` §6（stash は `git-wt-stash` を使う）
