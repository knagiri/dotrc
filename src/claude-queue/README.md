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
| `claude-queue picker` | fzf を popup で起動し、選択 session の pane に `tmux switch-client` |
| `claude-queue reset [--force]` | DB (`~/.claude/session-queue.db`) を削除、対話 y/N |
| `claude-queue --version` | バージョン表示 |

### 環境変数

| Var | 意味 |
|---|---|
| `CLAUDE_QUEUE_DB` | DB パス override（既定 `~/.claude/session-queue.db`） |
| `CLAUDE_QUEUE_ASCII=1` | アイコンを ASCII フォールバック `[!] [.] [*] [X]` に切替 |
| `CLAUDE_QUEUE_DEBUG=1` | エラーを `~/.claude/session-queue.log` に追記 |

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
| picker から jump できない | `sqlite3 ~/.claude/session-queue.db "SELECT tmux_pane FROM sessions WHERE terminated_at IS NULL"` |
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
- **共有 `dbPath()` の抽出**: 現状 hook/run.go, status/, picker/, reset/ で 4 重複。`internal/config` か `internal/paths` に集約
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
