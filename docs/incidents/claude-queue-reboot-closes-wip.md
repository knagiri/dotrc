# ホスト再起動で WIP の session が claude-queue の一覧から消えた

## 経緯

ホストを停止して再起動したあと、作業途中だった interactive / background の session が
claude-queue の picker から一斉に消えた。台帳（`sessions`）は「プロセスが生きているか」と
「作業が終わったか」を `terminated_at` の 1 本で表しており、停止時の SIGTERM で届いた
`SessionEnd` と、その後 picker を開いたときの reconcile（`claude agents` の一覧に居ない session を
閉じる）が、どちらも `terminated_at` を立てた。閉じた session は一覧から外れ、7 日で GC される。
pin（待ちマーク）と親子関係も一緒に失われ、再開するには transcript を手で探すしかなかった。

`SessionEnd` の `reason` で「本当に終えた」を見分けることもできなかった。

## 実行したコマンドと観測

台帳を読み取り専用で開き、終了 event を種類・reason・分単位の時刻で集計した（5 件以上の塊だけ）。

```
$ sqlite3 -readonly ~/.claude/session-queue.db "SELECT event_type, json_extract(payload,'$.reason') r, date(created_at,'unixepoch','localtime') d, strftime('%H:%M',created_at,'unixepoch','localtime') hm, COUNT(*) n FROM events WHERE state='ended' GROUP BY event_type, r, d, hm HAVING n >= 5 ORDER BY d, hm;"
SessionEnd|other|2026-10-23|20:00|42
ForcedEnd||2026-10-26|12:12|10
```

1 行目がホスト停止の時刻で、`reason: other` の `SessionEnd` が 1 分の間に 42 件届いている。
2 行目はその 3 日後に picker を開いた時刻で、reconcile の `ForcedEnd` が 10 件。
（第 1 部の着手時に委譲元が同じ観点で集計したときは 40 件・9 件だった。集計の切り方の違いで、
傾向は変わらない。）

`SessionEnd` の reason の全件集計:

```
$ sqlite3 -readonly ~/.claude/session-queue.db "SELECT json_extract(payload,'$.reason') r, COUNT(*) FROM events WHERE event_type='SessionEnd' GROUP BY r ORDER BY 2 DESC;"
other|136
prompt_input_exit|80
logout|1
```

`other` が最多で、ホスト停止以外も含む。委譲元が使い捨て session で確かめたところ、`claude -p` の
終了・`claude stop`・tmux の pane の kill もすべて `other` になった（この確認はこの PR では
再現していない）。したがって `reason` からはプロセスが消えた理由を区別できない。

## 原因と直し方

原因は、台帳が `terminated_at` 1 本でプロセスの終了と作業の完了を兼ねていたこと。プロセスが
消えたことは作業が終わった根拠にならない。

- 第 1 部: 作業軸（`done_at`）を足し、プロセス軸（`terminated_at`）と分けた。done にするのは
  `/exit`・`/clear`・`claude-stop-bg`・picker の完了操作など明示的な操作と、親からの cascade だけで、
  それ以外の終了は gone（作業は open のまま一覧に残る）にした
- 第 3 部（休眠）: idle の session のプロセスを `claude-queue watch` が止める。止めても gone に
  なるだけで作業は残る。これに伴い、居座る委譲先を止めていた `bin/claude-reap-bg` を廃止した

設計は `docs/design/claude-queue-lifecycle.md`。

## 反映した規約

- `dot/claude/rules/worktree-scope.md` §6（委譲元が `claude-stop-bg` で閉じる理由を「作業を done に
  する明示的な操作だから」にした）と §8（`claude-reap-bg` の節を休眠の節に置き換えた）
- `dot/claude/skills/delegate-to-worktree/SKILL.md` 手順 6
