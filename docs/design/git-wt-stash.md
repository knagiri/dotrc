# git-wt-stash: worktree ごとの stash

`git stash` のスタック（`refs/stash` とその reflog）は common git dir にあり、main checkout と
全 linked worktree で共有される。ある worktree の `git stash pop` は、どの worktree で積まれた
entry も先頭から取るので、並行する session の変更が黙って持ち出される。`bin/git-wt-stash` は
entry の置き場所を worktree ごとに分け、他 worktree の entry を既定で見えなくする。
経緯は `docs/incidents/shared-stash-popped-by-subagent.md`。

## 置き場所

entry は per-worktree ref の `refs/worktree/stash` とその reflog に置く。`refs/worktree/*` は
worktree ごとに別の ref で、同じ名前が各 worktree で自分の ref に解決される。同じ ref は見る側に
よって名前が変わる。自 worktree からは `refs/worktree/stash`、main working tree からは
`worktrees/<id>/refs/worktree/stash`、linked worktree から見た main working tree のものは
`main-worktree/refs/worktree/stash`。

受け付けるのは `push [-u] [-m msg]` / `list` / `show|pop|apply|drop [N]` だけで、git へ引数を
素通ししない。`list` は `refs/worktree/stash@{N}` の表記で出し、共有スタックの `stash@{N}` と
取り違えないようにする。`dot/claude/settings.json` は生の `git stash` を deny し、`git-wt-stash` を
allow する。

## push

保存先が `refs/stash` 固定の `git stash store` と、`-u` を持たない `git stash create` では
untracked を含めて積めないので、積むときだけ共有の `refs/stash` を一瞬経由する。

1. message に一意な印を付けて `git stash push` する
2. `refs/stash` の reflog（`%H %gs`）から印の entry を探す。変更があったのに無い、または
   先頭に無い（別 session が間に積んだ）ときは drop せず exit 1 で、印と commit を stderr に出す
3. per-worktree ref へ `git update-ref --create-reflog` で写す
4. `refs/stash` がまだその commit を指しているときだけ `git stash drop` する

3 を 4 の前に置くのは、途中の失敗で entry が両方に残る（どちらにも無くならない）ようにするため。
翻訳されるメッセージは読まず、成否は git の終了コードで、entry の照合は reflog の
`%H %gs` で見る。locale に依存しない。

working tree の変更の有無を push の前に `git status --porcelain` で見ておくのは、印が見つからない
理由が「積むものが無かった」なのか「積んだ entry が消えた・読めなかった」なのかを区別するため。
後者を前者と同一視すると、退避済みの変更を exit 0 で隠す。

ref はあるが reflog が空の状態（期限切れの後など）に積むと、`update-ref --create-reflog` が
古い commit を上書きして到達不能にする。push はこの状態を検出したら何も積まず exit 1 で、
commit を stderr に出す。`list` も同じ commit を stderr に出す。

## pop / drop

`pop` / `apply` / `show` は `refs/worktree/stash@{N}` を commit に一度解決し、その commit を
`git stash apply` / `show` に渡す。`pop` と `drop` は削除の直前にもう一度解決して同じ commit
であることを確かめ、ずれていれば（間に同じ worktree への push が入った）消さず exit 1 にする。
`apply` するのは `pop` だけで、`drop` は削除だけを行う。`pop` で apply が失敗したら entry は残し、
apply が済んだ後の削除が失敗・拒否されたら、変更は apply 済みで entry は消えていないと伝える。

最後の 1 件を `git reflog delete --updateref --rewrite` で消しても reflog が空になるだけで ref は
残る。そのため件数は reflog の行数で数え、0 になったら `git update-ref -d <ref> <消した commit>`
で ref を消す。旧値を渡すのは、件数を数えてから消すまでの間に同じ worktree へ入った push の
entry を ref ごと消さないためで、旧値が合わなければ git が拒否し、新しい entry を残す。

存在確認は `git show-ref --exists`（完全一致）で行う。`refs/worktree/stash` という名前のブランチが
あると、素の名前は `refs/heads/refs/worktree/stash` に解決され、別の ref の reflog を stash として
扱ってしまうため。reflog の読み取り失敗は 0 件として扱わず、失敗として止める。

## reflog の期限切れ

reflog は既定で `gc.reflogExpire`（90 日）と `gc.reflogExpireUnreachable`（30 日）で期限切れになり、
`git gc` / `git reflog expire` に消される。既定で対象から外れるのは `refs/stash` だけで、
`refs/worktree/stash` の entry は消える。明示した `--expire` では `refs/stash` も対象になる。

対策として、`dot/git/config`（global git config）に、上の 3 つの名前それぞれの
`gc.<pattern>.reflogExpire` と `reflogExpireUnreachable` を `never` で置く。linked worktree から
`gc` を回すと main working tree の entry が `main-worktree/refs/worktree/stash` の名前で見えるので、
3 つとも要る。wrapper が push のたびに repo の local config へ書く形は、stash を使っただけで任意の
repo の config が黙って書き換わる副作用になるので採らない。

## worktree の後片付け

`git worktree remove` は per-worktree ref を worktree の git dir ごと、警告無しに消す。
`bin/git-reap-gone` はそのため `refs/worktree/stash` が残る worktree を skip する
（`docs/design/claude-tmux-worktree.md`「委譲 worktree の後片付け」の条件⑤）。

## 既知の限界

- 持ち主の単位は worktree で、session ではない。同じ worktree を共有する session（親と
  subagent 等）は互いの entry を区別しない。
- `refs/worktree/stash` は解決が worktree ごとに分かれるだけで、アクセス制御ではない。他
  worktree の ref は名前で指せ、`git stash apply worktrees/<id>/refs/worktree/stash@{0}` は git の
  上では動く。ただしこれは先頭が `git stash` なので Bash tool の deny（`Bash(git stash *)`）に
  当たる。deny をすり抜けるのは `git reflog show|delete worktrees/<id>/…` のように `git stash`
  以外のコマンドで読む・消す経路で、`git-wt-stash` が他 worktree の entry を見せないというだけである。
- deny の `Bash(git stash *)` は先頭が `git stash` のコマンドに一致する。`git -C <dir> stash` の
  ように global option が挟まる形は pattern の形からは一致しない（実機では未確認）。`git -C` は
  allow に無いので承認の対象になるが、`defaultMode` が auto のときは承認ではなく classifier の
  判定になる。`sh -c 'git stash …'` や git alias も一致しない。共有スタックに entry が常駐
  しないのは正常終了した push の一時 entry に限る。人が生の `git stash` で積んだ entry と、race・
  失敗で残ったコピーは共有されたまま残る。
- push の手順 2 の照合から 4 の `drop` までと、pop / drop の再解決から削除までは別々の git
  コマンドで、その間に別 session が積む窓が残る。push では窓に入られると、相手の entry を drop
  しうる。pop / drop では index がずれた entry を消しうる。「drop しない」「消さない」は照合した
  時点の保証であり、窓は閉じない（直列化は範囲外）。失敗時の stderr は印と commit を出すので、
  手で回収できる。
- reflog の期限切れ対策は global git config に依る。`dot/git/config` が展開されていない環境
  （別マシン・CI・HOME の違う実行環境）では効かず、期限を過ぎた entry は `git gc` で黙って
  消える。`git reflog expire --expire=<time>` のように期限を明示すると config は上書きされる。
- `git-reap-gone` の条件⑤は確認した時点の状態である。確認と `git worktree remove` の間に完了した
  push は守らないので、後片付けと stash 操作は並行させない前提になる。手で worktree を消すとき
  は先に `git-wt-stash list` で残りを確認する。
