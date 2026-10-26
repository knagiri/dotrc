# claude-queue: session のライフサイクル再設計

## 目的

claude-queue の台帳は、session の「プロセスが生きているか」と「作業が終わったか」を
`sessions.terminated_at` の 1 本で表している。ホスト再起動・`/clear`・background の自然消滅は
プロセスが消えただけで作業は終わっていないが、いずれも `terminated_at` が立ち、一覧から外れる。
pin（`waiting_event_id`）は最新 event に紐づくので終了 event で外れ、resumable 一覧は親子関係も
pin も運ばない。閉じてから 7 日で GC が session の記録ごと消すので、再起動で閉じた WIP はそのまま失われる。

同時に、interactive の WIP が数十本並んで管理しきれず、外部待ち（他メンバーの review・作業）の
文脈と、それが解けたときの再開が人手に依存している。常駐する claude プロセスは 1 本あたり
300〜450MB を使い、数十本で十数 GB になる。

この設計は session の状態を 2 軸に分け、作業の終わりを利用者の明示的な操作だけに限る。そのうえで
メモ・pin・休眠・PR 監視による自動再開を載せる。

## 目標

- 再起動後も、open な session・pin・メモ・親子関係が一覧にそのまま残り、選べば resume できる
- 作業の完了は利用者（または委譲元）が明示的に決める。自動判定しない
- どの session にも短いメモを残せ、picker で曖昧検索できる
- pin は外部待ちのコメントを持ち、PR に関する待ちは状態変化を検知して委譲元を自動で起こす
- しばらく動いていない session はプロセスを止めてメモリを返す。作業は open のまま

## 非目標・アンチゴール

- 優先度の項目は持たない。並べ替えの判断は利用者がメモを見て行う
- PR 以外の外部待ち（人の作業待ち等）の自動検知はしない。コメントだけ付け、再開は手動
- webhook は使わない。手元のマシンに公開の受け口を置かない
- 推測で作業を完了扱いにしてはならない。idle が長い・roster に居ない・`SessionEnd` が来た、は
  どれも作業完了の根拠にならない。これを破ると、生きた WIP が一覧から黙って消える現状に戻る
- 返信待ちの session（委譲元へ `SendMessage` で質問中の委譲先、`awaiting_approval` 中の session）を
  休眠させてはならない。止めると返信や承認の受け手が居なくなる

## 状態モデル

session は kind（`interactive` / `background`）を持ち、状態は独立した 2 軸で表す。

| 軸 | 値 | 誰が決めるか |
|---|---|---|
| 作業 | `open` → `done`（一方向） | 利用者・委譲元の明示的な操作だけ |
| プロセス | `running` ↔ `gone` | 観測（hook・roster）と休眠 |

既存の hook 由来の state（`working` / `awaiting_approval` / `idle_done`）は `running` の中の細分として
そのまま残る。メモ・pin・親子関係は `open` の間、プロセス軸がどう動いても消えない。

### `done` への遷移

| kind | トリガー |
|---|---|
| interactive | `SessionEnd` の `reason: prompt_input_exit`（Ctrl-C / `/exit`） |
| interactive | picker からの完了操作 |
| interactive | `/clear`（古い session id が `done` になる。利用者は別作業を新しい session で始める運用なので、`/clear` は完了とみなす） |
| background | `claude-stop-bg` で閉じたとき。`claude stop` 由来の `SessionEnd` は `reason: other` で再起動時の SIGTERM と区別できないので、`claude-stop-bg` が台帳へ完了を書き、roster に居れば続けて stop する（休眠で既に `gone` の子にも効くよう、roster に居ないことを拒否理由にしない） |
| 非対話（`claude -p` 等） | プロセス終了時に常に `done`。一回きりの実行で、再開する WIP ではない |
| 両方 | 親が `done` になったとき（cascade。下記） |

### `gone` への遷移（作業は `open` のまま）

- `SessionEnd` の `reason` が `prompt_input_exit` 以外（ホスト停止の SIGTERM 等）
- roster に居ない（reconcile。background の約 60 分後の自然消滅を含む）
- 休眠
- 既存の `ForcedEnd` 経路（同 pane の新 session、picker の switch 失敗）のうち、`/clear` 以外

`gone` → `running` は resume（利用者の選択、または PR 監視による自動再開）で起き、同じ session id で
hook が再び届いた時点で記録される。

### 親子関係と cascade

- 親が `done` になったら、その子をすべて `done` にし、`running` の子はプロセスも止める
- 親が `gone` になっただけでは子に何もしない。親を resume すれば関係ごと戻る
- 取り残し（親が `done` なのに `open` の子）は、cascade の失敗の後始末として自動で `done` にする。
  判定に推測が入らないので無人で回してよい
- `session_links` は親子のどちらかが `open` の間は GC しない

## 休眠

`running` で一定時間動きのない session のプロセスを止め、`gone` にする。

- 対象: 最新 state が `idle_done` で、そこから閾値以上経っている session。interactive・background の両方
- 除外: `working` / `awaiting_approval`、最後の assistant ターンに `SendMessage` がある session
  （返信待ち）。ただし親が `done` の孤児は返信が来ないので除外しない
- interactive は claude プロセスを終了し、その tmux pane も閉じる（window の最後の pane なら window
  ごと）。再開時は picker / 自動再開が新しい window を開くので、shell に戻った pane は不要になる
- background は `claude stop` で止める。この経路では作業を `done` にしない（`claude-stop-bg` の
  完了記録とは別の入口にする）

`bin/claude-reap-bg` は廃止する。取り残された記録の掃除は `open / gone` が正規の状態になることで不要になり、
居座るプロセスの停止は休眠が担う。reap のゲート（idle、`idle_done` からの経過、`SendMessage`、
孤児の例外）は休眠の除外条件に引き継ぐ。

## メモと pin

**メモ**: どの session にも 1 本の短い自由文を付けられる。picker の一覧に表示し、fzf の曖昧検索の
対象に含める。picker 上で編集でき、CLI からも設定できる（agent が自分の session に付けられるように）。

**pin**: 「外部待ち」の印。コメント（自由文）と、任意で PR の監視条件を持つ。現在の待ちマークは
次の hook event で自動的に外れるが、新しい pin は明示的に外すか、PR 監視が委譲元を起こすまで残る。
外部待ちの間も、催促などで利用者や agent が session に触れることがあるため。pin は表示上の印であり、
一覧の並び順は変えない。

pin は picker から利用者が付けるほか、CLI で agent が自分の session に付けられる。

## PR 監視と自動再開

窓口は委譲元（interactive）に集約する。委譲先は実装 → agent / bot の review → 修正を終えて委譲元へ
完了を報告し、報告を受けた委譲元が「PR の人による review 待ち」の pin を自分に付ける。人の review・
修正指示の受け口も委譲元なので、起こす相手は常に pin を付けた session になる。

`systemd-user` の timer が数分おきに監視コマンドを 1 回起動し（常駐はしない）、PR 監視条件付きの
pin について GitHub の PR を確認する。pin は既読位置（cursor）を持ち、それより新しい活動があれば
その session を起こして指示を渡し、cursor を進める。bot の review も人の review も同じく起こす対象で、
pin は merge / close まで残る。PR が閉じるまで「活動 → 委譲元が対応 → 休眠 → 次の活動」のループを
回すためである。bot の review はコメントが連続して付くので、最後の活動から 1 tick 経ってから
まとめて 1 回配送する。

| PR の変化 | 委譲元への指示 |
|---|---|
| PR author 以外の review / comment（bot を含む） | 内容を読み、修正の要否を判断する |
| merge | 次の作業を整理する（pin を外す） |
| merge なしの close | 状況を確認する（pin を外す） |

起こし方は session のプロセス状態で分かれる。

| 状態 | 配送 |
|---|---|
| `gone`（interactive） | 新しい tmux window で `claude --resume <id> "<指示文>"`。同じ session id で REPL が開き、指示文が最初の入力として処理される |
| `gone`（background） | `claude --bg --resume <id> "<指示文>"`。同じ id・同じ会話のまま background で再開する |
| `running` で `idle_done`（interactive） | pane へ `tmux send-keys` で指示文と Enter を送る。入力欄に打ちかけの文字列があると連結されて送信されるので、入力欄が空でなければ配送せず次の tick に回す |
| `running` で `working` / `awaiting_approval` | 割り込まず次の tick に回す |

`running` な session へ外からメッセージを渡す CLI は claude に無いので、interactive は `send-keys`
に頼る。window の置き場所と名前は picker の resume と同じ規約に従う。timer には popup を開いたクライアントが無いので、window は session の cwd が
属する repo の正準名の tmux session（`<main-repo-basename>_<name>` と同じ規約で決まる名前）に開き、
無ければ detached で作る。tmux server 自体が無いときも同様に起動する。起きた session は通常の hook で state を更新するので、人の判断が要る場面は
`awaiting_approval` / `idle_done` として一覧に上がる。自動再開専用の通知は作らない。

GitHub への問い合わせは既存の `gh-*` wrapper と同じ token 経路を使う（`bin/lib/gh-mise.sh`）。

systemd user unit は shell の環境を引き継がないので、PATH は `claude-digest.service` と同じく明示し、
claude を起動するときの `CLAUDE_CONFIG_DIR` は 台帳に記録された session の config dir から決める（`internal/configdir`）。
`Type=oneshot` の service が起動した子プロセスは、既定（`KillMode=control-group`）では service の
終了とともに殺される。監視コマンドが tmux server・claude・background daemon を新たに立ち上げる場合は、
それらを service の cgroup の外へ出す（`systemd-run --user --scope` 等）か `KillMode` を変える。

## 一覧と GC

- picker の既定一覧は `open` な session。`gone` は 💤 で区別し、選べば resume する。`done` は出さない
- 現在の `--show-resumable` の役割（終了済みから resume 候補を拾い直す）は、`open / gone` が既定一覧に
  載ることで吸収される
- GC は `done` になってから 7 日経った session だけを削除する。`gone` は期間に関わらず消さない

## 移行

既存 DB の閉じた session は次のように振り分ける。

- 直近 7 日以内に閉じ、終了理由が `prompt_input_exit` / `clear` 以外のもの → `open / gone`
- 同 pane の新 session による `ForcedEnd` は、その新 session の `SessionStart` が `source: clear` なら
  `/clear` とみなして `done`、それ以外は上の規則に従う
- それ以外 → `done`
- `waiting_event_id` を持つ session → pin（コメントは空）に変換する

## 実装者に任せること

- 台帳のスキーマ（作業軸・kind・メモ・pin の持ち方）と、既存の `terminated_at` / `ForcedEnd` の扱い
- 休眠の閾値（既定値は 2 時間を想定。設定で変えられること）と、監視 timer の間隔
- `running` な background へメッセージを渡す手段（委譲元からの `SendMessage` 以外の経路が要るか）
- interactive の入力欄が空かどうかの判定方法（`tmux capture-pane` の読み取り等）
- agent が CLI で自分の session id を解決する方法
- picker のキー割り当て（メモ編集・pin・完了）
- 休眠・自動再開・cascade の各処理を、監視コマンドと picker 起動時のどちらで回すか
- 既存の stale 判定（🧟）を残すかどうか。休眠により長時間 idle の `running` は減るので、残るのは
  `working` のまま動かないものが主になる
