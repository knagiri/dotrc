# Claude × tmux × git worktree 連携設計

複数タスクを並行で回すための、git worktree / tmux セッション / Claude Code セッションの
連携設計をまとめる。各ツールが **何をキーに対象を識別するか** が異なる点を押さえると、
全体の噛み合わせが理解できる。

## 関連ファイル

| 領域 | 実体 |
|---|---|
| worktree 操作 alias | `dot/git/config`（`w`/`wl`/`wls`/`wa`/`wd`/`rpst`） |
| tmux セッション | `bin/ghq-tmux-session`（alias `gts` = `rc/aliases`） |
| Claude セッション可視化 | `src/claude-queue/`（→ `bin/claude-queue`）。詳細は同梱 README |
| worktree 分岐起動 | `bin/claude-worktree` |
| エージェント運用ルール | `dot/claude/rules/worktree-scope.md` |

## レイヤ構成

```
④ claude-worktree  … worktree 追加 + ②③を一括セットアップする入口
        │
        ▼
① git worktree ──→ ② tmux session ──→ ③ claude-queue
  (dir / branch)    (session=basename)   ($TMUX_PANE)
```

| 層 | ツール | 担当 | 識別キー |
|---|---|---|---|
| ① ファイル/ブランチ | `git w*` alias | worktree の作成・一覧・削除 | ディレクトリパス / ブランチ |
| ② tmux セッション | `gts`(`ghq-tmux-session`) | worktree dir ごとに tmux session を作って attach/switch | session 名 = dir basename |
| ③ Claude 可視化 | `claude-queue` | 全 pane の Claude 状態を SQLite 化、status-right 表示 + fzf popup で pane へジャンプ | `$TMUX_PANE` |
| ④ 分岐起動 | `claude-worktree` | ①の worktree 追加と②③のセットアップを 1 コマンド化 | worktree dir / tmux session |

**鍵となる連結:** worktree dir の basename = tmux session 名。区切り文字を `_` に統一して
あるため、`①の dir 名 dotrc_foo` → `②の session 名 dotrc_foo` が自動的に一致し、`gts` も
`claude-worktree` も同じ session を指す（二重作成が起きない）。

## 各層の詳細

### ① git worktree alias（`dot/git/config`）

| alias | 展開 | 用途 |
|---|---|---|
| `git w` | `worktree` | 素の worktree コマンド |
| `git wl` | `w list` | worktree 一覧 |
| `git wls` | `wl \| awk '{print $1}' \| fzf -1` | worktree パスを fzf 選択 |
| `git wa <name> [branch]` | `w add "$(git rpst)_<name>" [-b branch]` | worktree 追加 |
| `git wd` | `w remove $(git wls)` | fzf で選んで削除 |
| `git rpst` | `rev-parse --show-toplevel` | （現在の）worktree toplevel |

`git wa` は **現在の** worktree toplevel（`rpst`）基準でパスを作る。

### ② tmux セッション（`bin/ghq-tmux-session`, alias `gts`）

- `gts`（引数なし）: `ghq list` を fzf 選択 → repo dir basename を session 名にして、その dir で
  session を作成（無ければ）→ switch/attach
- `gts <name>`: 指定名の session を作成（既存なら再利用）→ switch/attach
- session 切替は `$TMUX` 有無で `switch-client` / `attach-session` を自動選択

worktree dir は ghq 配下の兄弟ディレクトリとして `ghq list` に載るため、fzf 候補に出る。

実コマンドは `ghq-tmux-session`（PATH 上）。nvim の `<leader>gq`（snacks.lua）も実名で呼ぶ。
対話シェルでは `alias gts='ghq-tmux-session'`（`rc/aliases`）で短縮。

### ③ claude-queue（`src/claude-queue/`）

- `settings.json` の hooks が Claude ライフサイクル各イベントで `claude-queue hook <event>` を呼び、
  `$TMUX_PANE` をキーに状態を SQLite（`~/.claude/session-queue.db`）へ記録
- tmux `status-right` に `claude-queue status`（working/awaiting_approval/idle_done のカウント）
- `C-q q` で popup → fzf picker → 選択 session の pane へ `tmux switch-client`
- **L3 自己修復**: 新規 `SessionStart` 時、同一 `$TMUX_PANE` 上の生存 session を `ForcedEnd`
  （`/exit`・`/clear` で `SessionEnd` が飛ばないバグの後始末）

→ ③は **pane を ID とする**。この前提が④の設計（後述）を縛る。

### ④ claude-worktree（`bin/claude-worktree`）

```
claude-worktree <name> [-b <branch>] [-- <prompt...>]
```

- worktree を `<メインリポジトリ toplevel>_<name>` に作成
- `name` は `[A-Za-z0-9_-]+` のみ許可（`.`/`:` は tmux ターゲット構文と衝突するため拒否）
- `-b` 省略時はブランチ名 = `<name>`（既存なら check out、無ければ新規）
- プロンプト無し: worktree 追加のみ。stdout にパスのみ出力（`git wa` の置き換え）
- プロンプト有り: **detached tmux session（名前 = worktree basename）を作り、その pane の中で
  interactive claude（`acceptEdits`）を起動**
- `settings.json` で `claude-worktree` / `claude-worktree *` を allow 済み（承認不要）

## エンドツーエンドの流れ（作業を分岐する）

1. worktree A の tmux pane で claude 作業中（③が pane 単位で追跡、status-right に状態表示）
2. 独立した別ラインを切り出したい → `claude-worktree B -- "<prompt>"`
3. ④が worktree B を作り、`dotrc_B` という detached session の pane で interactive claude を起動
4. ユーザーは `gts dotrc_B`（または `tmux attach -t dotrc_B`）で attach
   - interactive なので初期プロンプト処理後も REPL に留まる → `claude --resume` 不要
5. `C-q q`（③picker）で A / B の pane を行き来

## 設計判断と根拠

### 区切り文字は `_`（`.` 不可・`@` 不採用）

worktree dir の basename はそのまま tmux session 名になる。tmux のターゲット指定は
`session:window.pane` 構文で `.` を **pane 区切り**として解釈し、さらに session 名では
`.`→`_` に変換する。そのため `dotrc.foo` を `switch-client -t dotrc.foo` すると
「session `dotrc` の pane `foo`」と誤解釈され `can't find pane: foo` で落ちる。

`@` は tmux 上は無害（旧 `git wa` の `dotrc@chore` は動作した）が、可読性の観点で不採用。
`_` は tmux ターゲット・session 名どちらでも安全。`git wa` と `claude-worktree` の双方を
`_` に統一した。

### ④は「先に tmux session を作り、その pane の中で claude を起動」

素朴に `claude -p` をバックグラウンド（`setsid`）で起動すると、環境変数を継承するため
ヘッドレス session の `$TMUX_PANE` が **起動元 pane のまま** になる。③は pane を ID とするので:

- 起動元 pane を指す重複エントリが DB に載る
- L3 自己修復が「同一 `$TMUX_PANE` の他 session を ForcedEnd」→ **起動元 A の追跡を誤終了** し得る

これを避けるため、先に `tmux new-session -d` で **新しい pane** を作り、その中で claude を
起動する。claude は自分の pane の `$TMUX_PANE` を見るので③が正しく追跡し、起動元との衝突が
無い。あわせて `-p` ではなく interactive 起動（初期プロンプト渡し）にすることで、処理後も
REPL に残り attach するだけで続行でき、`--resume` の二段が消える。

### ④は **メイン** toplevel 基準でパスを作る

`git rev-parse --git-common-dir` の親（= メイン working tree の toplevel）を基準にするため、
worktree の中から `claude-worktree` を実行しても `dotrc_a_b` のようにネストしない。

## 既知の差分・今後の論点

- **anchor の不一致**: `git wa` は現在 toplevel（`rpst`）基準、`claude-worktree` はメイン
  toplevel 基準。worktree 内から `git wa` するとパスがネストし得る。揃えるなら `git wa` も
  `--git-common-dir` 基準にする。
- **alias のスコープ**: `gts` は対話シェル限定（非対話/スクリプトでは実名 `ghq-tmux-session`）。
- **claude-queue 連携の検証**: ④で起動した session が③の picker / status に正しく載るかは、
  実 claude 起動での通し確認が望ましい（pane 独立はスタンドインで実証済み）。
