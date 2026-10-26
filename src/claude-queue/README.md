# claude-queue

複数の Claude Code セッション (tmux pane 毎) を横断して現在状態をキュー化し、
tmux popup + fzf picker で該当 pane にジャンプするための Go CLI。

**Status:** v0.1 MVP。subagent 追跡 / dismiss / preview は v0.3 予定。

## Dependencies

- Go 1.22+（ビルド時）
- SQLite は `modernc.org/sqlite` に同梱、CGO 不要
- ランタイム: `tmux` 3.2+, `fzf`

## Multiplexer 抽象

`internal/multiplexer` パッケージで terminal multiplexer 差を吸収する
`Multiplexer` interface を定義。v0.1 では tmux 実装のみ（`TMUX` 環境変数
検知で自動選択）。Zellij 等を追加する場合は `zellij.go` を足して `Detect()`
に分岐追加するだけで hook / picker 側のコードは変更不要。

ただし **Zellij 移行には別途**：(1) status bar 表示は WASM plugin 必須、
(2) popup / keybind は `config.kdl` で書き換え、という multiplexer 外の
作業が発生する。

## Install

```
cd src/claude-queue
make install
```

バイナリは `<repo-root>/bin/claude-queue` に作られる。`bin/` はリポジトリの
`rc/bashrc` 経由で既に PATH に入っているため、インストール後は即利用可。
`bin/claude-queue` は `.gitignore` 対象、`make install` で都度ビルドする。

## Subcommands

| コマンド | 用途 |
|---|---|
| `claude-queue hook <event>` | stdin JSON を受け取り SQLite に状態書き込み（Claude Code hook 経由で呼ばれる） |
| `claude-queue status` | tmux status-right 用のカウンタ文字列を stdout に出力 |
| `claude-queue picker` | fzf を popup で起動し、選択 session へ到達する（到達手段の決定は後述）。`--show-working` / `--show-stale` で一覧を広げる。キー操作は「pin とメモ」と「session の状態」の節を参照。`--show-resumable` は受け付けるが何もしない（gone は既定で並ぶ） |
| `claude-queue reconcile` | `claude agents --json` に載っていない running の session を gone にし、done なのに running な background session を `claude stop` する（picker 起動時に自動実行される） |
| `claude-queue watch [--idle-minutes N] [--pr-debounce-minutes M] [--dry-run]` | 無人の定期処理を 1 回行う。reconcile、PR 監視（pin の PR に新しい活動があれば session を起こす。後述）のあと、`idle_done` から N 分（既定 120）以上動いていない session のプロセスを止める（休眠。作業は open のまま gone になる）。`dot/systemd-user/claude-queue-watch.timer` が 3 分おきに起動する。止めたもの・skip とその理由を 1 行ずつ出し、exit は常に 0（DB を開けないときだけ 1）。`--dry-run` は reconcile も PR 監視も停止もせず、休眠の対象を出すだけ（後述） |
| `claude-queue reset [--force]` | DB (`~/.claude/session-queue.db`) を削除、対話 y/N |
| `claude-queue link --parent <session-id> --child <short-id>` | 委譲の親子関係を記録する（`bin/claude-worktree` の bg 経路が呼ぶ）。picker の木表示と孤児の判定に使う。設計は `docs/design/claude-queue-session-tree.md` |
| `claude-queue mark <session-id>` | pin をトグルする（picker の Tab が呼ぶ）。外すと pin のコメントも消える。done・未知の session は何もせず exit 0 |
| `claude-queue memo [--session <id>] [--] [<text>]` | session のメモを設定する。`<text>` を省くと現在のメモを出力し、空文字を渡すと消す |
| `claude-queue pin [--session <id>] [--note <text>] [--pr <owner/repo#N \| PR URL>]` | pin を立てる。`--note` を渡すとコメントを置き換え（空文字で消す）、省くと既存のコメントを残す。`--pr` を渡すとその PR を監視する（既読位置は今の時刻から。後述の「PR 監視」） |
| `claude-queue unpin [--session <id>]` | pin とそのコメント・PR 監視を外す |
| `claude-queue done <session-id-or-prefix>` | session の作業を done にする（委譲先も cascade で done）。picker の `ctrl-x` と `bin/claude-stop-bg` が呼ぶ。8 桁以上の前方一致で 1 件に決まらなければ exit 1。既に done でも exit 0 |
| `claude-queue --version` | バージョン表示 |

`memo` / `pin` / `unpin` は `--session`（8 桁以上の前方一致）を省くと `CLAUDE_CODE_SESSION_ID` を使う。Claude Code は
hook と Bash tool の環境にその session の id を入れるので、agent は id を知らずに自分の session へ書ける
（例: `claude-queue pin --note "<待っているもの>"`）。どちらも無いとき、id が 1 件に決まらないとき、done の
session に書こうとしたときは exit 1 で、理由を stderr に出す。

### 環境変数

| Var | 意味 |
|---|---|
| `CLAUDE_QUEUE_DB` | DB パス override（既定 `~/.claude/session-queue.db`） |
| `CLAUDE_QUEUE_ASCII=1` | アイコンを ASCII フォールバック `[!] [.] [*] [X] [~]`（pin は `[P]`、メモは `[M]`）に切替 |
| `CLAUDE_QUEUE_DEBUG=1` | エラーを `~/.claude/session-queue.log` に追記 |

### picker の行

行は tab 区切りで、fzf に見せるのは 1〜5 列と 11 列だけ（`--with-nth`）。fzf は見せている列だけを検索する。

| 列 | 中身 | 幅 |
|---|---|---|
| 1 | state アイコン（pin 中は 📌） | 可変（1〜2 桁） |
| 2 | 現在 session の印・委譲の木の罫線・孤児の印 + ai-title（transcript 由来） | 40 桁 padding + truncate（印・罫線込み） |
| 3 | worktree 名（`<main-repo-basename>_<name>`。メイン checkout は `<repo>` のみ） | 56 桁 padding + truncate |
| 4 | age | 可変（短い） |
| 5 | summary（何で止まっているか） | padding なし。payload 由来は 150 桁で truncate |
| 6〜10 | session_id / tmux_pane / cwd / transcript_path / config_dir | 非表示 |
| 11 | 注記（`📌 <pin のコメント>` と `📝 <メモ>`） | padding なし |
| 12〜13 | メモ / pin のコメント（編集キーの初期値） | 非表示 |

3 列目は cwd の git toplevel basename そのままではなく、`--git-common-dir`（絶対）の親を
メイン toplevel として `<main-repo-basename>_<name>` を合成する。worktree は
`<repo>/.worktrees/<name>` にあり dir basename が `<name>` だけなので、そのままでは repo 名が
落ちるため。メイン checkout（common-dir の親 == 自分の toplevel）は接尾辞を付けず `<repo>` だけ。
合成するのは `<メイン toplevel>/.worktrees/<name>` 直下の worktree だけで、それ以外の場所に
ある linked worktree（sibling layout の `<parent>/dotrc_foo` や手製の `../scratch`）は自分の
dir basename のまま。無条件に合成すると前者が `dotrc_dotrc_foo` になり、picker が
has-session を外して二重に session を作るため（1 worktree = 1 session が壊れる）。
git が引けない cwd は cwd の basename に落ちる。

ai-title を worktree 名より前に置くのは、同じ repo に複数 session が並ぶと worktree 名は全部
同じで summary も全部 `working` になり、「何の作業か」を言えるのが title だけになるため。
padding と truncate は表示幅（全角 2 桁）で数える — 日本語タイトルが多数派なので、バイト数
基準の `%-40s` では列が揃わない。行は tab 区切りのまま fzf に渡り、fzf 既定の `--tabstop=8` で
展開されるので、2〜4 列目は 8 / 56 / 120 桁から始まる（padding 幅の 1+40+56 ではなく、各列の
末尾で次の 8 の倍数まで送られるため）。popup は client 幅の 80%（実測 ~290 桁）あるので、
summary が 150 桁使ってもなお収まる。

ai-title は window 名と同じ transcript から取るが、**別関数**（`label.DisplayTitle`）で作る。
window 名側の 16 桁切りと `-<id8>` 付与、`.` `:` `~` `#` の置換は tmux の `-t` target 構文と
FORMATS 展開のための処理で、読むだけの行には要らない。ただし `\t` `\n` `\r` だけは title 側でも
summary 側でも必ず潰す（メモと pin のコメントは保存時に潰す） — 混ざると 6 列目以降がずれ、picker が別 session の id / pane / cwd /
transcript を掴む。tab を含む Bash コマンド（`awk -F'<tab>'`）は承認待ちで普通に出るので、
これは机上の話ではない。

popup を開いた pane で動いている session の row には、2 列目の先頭（罫線より前）に `▶ `
（`CLAUDE_QUEUE_ASCII=1` では `> `）が付く。判定は ledger の `tmux_pane` が popup を開いた時点の
pane と一致するかだけで、background session や `claude attach` で入った pane には付かない。
state アイコンは置き換えないので、現在の session の state も 1 列目で読める。pane は
interactive 起動時に 1 度だけ取り、Tab の再描画（`--list`）へは `--current-pane` で渡す。

11 列目が 6〜10 列目より後ろにあるのは、後から足した列で既存の隠し列の位置を動かさないため。

### pin とメモ

pin は「外部待ち」の印で、人の返信待ち・保留・後回しにした session に付ける。メモはどの session にも
付けられる 1 行の自由文。どちらも 11 列目に出るので、fzf の曖昧検索で引ける。

| キー | 操作 |
|---|---|
| `tab` | pin の付け外し。外すとコメントも消える |
| `ctrl-t` | pin のコメントを 1 行編集する。保存すると pin も立つ |
| `ctrl-e` | メモを 1 行編集する。空にして保存すると消える |
| `ctrl-x` | done にする。`y` 以外を押すと何もしない。失敗したら理由を出し、キー入力を待つ |

編集は現在の値を初期値にした readline で、`Ctrl-U` で行を空にしてから `Ctrl-D` で取り消す（行が空でない間の `Ctrl-D` は 1 文字削除になる）。空のまま Enter すると消去になる。`-` で始まるメモも保存できる。保存したテキストのタブと改行は空白に
潰す。agent は CLI（`claude-queue pin` / `memo`）で自分の session に付けられる。

いずれのキーでも popup は閉じず、`picker --list`（同じ flag で行だけを出すモード）で一覧をその場で再描画する。
pin が変えるのはアイコンだけで、並び順・state・priority・age・summary は変えない。別グループに
すると並びが動いて行を見失うため。stale 判定も変えないので、印の付いた session も時間が
経てば既定の picker から消え、`--show-stale` では 📌 のまま見える。tmux status-right の
カウンタは pin を数えない。

pin（`sessions.waiting_event_id` が非 NULL）は明示的に外すまで残り、gone の session にも付けられる。
外部待ちの間も催促などで session に触れることがあり、そのたびに外れては pin の意味が無いため。
done の session には pin もメモも書けない（一覧に出ないので、書いても見えない）。

### session の状態（作業とプロセスの 2 軸）

台帳は session ごとに、作業（`done_at`。NULL が open）とプロセス（`terminated_at`。NULL が
running、非 NULL が gone）を別々に持つ。picker の既定一覧は open な session で、gone は 💤
（`[~]`）・summary `gone (was <直前の state>)` で running の後ろに並ぶ。直前の state が
`working` / `awaiting_approval` のもの（作業途中で落ちた可能性が高い）が先。選べば上の到達手段で
resume する。done は一覧に出ない。設計は
[docs/design/claude-queue-lifecycle.md](../../docs/design/claude-queue-lifecycle.md)。

done にするのは次だけで、idle の長さ・`claude agents` の一覧に居ないこと・`reason: other` の `SessionEnd` は
根拠にしない（いずれもホスト再起動と区別できないため）。

- `SessionEnd` の `reason` が `prompt_input_exit`（Ctrl-C / `/exit`）または `clear`
- `/clear` で同 pane に新 session が始まったとき（`SessionStart` の `source: clear`）の旧 session
- print mode（`claude -p`）の session の終了
- `claude-queue done`（picker の `ctrl-x`、`bin/claude-stop-bg`）
- 親が done になったときの子孫（`session_links` を辿る cascade）

done は一方向で、後続の hook event（resume 等）でも戻らない。gone は同じ session id の hook が
届いた時点で running に戻る。kind（`interactive` / `background` / `print`）は hook の環境変数
（`CLAUDE_JOB_DIR` / `CLAUDE_CODE_ENTRYPOINT`）で決める。`SessionEnd` の `reason` は
`claude -p` の終了・`claude stop`・pane の kill・ホスト停止のいずれも `other` で、kind を区別
できないため。

gone の session は `tmux_pane` を運ばない（view が NULL にする）。ledger はこの列を終了時に
クリアせず持ち回るため、gone の pane は必ず「終わったプロセスの pane」であり、pane id は server
単位のカウンタで新しい server は `%0` から振り直すので、再起動後は無関係な live pane に衝突する。
transcript / cwd の実在は選んだ時点で確かめ、欠けていれば理由を出す（後述の到達手段 5）。

### picker の到達手段

選択された session への到達手段を次の順で決める。

1. **到達できる pane があれば `tmux switch-client`**。roster に該当 session があれば
   `claude agents --json` の pid からプロセス祖先を辿って pane を解決する（identity 込みの
   確認）。ただしこの祖先辿りは interactive な roster entry にだけ適用する。background agent は
   ホスト共有の `claude daemon run` が fork するため、daemon が pane の中から起きていると配下の
   全 background が無関係なその pane に解決されてしまう。よって background は pane を解決せず、
   必ず手順 2 の `claude attach` に落とす。ledger の `tmux_pane` を最後の手段として見るのは
   **roster を読めなかったときだけ**
   （roster は読めたが該当 session が無い場合は含まない — それはプロセス終了の証拠なので
   使わない）。pane id は server 単位のカウンタで新しい server は `%0` から振り直すため、
   実在するだけでは同一 session の pane だと確認したことにならない。switch が失敗しても row は
   terminate しない — 直前に確認したのは pane の実在（かつ可能なら identity）であって、失敗は
   switch 自体の問題（client 未接続等）であり session の死を意味しない
2. **background session は `claude attach <short-id>`**。その worktree の tmux session
   （無ければ作成）に window を開き、client をそこへ移す。承認待ちで止まった background
   委譲先へ入る経路はこれだけ
3. **pane に到達できない interactive session は `claude --resume <uuid>`**。`claude attach` は
   background 専用で、interactive に投げると `No job matching` で失敗する。resume は元プロセスを
   引き継がず別プロセスを立てるので、先にプロセスを終わらせる必要がある。終わらせてよいのは
   **その session の tmux server がもう誰からも到達できないと確定した場合だけ**。
   `/proc/<pid>/environ` の `TMUX=<socket>,<serverpid>,<n>` から socket と server pid を取り、
   (a) server pid が現行 server と異なり、(b) その socket の現在の所有者が記録された server pid
   ではない（別 server に置き換わっている、または socket 自体が無い）ことを確認する。tmux server は
   socket 単位なので、自分が switch-client できない server でも socket を持っていれば別端末から
   `tmux -L other attach` で使用中でありうる — 判断材料はプロセスの生死ではなく socket の所有者。
   `TMUX` が無い（tmux 外で起動）・`/proc` が読めない・socket を問い合わせられない等、確定できない
   ときは何もせず理由を出す。確定したときは SIGTERM を送り roster から消えるまで最大 10 秒待つ。
   消えなければ resume せず報告して終わる（SIGKILL へは上げない）。

   socket が置き換わる前から attach していた client は既存の接続で動き続けるが、その socket は
   もう別 server のものなので列挙する手段が無い。この残余リスクを取るのは、取らなければ会話が
   恒久的に到達不能になるため
4. **roster に居ない session はそのまま `claude --resume`**。止めるプロセスが無い
5. **resume は transcript と cwd が実在するときだけ行う**。存在しない uuid を `--resume` に
   渡してもエラーにならず、その id で空の新規 session が立ってしまう。短命 session は jsonl を
   書かないので `transcript_path` があってもファイルが無いことがあり、reap 済み worktree の
   session は cwd 側が消えている。どちらが欠けたかを stderr に出して終わる

session 名 = `<main-repo-basename>_<name>`（正準規約。`claude-worktree --tmux` と共有する）。
popup を開いた時点の current session には作らない。

window 名は session の transcript にある ai-title から `<タイトル 16 桁>-<session id 8 桁>` を
組む（取れなければ `attach-<id8>` / `resume-<id8>`）。picker 経由で開く window だけでなく、
pane を持つ追跡中の session の window も hook（`UserPromptSubmit` / `Stop`）が同じ名前へ
改名する。ただし改名するのは pane が window 唯一の pane のときだけで、`SessionEnd` では
自分が付けた名前のときに限り tmux の automatic-rename を戻す。設計上の理由は
[docs/design/claude-tmux-worktree.md](../../docs/design/claude-tmux-worktree.md) を参照。

window を開く attach / resume の経路では、`claude` をそのまま pane のプロセスにせず shell 経由で
走らせ、コマンドの exit status で終わり方を分ける。`claude attach` を意図して抜ける手段は
どれも exit 0 で終わり（外からの `claude stop`、UI で `/exit` してから agent view を `Esc` で
抜ける、`C-z`）、失敗系だけが非 0 になるので、この 2 つを取り違えずに分けられる。

- **正常終了（exit 0）**: その時点で window を表示している client だけを起動元 pane へ
  `switch-client -c` で戻し、pane が終了して window も閉じる。別の場所を見ている client は動かさない
  （外からの `claude stop` で終わったとき、別の pane で作業中のユーザーを引き戻さないため）。
  その window しか持たない session も一緒に消えるが、表示していた client は既に起動元へ移っているので影響しない。
  残った window はユーザーが手で閉じることになるので、閉じるのが既定
- **失敗（非 0）**: shell へ置き換えて pane を残し、エラーを読ませる。`tmux new-window` は中の
  コマンドの exit status を返さないので、window を閉じると失敗の理由ごと消える

UI の中で `/exit` しても `claude attach` は終わらず、agent view（`claude agents` と同じ session
一覧）へ戻る。そこから `Esc` で抜けると exit 0 で終了し、window が閉じて起動元 pane に戻る。

戻り先の pane が既に閉じていた場合は戻らず、window と（それしか持たない）session が消えるので
client は端末へ detach される。

失敗して残った window は `<元の名前>~exited` へ改名する。同じ対象を選び直したときの window
再利用は名前の一致で決まるので、改名しないと「claude が居ない shell だけの window」が名前を
握り続け、選び直しても `claude attach` が二度と走らなくなる。正常終了側で改名しないのは window が
閉じて名前ごと消えるためで、`~exited` window が溜まるのもこれで避けられる。

## State machine

| hook event | state |
|---|---|
| `SessionStart` | working |
| `UserPromptSubmit` | working |
| `PermissionRequest` | awaiting_approval |
| `PermissionDenied` / `PostToolUse` / `PostToolUseFailure` | working |
| `Stop` / `StopFailure` | idle_done |
| `SessionEnd` | ended（プロセス軸が gone になる。作業軸は上の規則による） |

Stale 閾値: working > 8h / awaiting_approval > 2h / idle_done > 4h 経過。

`gone` は view が `terminated_at` から導く擬似 state で、hook が書く state ではない。

## L3 自己修復

`/exit` `/clear` で `SessionEnd` が発火しないバグ対処：新規 `SessionStart`
時に **同一 `$TMUX_PANE` 上で生存中の他 session を `ForcedEnd`**（gone にする）。新 session の
`source` が `clear` のときだけ、旧 session を done にもする。

### 休眠（`claude-queue watch`）

常駐する claude プロセスのメモリを返すため、しばらく動いていない session のプロセスを止める。
作業は done にせず gone として一覧に残るので、選べば resume できる。止める条件はすべて満たすこと:
最新 state が `idle_done` でそこから閾値以上経っている、その config dir の `claude agents` の一覧で
`status` が `idle`、transcript の最後の assistant ターンに `SendMessage` が無い（委譲元が done または
台帳に居ない孤児はこの検査を省く）、running かつ open な委譲先を持たない。pin は妨げない。完了報告も
`SendMessage` なので、閉じ忘れた委譲先は委譲元が done になるまで休眠しない。

- interactive: pane の window が attach 中の client で表示中なら止めない。pane が見つからなければ
  止めない。SIGTERM を送り、一覧から 10 秒以内に消えたら pane を閉じる（window の最後の pane なら
  window ごと）。消えなければ pane は残して失敗として出す
- background: `claude stop` で止める

### PR 監視（`claude-queue watch`）

`claude-queue pin --pr <PR>` で PR を監視している open な session について、`gh api graphql` で PR の state と、直近 100 件ずつの
review / comment の種別・時刻・author が bot か（`__typename`）を読む。本文と login は読まない。gh は `bin/lib/gh-mise.sh` と同じく `MISE_ENV=gh mise exec -C <session の cwd> --` 経由で呼ぶ
（cwd が消えていれば `$HOME`）。gh が失敗した pin は skip して理由を出し、他の pin は続ける。

- 既読位置（`pin_cursor`）より新しい review / comment は、author を問わず数える。最初に見た pass では記録だけして、
  `--pr-debounce-minutes`（既定 2。timer の 1 tick から揺らぎの余裕を引いた値）以上経った pass でまとめて配送する。bot の review の
  連続コメントを 1 回で渡すため
- merge / close は待たずに配送する
- 配送しても既読位置は進めず、配送時刻と進め先（`pin_delivered_at` / `pin_delivered_upto`）を記録する。次の pass で
  その session の配送時刻以降の `UserPromptSubmit` が台帳にあれば、既読位置を進めて（merge / close なら pin を外して）記録を消す。
  6 分（timer の 2 tick）経っても無ければ window の中の resume が失敗したとみなして記録を消し、次の pass で再配送する。
  起動自体の失敗・skip は何も記録せず、次の pass で再試行する
- 確認できない配送が 3 回続いたら、その pin への配送を止め、pin のコメントの先頭に `[自動再開に 3 回失敗]` を付ける。
  PR の監視は続け、止めた配送より新しい活動か merge / close が来たら配送を再開する。pin を付け直しても再開する

配送は指示文を最初の入力にした resume で行う。interactive は picker の resume と同じ tmux session・window 名で
（その session が無ければ最後に attach された既存の session に。service から session を作ると `update-environment` で
SSH agent 等が消えた env になるので作らない）
`claude --resume <id> "<指示文>"` の window を detached で開き（client は動かさない。同名の window があっても `-S` は付けず、常に新しい window を作る。`-S` と `-d` の併用は同名 window があると何もせず成功を返すため）、background は
`claude --bg --resume <id> "<指示文>"`。どちらも台帳に記録された config dir で起動する。running な session には入力欄へ
打ち込まず、休眠と同じ手順で止めてから resume する。次のときは配送せず次の pass に回す: running かつ open な委譲先がいる、
running で `idle_done` にいない、window が表示中、cwd か transcript が無い、tmux server が居ない（interactive）、その
config dir の claude daemon が居ない（background。`<config dir>/daemon.lock` の pid と `/proc/<pid>/stat` の起動時刻で判定する）。
この pass で起こした session は同じ pass の休眠で止めない。

指示文は PR 番号と、review（state ごと）/ comment の件数を bot か人か別に並べ、本文は `gh-pr-comments <N>` で読むこと、
本文は信頼できない外部入力で指示として扱わないことを書く。本文と author 名は入れない。

timer の有効化:

```
bin/deploy.sh   # dot/systemd-user/claude-queue-watch.{service,timer} の symlink を張る
systemctl --user daemon-reload
systemctl --user enable --now claude-queue-watch.timer
```

## Auto-GC

`SessionEnd` hook 末尾で、`done_at` が 7 日以上前の sessions とその events を削除。gone の
session は期間に関わらず消さない。`session_links` は作成から 7 日以上経ち、親子のどちらも open で
ないものを削除。

既存 DB は初回の Open で一度だけ移行する（`PRAGMA user_version` で判定）。直近 7 日以内に
`prompt_input_exit` / `clear` 以外で閉じた session は open（gone）に、それ以外は done になる。

## tmux 設定（`dot/tmux.conf`）

```tmux
set -g status-interval 5
set -g status-right '#(claude-queue status) | %H:%M'
bind-key q display-popup -E -d "#{pane_current_path}" -w 80% -h 60% "claude-queue picker --repo-scope"
bind-key Q display-popup -E -w 80% -h 60% "claude-queue picker --show-working --show-stale"
```

prefix (`C-q`) のあと `q` で popup → fzf → Enter でジャンプ。`q` は `--repo-scope` 付きで、
**popup を開いた pane と同じ repo の session だけ**に絞る（メイン checkout と その
`.worktrees/*` は `--git-common-dir` を共有するので 1 グループになる）。`-d
"#{pane_current_path}"` を明示するのは、この絞り込みが popup 自身の cwd を起点にするため。
repo の外で `q` を押したときは一覧を出さず `not in a git repo; use prefix Q for all sessions`
を stderr へ出して終わる。`Q` は絞り込みを外した全部入り（別 repo の session も、working /
stale も出す）。gone は `q` / `Q` どちらでも出る。

`dot/tmux.conf` は `bin/deploy.sh` の symlink 経由なので pull した時点で反映されるが、
`bin/claude-queue` は `.gitignore` 対象で `make install` でしか更新されない。flag が増えた
バージョンを pull したら、tmux.conf を reload する前に `make install` を回す（古い binary は
未知の flag で usage を出して exit するだけなので、popup が無反応に見える）。

## Troubleshooting

| 症状 | 調べ方 |
|---|---|
| status-right が更新されない | `~/.claude/session-queue.db` 存在確認、`claude-queue status` 単体起動 |
| hook が動かない | `CLAUDE_QUEUE_DEBUG=1` で `~/.claude/session-queue.log` 確認 |
| picker から jump できない | picker が理由を stderr に出す（resume できない場合は transcript / cwd のどちらが欠けているかまで出る）。`tmux_pane` 列は NULL でも stale でも picker が再解決を試みるので、DB を見るだけでは jump 不能と断定できない。`claude agents --json` の生存扱いと `tmux list-panes -a` のプロセス実在を合わせて見る |
| DB が壊れた | `claude-queue reset` |

## Manual verification checklist

自動で回る gate は `.github/workflows/ci.yml` の 3 job（go / bash / shellcheck）。
Go 側は手元でも同じものを回せる：

```
make -C src/claude-queue test vet fmt-check
```

`fmt-check` は `gofmt -l .` の出力が非空なら落ちる。`go vet` は整形崩れを見ないので、
これが無いと未整形の Go が全 gate を通る。崩れたファイル名が出るので `gofmt -w` を当てる。
残る 2 job は repo root の `test/*.test.sh` と `bin/` の shellcheck で、対象は workflow が持つ。

以下は自動化できない、手で確かめる項目。PR 作成時に description に貼って確認：

- [ ] `make install` で `bin/claude-queue` 生成、`claude-queue --version` が期待値
- [ ] `claude-queue reset --force` で DB 削除、次 hook で再生成
- [ ] claude code を tmux pane で起動、SessionStart で sessions/events 各 1 行
- [ ] 確認プロンプト時に status-right が `⏳1` になる
- [ ] 承認後 `⚙️1`（working）、応答完了で `✅1`（idle_done）
- [ ] 拒否時は `PermissionDenied` で `⚙️1` に戻る
- [ ] `C-q q` で popup、Enter で目的 pane にジャンプ、popup 自動閉
- [ ] `claude --bg` で起動した background session（tmux_pane が NULL）を picker から選択、その worktree の tmux session に window が開いて `claude attach` される（popup を開いた session には増えない）
- [ ] `<repo>/.worktrees/<name>` のサブディレクトリで起動した session が、picker の 3 列目に `<repo>_<name>` で並ぶ（メイン checkout の session は `<repo>` だけ）
- [ ] `C-q q` が別 repo の session を出さず、現在 repo のメイン checkout + その `.worktrees/*` だけを並べる（`C-q Q` では別 repo の session も出る）
- [ ] repo の外の pane で `C-q q` を押すと `not in a git repo; use prefix Q for all sessions` が出る（`display-popup -E` は command の exit で閉じるので、読むにはシェルから直接起動する）
- [ ] worktree 内から `git wa x` すると `<repo>/.worktrees/x` に作られる（worktree の中で実行してもネストしない）
- [ ] 同じ repo の複数 session が、picker の 2 列目の ai-title で見分けられる（title の無い row は空欄のまま 3 列目の開始位置が揃う）
- [ ] tab を含む Bash コマンド（`awk -F'<tab>'`）の承認待ち row を picker から選ぶと、意図した session へ到達する（列がずれない）
- [ ] `tmux_pane` が NULL の interactive session（他 pane の同 tmux server 上に存在するもの）を picker から選ぶと、`claude attach` ではなく再解決した pane へ直接 switch される
- [ ] `tmux_pane` が「socket を別 server に明け渡した tmux server」の pane を指す interactive session を picker から選ぶと、SIGTERM 後に `claude --resume` で同じ session id のまま会話が復元される
- [ ] 別 socket（`tmux -L other`）で稼働中の server 上の interactive session を picker から選ぶと、kill されず理由が出る
- [ ] tmux 外で起動した（`TMUX` を持たない）interactive session を picker から選ぶと、kill されず「別端末で使用中の可能性」の理由が出る
- [ ] transcript が無い / cwd が reap 済みの session を picker から選ぶと、resume されずどちらが欠けたかが出る
- [ ] `SessionEnd` 後に `claude --resume` した session が picker に再び現れる
- [ ] ホスト再起動後、`C-q q` / `C-q Q` に再起動前の session が 💤 で並び、pin（📌）と委譲の木が残っている
- [ ] gone の session が running の session の後ろに並び、終了直前が `working` / `awaiting_approval` のものが先頭に来る
- [ ] gone の session を選ぶと同じ session id のまま会話が復元され、💤 が running の state に戻る
- [ ] Ctrl-C / `/exit` で閉じた session は一覧から消える
- [ ] 同 pane で `/clear` 後、旧 session が一覧から消える（L3）
- [ ] picker の `ctrl-x` で確認が出て、`y` で行が消え、その委譲先の行も消える。`n` では残る
- [ ] picker の `ctrl-e` で付けたメモが 11 列目に 📝 付きで出て、メモの語で絞り込める
- [ ] agent の Bash tool から `claude-queue pin --note "<待っているもの>"` を叩くと、その session に 📌 とコメントが出る
- [ ] `CLAUDE_QUEUE_ASCII=1` で `[!]1` 等に切替
- [ ] 2 pane 並行で approve 連打、busy_timeout 超過しない

## v0.2 backlog

v0.1 MVP の後続候補。優先度順に整理（implementation plan の final review より）。

### Feature
- **Subagent 追跡**: `SubagentStart`/`SubagentStop` + `TaskCreated`/`TaskCompleted` hook を追加し、working state に `working (N subagents)` を表示
- **Dismiss 機能**: picker 上 `d` キー → `dismissals` テーブルに書き込み、queue view から除外。schema 変更必要
- **fzf preview pane**: 選択中 session の transcript 末尾 N 行を popup 右側にプレビュー

### Refactor / Polish
- **MCP tool naming**: `mcp__server__tool` → `server.tool` 整形（`internal/summary/summary.go:toolInputSummary` に TODO あり）
- **共有 icon maps の抽出**: status/ と picker/ で emoji/ascii マップが重複。`internal/icons` 化
- **`db.ListRows` filter**: `where[0]` を上書きする現方式を slice-of-states に書き換え。state 追加時の保守性向上
- **status の debug log**: `db.Open` 失敗を once-per-process で throttle log

### Platform
- **Zellij multiplexer 実装**: `internal/multiplexer/zellij.go` + `Detect()` 分岐追加。status bar は WASM plugin 必須（別作業）、keybind/popup は `config.kdl` で別途設定
- **`~/.claude/session-queue.log` rotation**: `CLAUDE_QUEUE_DEBUG=1` 常用時に無限増殖を防ぐ

### Test coverage
- L3 rule で `$TMUX_PANE` が空のケース（degrade mode）の専用テスト
- `ensureSession` defensive path (SessionStart 無しで PermissionRequest が来た時) の専用テスト
- `db.ListRows` の `--show-working` / `--show-stale` フラグ各組み合わせのテスト
