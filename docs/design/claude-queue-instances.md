# claude-queue: プロセス（instance）の軸を独立して持つ

## 目的

claude-queue の台帳は session の状態を作業の軸（`done_at`）とプロセスの軸（`terminated_at`）に
分けている（[claude-queue-lifecycle.md](claude-queue-lifecycle.md)「状態モデル」）。ところがプロセスの
軸は session ごとに 1 つの値で、`sessions.tmux_pane` と `terminated_at` を 1 個ずつしか持たない。
同じ session id を握る claude プロセスは実際には 0〜N 個ありうるので、2 個目が現れるとこの表現が破れる。

典型は、ある pane で resume したまま放置した古いプロセスが残っている session を、別の pane で
もう一度 resume して作業を続けた場合である。古いプロセスを `/exit` で終えると、その `SessionEnd`
（`reason: prompt_input_exit`）が session 全体に効き、次の 3 つが同時に起きる。

1. `internal/hook/dispatch.go` の `doneReasons` により done が付き、picker の一覧から消える。新しい
   プロセスはまだ生きていて作業も続いている
2. `terminated_at` が立ち、gone になる（新しいプロセスが生きているのに）
3. 新しいプロセスの後に古い側の hook が `upsertSession` を通るので、`sessions.tmux_pane` が古い pane
   （既に存在しない）に上書きされ、生きている pane へ switch できなくなる

3 つとも「プロセスを session ごとに 1 つの値で持つ」1 点から生じる。この設計はプロセスの軸を
instance の集合として台帳に持たせ、gone・done・pane をそこから導く。

## instance 表

```
session_instances(session_id, instance_key, started_at, ended_at, end_reason)
  instance_key = pane id（interactive）／ pid（background）
```

1 つの claude プロセスが 1 つの session id を握っている期間を 1 instance とする。`ended_at` が NULL の
ものが開いている instance である。key を interactive で pane にするのは、picker の switch・休眠の
pane 閉鎖・`forcedEndSiblings` がどれも pane を単位に動くためで、background は pane を持たないので
pid にする。

### hook での遷移

- `SessionStart` は自分の key の instance を開く。同じ key で開いている instance（同じ pane に別の
  session が来た、または `SessionEnd` が届かずに同じ pane で同じ session が再開した）は先に閉じる。
  これが現在の `forcedEndSiblings` を置き換える
- `SessionStart` 以外の event も、自分の key の instance が開いていなければ開く。`SessionStart` が
  落ちる経路（hook の途中登録等）があるので、現在の `upsertSession` が全 event で `terminated_at` を
  消しているのと同じ理由で、生きた hook の到着そのものを instance が開いている証拠として扱う
- `SessionEnd` は自分の key の instance だけを閉じ、`end_reason` に `reason` を記録する

### 導出

- **gone**: 開いている instance が 0 個。`terminated_at` は保存せず `queue` view で計算する
- **終了による done**: `doneReasons` に当たる `SessionEnd`（と `/clear` による `forcedEndSiblings` の
  done、print 実行の終了）は、それが閉じた instance が最後の 1 個だったときだけ `done_at` を書く。
  他の instance が開いていれば作業の軸は動かさない。最後に閉じた instance の理由で決めるので、
  2 つのプロセスのうち古いほうを `/exit` し、新しいほうを後で `/exit` すれば、後者の時点で done になる
- **pane**: 開いている instance のうち `started_at` が最新のものの pane。gone の session は開いている
  instance を持たないので pane も持たない。現在の `queue` view が gone の session から `tmux_pane` を
  隠している理由（記録に残った古い pane id が、再起動後の別 pane と衝突する）は、この導出で構造的に
  満たされる

作業の軸の規則（done にするのは明示的な操作だけ、reopen でだけ戻る、cascade）は
[claude-queue-lifecycle.md](claude-queue-lifecycle.md) のまま変えない。この設計が変えるのは、終了 event を
作業の軸へ渡す条件だけである。

### reconcile

`internal/reconcile` は、開いている instance を、その session の config dir の `claude agents` の一覧と
instance 単位で突き合わせ、一覧に対応するプロセスが居ない instance を閉じる。background は pid の
一致で、interactive は一覧の pid から pane を引いて（`internal/sessionproc` の `PaneForSession` と同じ
経路）key と比べる。一覧が読めない config dir の instance は閉じない、という現在の保守側の規則は
instance 単位でも同じで、interactive の pane が引けない（tmux server に届かない）場合も読めない側に
倒す。休眠・`claude-stop-bg` がプロセスを止めた結果も、`SessionEnd` か reconcile で該当 instance が
閉じることで台帳に入る。

## 重複の可視化

`SessionStart` で instance を開いた時点で、同じ session に他の開いている instance があれば、hook から
警告を出す。picker の一覧にも、開いている instance が 2 個以上の session に印を付ける。

picker の resume には既に重複チェックがある（`internal/picker/picker.go` の `DecideAction`。
`claude agents` の一覧に同じ session id が 2 件以上あれば、どのプロセスを止めるか決められないので
何もしない）。これも同じ instance 表を参照させ、「重複している」の判定を台帳の 1 箇所にまとめる。
picker は起動時に reconcile を回すので、resume の判定時点で表は一覧と揃っている。止める対象の pid は
従来どおり `claude agents` の一覧から取る。

Claude Code 側では、同じ session の transcript を 2 つのプロセスが書くと、後から終えた側の書き込みが
resume の起点を古い時点へ戻すことがある（終了時に transcript 末尾へ書かれる `last-prompt` の
`leafUuid` が、そのプロセスが resume した時点のエントリを指す。resume がこの leaf を使う点は推定で、
未検証）。これは claude-queue の外の挙動で直せない。claude-queue にできるのは、上の警告で 2 重化に
早く気づかせることまでである。

## 移行

既存の session ごとに次のとおり instance を作る。

- `terminated_at` が NULL（running）: `tmux_pane` を key に、開いている instance を 1 個作る。
  `tmux_pane` が NULL のもの（background、tmux 外の interactive）は、pid が分からないので仮の key で
  作り、次の reconcile で閉じるか、次の hook event が本来の key で開き直すのに任せる
- `terminated_at` が非 NULL（gone）: 開いている instance を作らない。gone は導出で再現される

移行後は `terminated_at` と `tmux_pane` を書かず、読む側（`queue` view、`LiveSessions`、
`idx_sessions_pane_live` など）を instance 表へ移す。列そのものを落とすかは実装に任せる。

## 却下案: `SessionEnd` の hook で `claude agents` の一覧を引く

`SessionEnd` の hook で `claude agents` の一覧を読み、同じ session id の別プロセスが居れば done を
付けない、という局所修正は採らない。hook はすべての event の hot path にあり、そこへ外部プロセスの
起動を入れることになる。さらにこれで止まるのは症状 1 だけで、`terminated_at` が立つこと（症状 2）と
`tmux_pane` が古い pane を指すこと（症状 3）は残る。

## 実装者に任せること

- hook が background の pid（claude 本体のもの）を得る方法と、tmux 外の interactive の key
- hook の警告の出し方と、picker の印の字形
- `end_reason` を移行で埋めるか、移行後の instance だけに持たせるか
