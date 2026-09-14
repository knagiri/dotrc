# claude-queue: 委譲の親子関係と孤児 session

## 目的

`delegate-to-worktree` / `bin/claude-worktree` は委譲元 session から委譲先 session を起こす。その
親子関係を claude-queue に記録し、picker（`C-q q` / `C-q Q`）で木として表示する。あわせて、親を
失った background session（孤児）を picker で見分けられるようにし、`bin/claude-reap-bg` が拾える
ようにする。

委譲先は完遂しても `idle` のまま残り、一次経路では委譲元が `claude-stop-bg` で閉じる
（`dot/claude/rules/worktree-scope.md` §6）。委譲元が先に消えるとこの経路は構造的にもう発火せず、
委譲先は約 60 分居座る。親子関係が無いと、この状態を外から判別できない。

## スコープ外

- `claude-worktree --tmux` 経路。interactive claude は pane の中で自分の session id を採番する
  ので、起動時点で子の id が分からない
- 記録を始める前に起動した session の backfill。親を記録していない session はすべて root として扱う
- 孤児の自動停止。無人の session killer は作らない（`worktree-scope.md` §8）

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

GC は `created_at` が GC 期限より古く、かつ子が生きていない link を消す。子の行を基準に消さないのは、
子の行が一度も書かれない場合があるため。

## 表示（picker）

木の順を主にし、priority は兄弟間の順序にだけ効かせる。`q` と `Q` の両方に適用する。

1. 生きている行を全状態で読み、state filter（`--show-working` / `--show-stale`）を通った行を残す
2. 残した行の祖先を `parent_session_id` で辿り、生きている行に在れば加える。**祖先には state filter
   を掛けない**。`q` は `working` を隠すが委譲中の親はたいてい `working` なので、掛けると木が崩れる
3. repo-scope（`--repo-scope`）を掛ける。これは祖先の引き戻しより後で、戻さない
4. 森を組み、兄弟（root 同士を含む）を「部分木の最小 priority 昇順 → 部分木の最大 `created_at`
   降順 → session id 昇順」で並べる。承認待ちの子がいれば親ごと上に来る
5. `--show-resumable` の行は木の末尾に平坦なまま足す

罫線は `tree` と同じ形で、title 列の先頭に付ける。列を増やさないので非表示列の位置は変わらず、
title は prefix の幅を引いた残りで切り詰める。

### 親が一覧に居ない root

| 状態 | 印（emoji / ASCII） |
|---|---|
| link が無い（`parent_session_id` が NULL） | なし |
| 親は生きているが一覧に居ない（repo-scope で除外された等） | `↑` / `^` |
| 親が生きていない（terminated、または GC 済みで行が無い） | `✂` / `x`（孤児） |

NULL は「記録が無い」だけで、親が居ないことを意味しない。この 3 つを混同すると、backfill していない
既存 session がすべて孤児に見える。

生死は ledger（`terminated_at IS NULL`）で判定する。picker は起動時に reconcile するので ledger は
roster とほぼ一致する。reconcile や生死の読み出しに失敗したときは親を生きているとみなし、孤児の印を
出さない側に倒す。

link の循環は `claude-worktree` からは生じないが、テーブルは禁じていない。session id 順に祖先を上り、
既に訪れた id へ戻る link を切って root にする。

## reap（`bin/claude-reap-bg`）

孤児 = link が在り、かつ roster のどの entry の `sessionId` も親と一致しない session。pid の無い
stale job record も「居る」に数え、判定を保守側に倒す。

`/clear` は session を終わらせ、別の session id で新しい session を始める。委譲元が `/clear` すると
その子は ledger でも roster でも親を失って孤児になる。新しい session は子の報告を受け取らず、子を
閉じることもないので、閉じ手が居ないという孤児の状態に合う。compact は session id を変えないので、
長く動く委譲元が compact を挟んでも link は切れない。

`SendMessage` gate は委譲元へ質問して返信待ちの委譲先を殺さないためにある。委譲元が消えていれば
その返信は来ないので、孤児に限りこの gate と、それが前提にしている transcript の存在・parse の検査を
省く。roster の bg + idle、queue の `idle_done` と `--idle-minutes` の閾値、`claude-stop-bg` 経由の
停止は孤児でも変えない。report には `orphan: parent <親の先頭 8 桁> gone` を添える。

`session_links` が読めない（テーブルが無い古い DB を含む）ときは警告を出し、link が無い場合と同じ
挙動で続ける。
