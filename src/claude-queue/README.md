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
| `claude-queue picker` | fzf を popup で起動し、選択 session へ到達する（到達手段の決定は後述） |
| `claude-queue reconcile` | `claude agents --json` に載っていない生存扱いの row を terminated にする（picker 起動時に自動実行される） |
| `claude-queue reset [--force]` | DB (`~/.claude/session-queue.db`) を削除、対話 y/N |
| `claude-queue --version` | バージョン表示 |

### 環境変数

| Var | 意味 |
|---|---|
| `CLAUDE_QUEUE_DB` | DB パス override（既定 `~/.claude/session-queue.db`） |
| `CLAUDE_QUEUE_ASCII=1` | アイコンを ASCII フォールバック `[!] [.] [*] [X]` に切替 |
| `CLAUDE_QUEUE_DEBUG=1` | エラーを `~/.claude/session-queue.log` に追記 |

### picker の到達手段

選択された session への到達手段を次の順で決める。

1. **到達できる pane があれば `tmux switch-client`**。roster に該当 session があれば
   `claude agents --json` の pid からプロセス祖先を辿って pane を解決する（identity 込みの
   確認）。ledger の `tmux_pane` を最後の手段として見るのは **roster を読めなかったときだけ**
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
   **別 tmux server にあると確定し、かつその server が既に無いと確定した場合だけ**
   （`/proc/<pid>/environ` の `TMUX` から server pid を取り現行 server の pid と比較したうえで、
   その server pid が `/proc` に残っているかで生死を見る）。tmux server は socket 単位なので、
   別 server の pid が生きている限り別端末からそこに attach して使用中の可能性が残る。`TMUX` が
   無い（tmux 外で起動）・`/proc` が読めない・別 server の生死を確定できない等、いずれかが
   確定できないときは何もせず理由を出す。確定したときは SIGTERM を送り roster から消えるまで
   最大 10 秒待つ。消えなければ resume せず報告して終わる（SIGKILL へは上げない）
4. **roster に居ない session はそのまま `claude --resume`**。止めるプロセスが無い
5. **resume は transcript と cwd が実在するときだけ行う**。存在しない uuid を `--resume` に
   渡してもエラーにならず、その id で空の新規 session が立ってしまう。短命 session は jsonl を
   書かないので `transcript_path` があってもファイルが無いことがあり、reap 済み worktree の
   session は cwd 側が消えている。どちらが欠けたかを stderr に出して終わる

session 名 = worktree ディレクトリ名（`gts` / `claude-worktree` と同じ慣習）。popup を開いた
時点の current session には作らない。

## State machine

| hook event | state |
|---|---|
| `SessionStart` | working |
| `UserPromptSubmit` | working |
| `PermissionRequest` | awaiting_approval |
| `PermissionDenied` / `PostToolUse` / `PostToolUseFailure` | working |
| `Stop` / `StopFailure` | idle_done |
| `SessionEnd` | ended（view から除外） |

Stale 閾値: working > 8h / awaiting_approval > 2h / idle_done > 4h 経過。

## L3 自己修復

`/exit` `/clear` で `SessionEnd` が発火しないバグ対処：新規 `SessionStart`
時に **同一 `$TMUX_PANE` 上で生存中の他 session を `ForcedEnd`**。

## Auto-GC

`SessionEnd` hook 末尾で、`terminated_at` が 7 日以上前の sessions とその
events を削除。

## tmux 設定（`dot/tmux.conf`）

```tmux
set -g status-interval 5
set -g status-right '#(claude-queue status) | %H:%M'
bind-key q display-popup -E -w 80% -h 60% "claude-queue picker"
```

prefix (`C-q`) のあと `q` で popup → fzf → Enter でジャンプ。

## Troubleshooting

| 症状 | 調べ方 |
|---|---|
| status-right が更新されない | `~/.claude/session-queue.db` 存在確認、`claude-queue status` 単体起動 |
| hook が動かない | `CLAUDE_QUEUE_DEBUG=1` で `~/.claude/session-queue.log` 確認 |
| picker から jump できない | picker が理由を stderr に出す（resume できない場合は transcript / cwd のどちらが欠けているかまで出る）。`tmux_pane` 列は NULL でも stale でも picker が再解決を試みるので、DB を見るだけでは jump 不能と断定できない。`claude agents --json` の生存扱いと `tmux list-panes -a` のプロセス実在を合わせて見る |
| DB が壊れた | `claude-queue reset` |

## Manual verification checklist

PR 作成時に description に貼って確認：

- [ ] `make install` で `bin/claude-queue` 生成、`claude-queue --version` が期待値
- [ ] `claude-queue reset --force` で DB 削除、次 hook で再生成
- [ ] claude code を tmux pane で起動、SessionStart で sessions/events 各 1 行
- [ ] 確認プロンプト時に status-right が `⏳1` になる
- [ ] 承認後 `⚙️1`（working）、応答完了で `✅1`（idle_done）
- [ ] 拒否時は `PermissionDenied` で `⚙️1` に戻る
- [ ] `C-q q` で popup、Enter で目的 pane にジャンプ、popup 自動閉
- [ ] `claude --bg` で起動した background session（tmux_pane が NULL）を picker から選択、その worktree の tmux session に window が開いて `claude attach` される（popup を開いた session には増えない）
- [ ] worktree のサブディレクトリで起動した session が、picker の 2 列目に worktree 名で並ぶ
- [ ] `tmux_pane` が NULL の interactive session（他 pane の同 tmux server 上に存在するもの）を picker から選ぶと、`claude attach` ではなく再解決した pane へ直接 switch される
- [ ] `tmux_pane` が別 tmux server の pane を指す interactive session を picker から選ぶと、SIGTERM 後に `claude --resume` で同じ session id のまま会話が復元される
- [ ] tmux 外で起動した（`TMUX` を持たない）interactive session を picker から選ぶと、kill されず「別端末で使用中の可能性」の理由が出る
- [ ] transcript が無い / cwd が reap 済みの session を picker から選ぶと、resume されずどちらが欠けたかが出る
- [ ] `SessionEnd` 後に `claude --resume` した session が picker に再び現れる
- [ ] 同 pane で `/clear` 後、旧 session が view から消える（L3）
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
