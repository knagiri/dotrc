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

entry の置き場所を worktree ごとに分け、共有スタックを直接触る経路を塞ぐ。

- `bin/git-wt-stash`（`push [-u] [-m msg]` / `list` / `show|pop|apply|drop [N]`）は entry を
  per-worktree ref の `refs/worktree/stash` とその reflog に置く。`refs/worktree/*` は worktree
  ごとに別の ref で、`refs/worktree/stash` という名前は各 worktree で自分の ref に解決される。
  そのため `git-wt-stash` からは他 worktree の entry は見えず、`pop` でも取れない（明示的に
  指せば触れる。「既知の限界」）。受け付けるフラグを限定し、git へ引数を素通ししない
- 積むときだけ共有の `refs/stash` を一瞬経由する。`git stash store` は保存先が `refs/stash` 固定で、
  `git stash create` は `-u` を持たないため。message に一意な印を付けて `git stash push` し、
  `refs/stash` の reflog から印の entry を探す。無ければ積むものが無かったので何もしない。先頭に
  無ければ別 session が間に積んだので、drop せずに失敗する。先頭なら per-worktree ref へ写し、
  `refs/stash` がまだその commit を指すときだけ `git stash drop` する（別の push が割り込んで
  いたら drop せず失敗する）。drop の出力は parse しない。翻訳されるメッセージを読むと locale
  次第で誤判定するため。失敗時は印と commit を stderr に出す
- pop / drop は index を commit に解決してから apply し、消す直前に再度解決して同じ commit で
  あることを確かめる。間に同じ worktree への push が入って index がずれていたら消さずに失敗する
- reflog の期限切れ対策として、push 時に `gc.refs/worktree/stash.reflogExpire(Unreachable)=never`
  と `gc.worktrees/*/refs/worktree/stash.…=never`（main working tree から見た名前）を repo の
  config へ書く。`refs/stash` だけは git が expire の対象から外すが `refs/worktree/stash` は
  既定の 30 日で `git gc` / `git reflog expire` に消される（git 2.56.1 で再現）。dotrc 管理の
  global config に置く案もあったが、global config が展開されていない環境（別マシン・CI・
  委譲先の clone）では entry が黙って消えるので、wrapper が repo 側へ書く方を選んだ
- `dot/claude/settings.json` で生の `git stash` を deny し、`git-wt-stash` を allow する

以前は PreToolUse hook（`bin/claude-hook-git-guard`）が Bash のコマンド文字列から
`git stash pop|apply|drop|branch|clear` を探し、対象 entry の message にある branch が現在 branch と
違えば deny していた。これには穴が 2 つあった。持ち主を共有スタック上の entry の message から
推測するので、branch を読めない entry（detached HEAD、`git stash store -m`）は判定できず、
コマンド文字列の素朴な解析は `sh -c` や git alias 経由の呼び出しを見落とす。保存先を隔離すれば、他 worktree の
entry はそもそも見えないので、持ち主の判定もコマンドの解析も要らない。hook は撤去した。

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

## 既知の限界

識別子になるのは worktree であって session ではない。同じ worktree を共有する複数の session
（main working tree の interactive session と spin-off した session、親と Agent tool の subagent）
は互いの entry を区別しない。

`refs/worktree/stash` は worktree ごとに解決されるだけで、アクセス制御ではない。main working
tree からは `git reflog show worktrees/<id>/refs/worktree/stash`、`git stash apply
worktrees/<id>/refs/worktree/stash@{0}`、`git reflog delete worktrees/<id>/…` で他 worktree の
entry を読み・取り・消せ（linked worktree からは `main-worktree/refs/worktree/stash`）、どれも
deny の pattern に当たらない。`git-wt-stash` が他 worktree の entry を見せない、というだけである。

deny の pattern `Bash(git stash *)` は先頭が `git stash` のコマンドに一致する。`git -C <dir> stash`
のように git の global option が挟まる形はこの pattern の形からは一致しない（実機では未確認）。
`git -C` は allow に無いので承認の対象になるが、`defaultMode` が auto のときは承認ではなく
classifier の判定になる。`sh -c 'git stash …'` や git alias も pattern に一致しない。ただし
共有スタックには常駐する entry が無く（積む窓の間だけ）、これらで害を受けうるのはその窓に限られる。

`git worktree remove` は `refs/worktree/stash` ごと、警告無しに（exit 0）entry を消す。worktree を
消す前に `git-wt-stash list` で残りを確認する。

reflog の期限切れ対策は push 時に書く config に依る。この版より前に積んだ entry や、config を
消した repo では効かない。`git reflog expire --expire=<time>` のように期限を明示すると config は
上書きされ、entry は消える。

## 反映先

- `bin/git-wt-stash`、`test/git-wt-stash.test.sh`
- `dot/claude/settings.json` の `permissions.deny`（`git stash`）と `permissions.allow`（`git-wt-stash`）。
  `hooks.PreToolUse` の `claude-hook-git-guard` は削除
- `dot/claude/rules/session-scope.md` §2（stash は `git-wt-stash` を使う）
