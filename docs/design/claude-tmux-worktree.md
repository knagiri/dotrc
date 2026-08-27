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
| 委譲先の停止 | `bin/claude-stop-bg` |
| エージェント運用ルール | `dot/claude/rules/worktree-scope.md` |

## レイヤ構成

```
④ claude-worktree  … ① の worktree 追加 + 既定は ⑤ の起動、--tmux なら ② のセットアップ
        │
        ▼
① git worktree ──┬─(既定)────→ ⑤ claude --bg ──→ ③ claude-queue
  (dir / branch)  │             (short session id)  (tmux_pane = NULL)
                  │
                  └─(--tmux)──→ ② tmux session ──→ ③ claude-queue
                                (session=basename)  ($TMUX_PANE)
```

①の worktree 作成はどちらの経路でも必ず走る。分岐するのは「その worktree で何を起こすか」
だけで、②の tmux session は `--tmux` 指定時にしか作られない。③はどちらの経路でも追跡する
（②を経ない既定経路では `tmux_pane` が NULL になるだけ）。

| 層 | ツール | 担当 | 識別キー |
|---|---|---|---|
| ① ファイル/ブランチ | `git w*` alias | worktree の作成・一覧・削除 | ディレクトリパス / ブランチ |
| ② tmux セッション | `gts`(`ghq-tmux-session`) | worktree dir ごとに tmux session を作って attach/switch | session 名 = dir basename |
| ③ Claude 可視化 | `claude-queue` | 全 pane の Claude 状態を SQLite 化、status-right 表示 + fzf popup で pane へジャンプ | `$TMUX_PANE`（②を経ない既定経路では NULL。short session id で識別） |
| ④ 分岐起動 | `claude-worktree` | ①の worktree 追加を常に行い、既定は⑤の起動、`--tmux` 指定時のみ②のセットアップ（③はどちらの経路でも追跡する） | worktree dir / short session id（`--tmux` 時は tmux session） |
| ⑤ background 起動 | `claude --bg` | 人間不在の委譲先を起こす。完遂後も `idle` で残るので委譲元が閉じる | short session id（8 桁） |

**鍵となる連結（②を作る経路に限る）:** worktree dir の basename = tmux session 名。区切り文字を
`_` に統一してあるため、`①の dir 名 dotrc_foo` → `②の session 名 dotrc_foo` が自動的に一致し、
`gts` も `claude-worktree --tmux` も同じ session を指す（二重作成が起きない）。既定経路
（`claude --bg`）は②を作らないのでこの連結は働かず、到達は `claude attach <short-id>` になる。
既定経路で作った worktree dir に人間が後から `gts` を叩く場合も、同じ命名規約により basename
と同名の session が立つ（先行 session が無いので、やはり二重作成にはならない）。

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
- `C-q q` で popup → fzf picker → 選択 session へ到達（pane への `tmux switch-client` / `claude attach` /
  `claude --resume` を後述の順で選ぶ）
- **L3 自己修復**: 新規 `SessionStart` 時、同一 `$TMUX_PANE` 上の生存 session を `ForcedEnd`
  （`/exit`・`/clear` で `SessionEnd` が飛ばないバグの後始末）

→ ③は **記録のキーとして pane を使う**。この前提が④の設計（後述）を縛る。ただし到達手段としては
当てにしない（後述の「③との噛み合わせ」）。

### ④ claude-worktree（`bin/claude-worktree`）

```
claude-worktree [--tmux] <name> [-b <branch>] [-- <prompt...>]
```

- worktree を `<メインリポジトリ toplevel>_<name>` に作成
- `name` は `[A-Za-z0-9_-]+` のみ許可（`.`/`:` は tmux ターゲット構文と衝突するため拒否）
- `-b` 省略時はブランチ名 = `<name>`。解決順はローカルブランチ → `origin/<branch>` を追跡 checkout →
  どちらにも無ければ新規作成（fetch はしない）
- プロンプト無し: worktree 追加のみ。stdout にパスのみ出力（`git wa` の置き換え）
- プロンプト有り（既定）: **worktree dir で `claude --bg`（background agent, `acceptEdits`）を起動**。
  tmux session は作らない。捕捉した short session id を `attach: claude attach <short-id>` として
  stdout に出す
- プロンプト有り + `--tmux`: **detached tmux session（名前 = worktree basename）を作り、その pane の
  中で interactive claude（`acceptEdits`）を起動**。人間が同席する委譲に使う
- `settings.json` で `claude-worktree` / `claude-worktree *` を allow 済み（承認不要）

## エンドツーエンドの流れ（作業を分岐する）

1. worktree A の tmux pane で claude 作業中（③が pane 単位で追跡、status-right に状態表示）
2. 独立した別ラインを切り出したい → `claude-worktree B -- "<prompt>"`
3. ④が worktree B を作り、その中で `claude --bg` を起動する（tmux session は作らない）
4. ユーザーは `claude attach <short-id>` で様子を見る。`C-q q`（③picker）からも同じ場所へ飛べる
   - 承認待ちで止まっていれば、attach した画面にその prompt がそのまま出る
5. 委譲先は完遂しても session を終えず `idle` で待ち続ける。委譲元は完了報告を受けたら、
   質問へ返信したかに関わらず `claude-stop-bg <short-id>` で閉じる（理由は後述）

## 設計判断と根拠

### 区切り文字は `_`（`.` 不可・`@` 不採用）

worktree dir の basename はそのまま tmux session 名になる。tmux のターゲット指定は
`session:window.pane` 構文で `.` を **pane 区切り**として解釈し、さらに session 名では
`.`→`_` に変換する。そのため `dotrc.foo` を `switch-client -t dotrc.foo` すると
「session `dotrc` の pane `foo`」と誤解釈され `can't find pane: foo` で落ちる。

`@` は tmux 上は無害（旧 `git wa` の `dotrc@chore` は動作した）が、可読性の観点で不採用。
`_` は tmux ターゲット・session 名どちらでも安全。`git wa` と `claude-worktree` の双方を
`_` に統一した。

### ④の既定は `claude --bg`（tmux session を作らない）

素朴に `claude -p` をバックグラウンド（`setsid`）で起動すると、環境変数を継承するため
ヘッドレス session の `$TMUX_PANE` が **起動元 pane のまま** になる。③は pane を ID とするので、
起動元 pane を指す重複エントリが載り、L3 自己修復が起動元の追跡を誤終了し得た。この懸念が
「先に tmux session を作り、その pane で起動する」という初期設計の根拠だった。

`claude --bg`（background agent）ではこれが起きない。**`$TMUX_PANE` を継承しない**（実測: pane
の中から起動しても③の `tmux_pane` は NULL）ため、起動元を指す重複エントリが作られない。
`internal/hook/dispatch.go` の `forcedEndSiblings` は `Pane != ""` でガードされているので、
空 pane の session が L3 自己修復を発火させることも原理的に無い。

`-p` と違い、承認が要る tool call は**ブロックして待つ**（`claude agents --json` が
`status: waiting`, `waitingFor: permission prompt` を返す）。人間不在の委譲先が「静かに劣化した
まま完了扱い」になることがないので、`-p` の棄却理由も解消している。

そのうえで background は tmux session も pane も占有しない。人間が同席しない委譲にはそれで
足りるため、④の既定を background に置いた。

一方で **session の滞留は background でも消えない**。タスクを完遂しても session は終わらず、
`claude agents --json` の `status: idle`（承認待ちの `status: waiting` / `waitingFor: permission
prompt` とは別状態）で次の入力を待ち続ける。放置すると完遂から約 60 分で roster から消えるが、
その消滅では `SessionEnd` が飛ばないため③の `terminated_at` は NULL のまま残り、`queue` view に
幽霊行が残る。追跡がきれいに閉じるのは `claude stop`（= `claude-stop-bg`）で閉じた経路だけ。
したがって委譲元は、完了報告を受けたら質問へ返信したかに関わらず `claude-stop-bg <short-id>` で
閉じる（`delegate-to-worktree` 手順 6 / `worktree-scope.md` §6）。

worktree の滞留も同様に残る — ①はどちらの経路でも走り、誰も消さないので、後片付けは
`worktree-scope.md` §7 の `git-reap-gone`（manual 運用）が担う。tmux session を作る経路は
`--tmux` として残してある — 人間が同席して設計を詰めるような、interactivity を要求する
委譲のためで、退避路ではない。

③との噛み合わせは「pane 無し = 追跡は完全、ジャンプだけ不能」になる。status-right のカウントは
`terminated_at IS NULL` と state だけで絞るので background も普通に乗る。

ジャンプ側は **pane を到達手段の第一候補に留め、当てにはしない**。`tmux_pane` は NULL になるだけで
なく、既に置き換わった tmux server の pane を指し続ける（実測では live 48 行のうち 44 行がこの状態）。
そこで picker は列の値を現行 server の pane 表と照合し、実在しなければ `claude agents --json` の pid
からプロセス祖先を辿って再解決する。

再解決しても pane に到達できない session は、種別で到達手段が分かれる。

- **background**: `claude attach <short-id>` を、その worktree の tmux session（session 名 =
  worktree ディレクトリ名。`gts` / `claude-worktree` と同じ慣習）を単位に開く。無ければ session ごと
  作成、既にあれば window を足して client をそこへ移す。popup を開いた時点の current session には
  作らない — これが「1 worktree = 1 tmux session」を守る理由で、承認待ちで止まった background
  委譲先へ入る経路はこれだけなので picker から隠さず出す
- **interactive**: `claude attach` は background 専用（interactive に投げると `No job matching` で
  exit 1）なので、到達単位が pane から **transcript** へ移る。`claude --resume <uuid>` は session id を
  変えないので、③の row は差し替わらずそのまま復元される

resume が pane への switch と決定的に違うのは、**元プロセスを引き継がず別プロセスを立てる**点で、
同一 transcript を 2 プロセスが掴む状態になる。そこで resume の前にプロセスを終わらせるが、
終わらせてよいのは **pane が別 tmux server にあると確定した場合だけ**とする（`/proc/<pid>/environ` の
`TMUX` から server pid を取り、現行 server の pid と比較する）。確定できない場合 — `TMUX` を持たない
（tmux 外で起動した）、`/proc` が読めない、比較相手の server pid が取れない — は別端末で使用中の
可能性が残るので、何もせず理由を出す。判定不能を orphan 扱いしないのが安全側。SIGTERM だけを使い
SIGKILL へ上げないのも同じ側で、居座るプロセスは transcript を掴んだままなので、強制排除は復元
しようとしている会話自体を失うリスクを取ることになる。

resume には transcript と cwd の実在確認が要る。存在しない uuid を `--resume` に渡してもエラーには
ならず、その id で空の新規 session が立ってしまうため、確認を欠いた resume は「成功したように見えて
会話を失う」。短命 session は jsonl を書かないので `transcript_path` があってもファイルが無いことが
あり（実測 12 行中 3 件）、reap 済み worktree の session は resume が transcript を引く基準の cwd 側が
消えている（同 3 件）。

flag レベルの詳細（`-d` の要否が経路で逆になる理由、`-t` の `=` 接頭辞・末尾 `:`・`-S` による window
再利用）は `internal/multiplexer/tmux.go` のコメントに一本化してあるので、そちらを参照
（README.md は挙動レベルの説明に留め、flag レベルは書かない）。

### ④は **メイン** toplevel 基準でパスを作る

`git rev-parse --git-common-dir` の親（= メイン working tree の toplevel）を基準にするため、
worktree の中から `claude-worktree` を実行しても `dotrc_a_b` のようにネストしない。

## 既知の差分・今後の論点

- **anchor の不一致**: `git wa` は現在 toplevel（`rpst`）基準、`claude-worktree` はメイン
  toplevel 基準。worktree 内から `git wa` するとパスがネストし得る。揃えるなら `git wa` も
  `--git-common-dir` 基準にする。
- **alias のスコープ**: `gts` は対話シェル限定（非対話/スクリプトでは実名 `ghq-tmux-session`）。
