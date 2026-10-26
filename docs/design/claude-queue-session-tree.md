# claude-queue: 委譲の親子関係と孤児 session

## 目的

`delegate-to-worktree` / `bin/claude-worktree` は委譲元 session から委譲先 session を起こす。その
親子関係を claude-queue に記録し、picker（`C-q q` / `C-q Q`）で木として表示する。あわせて、親を
失った session（孤児）を picker で見分けられるようにし、休眠が孤児を返信待ちとみなさずに止められる
ようにする。

委譲先は完遂しても `idle` のまま残り、委譲元が `claude-stop-bg` で閉じる（作業を done にする）
（`dot/claude/rules/worktree-scope.md` §6）。委譲元が閉じずに先に done になれば cascade で委譲先も
done になる。閉じ忘れた委譲先は最後のターンが完了報告の `SendMessage` なので、委譲元が done になるまで
休眠しない。どちらも親子関係が無いと判別できない。

## スコープ外

- `claude-worktree --tmux` 経路。interactive claude は pane の中で自分の session id を採番する
  ので、起動時点で子の id が分からない
- 記録を始める前に起動した session の backfill。親を記録していない session はすべて root として扱う

## 記録

`session_links(child_short, parent_session_id, created_at)` に 1 委譲 1 行で持つ。書くのは
`claude-worktree` の bg 経路だけで、`claude --bg` が返った直後に `claude-queue link --parent <uuid>
--child <short>` を 1 回呼ぶ。親は `resolve_delegator()` が名前を取るのと同じ roster entry の
`sessionId`。link の失敗や `claude-queue` の不在は警告に留め、起動は成功のまま続ける（session は
もう走っているので、失うのは link だけにする）。

子を full UUID ではなく 8 桁の short id で持つのは、`claude-worktree` がそれしか得られないため
である。`--bg` は `--session-id` を無視し、banner に出るのは short id だけで、roster から full id を
引こうにも `claude --bg` が返った時点で登録済みとは限らない。読む側は
`substr(session_id, 1, 8)` で join する。同じ理由で `sessions` への FK も張らない。link を書く時点で
子の SessionStart hook がまだ走っていないことがあり、親の行も GC で先に消えうる。

GC は `created_at` が GC 期限より古く、かつ親子のどちらも作業が open でない link を消す。子の行を
基準に消さないのは、子の行が一度も書かれない場合があるため。

## 表示（picker）

木の順を主にし、priority は兄弟間の順序にだけ効かせる。`q` と `Q` の両方に適用する。

1. open な行（running と gone）を全状態で読み、state filter（`--show-working` / `--show-stale`）を
   通った行を残す。gone は filter に関わらず残る
2. 残した行の祖先を `parent_session_id` で辿り、open な行に在れば加える。**祖先には state filter
   を掛けない**。`q` は `working` を隠すが委譲中の親はたいてい `working` なので、掛けると木が崩れる
3. repo-scope（`--repo-scope`）を掛ける。これは祖先の引き戻しより後で、戻さない。そのうえで、
   引き戻しでしか入っていない行のうち repo filter 後の一覧に子が残らなかったものを、変化が
   無くなるまで落とす。子が repo 外で落ちたのに親だけが一覧に残ると、この repo の session を見る
   一覧にとってノイズになるため
4. 森を組み、兄弟（root 同士を含む）を「部分木の最小 priority 昇順 → 部分木の最大 `created_at`
   降順 → session id 昇順」で並べる。承認待ちの子がいれば親ごと上に来る

罫線は `tree` と同じ形で、title 列の先頭に付ける。列を増やさないので非表示列の位置は変わらず、
title は prefix の幅を引いた残りで切り詰める。

### 親が一覧に居ない root

| 状態 | 印（emoji / ASCII） |
|---|---|
| link が無い（`parent_session_id` が NULL） | なし |
| 親の作業は open（running / gone）だが一覧に居ない（repo-scope で除外された等） | `↑` / `^` |
| 親が done（または GC 済みで行が無い） | `✂` / `x`（孤児） |

NULL は「記録が無い」だけで、親が居ないことを意味しない。この 3 つを混同すると、backfill していない
既存 session がすべて孤児に見える。

判定は ledger の作業軸（`done_at IS NULL`）で行い、プロセスの生死は見ない。親が gone なだけなら
resume すれば委譲の関係ごと戻るので、孤児にしない（[claude-queue-lifecycle.md](claude-queue-lifecycle.md)）。
読み出しに失敗したときは親を open とみなし、孤児の印を出さない側に倒す。

link の循環は `claude-worktree` からは生じないが、テーブルは禁じていない。session id 順に祖先を上り、
既に訪れた id へ戻る link を切って root にする。

## 休眠での扱い（`claude-queue watch`）

休眠（[claude-queue-lifecycle.md](claude-queue-lifecycle.md)「休眠」節）は、最後の assistant ターンに
`SendMessage` がある session を返信待ちとみなして止めない。委譲元へ質問して返信を待つ委譲先を止めると、
返信の受け手が居なくなるためである。孤児はその返信が来ないので、この検査と、それが前提にしている
transcript の読み取り・parse を省く。`idle_done` からの経過時間の閾値と、`claude agents` の一覧で
idle であることの検査は孤児でも変えない。

ここでの孤児は、link が在り、かつ親の作業が done、または親が台帳に居ない session である。picker の
孤児判定と同じく作業軸で決め、親のプロセスが gone なだけなら孤児にしない（resume すれば返信できる）。

`/clear` は session を終わらせ、別の session id で新しい session を始める。台帳は `/clear` された
旧 session を done にし、cascade で子も done にする（running の background 子は reconcile が止める）。
新しい session は委譲の文脈を引き継がないので、子の閉じ手はもう居ない。compact は session id を
変えないので、長く動く委譲元が compact を挟んでも link は切れない。
