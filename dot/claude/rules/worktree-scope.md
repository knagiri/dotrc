## worktree 作業スコープのルール

git worktree（linked worktree）内で起動された Claude Code は、**明示的に指示されない限り、その worktree ディレクトリ内の作業に閉じる**。
別 worktree・main チェックアウトへ作業を波及させない。

スコープの単位は **worktree ディレクトリであって、単一ブランチではない**。1 つの worktree 内でブランチを切り替えたり、新規ブランチを起こして PR を積み上げたりする運用は通常想定であり、妨げない。

関連ルール: 許可設定の仕組みは [claude-settings.md](./claude-settings.md)、承認が要るコマンドの回避は [bash-command-constraints.md](./bash-command-constraints.md) を参照。作業対象の dir が cwd とズレて `cd`/`git -C` で渡り歩きたくなったら、[working-directory.md](./working-directory.md) に従い `/cd` で cwd 自体を移す（§3 の read-only 覗き見はその例外）。

### なぜ閉じるのか

worktree は「1 まとまりの作業 = 1 作業ツリー」で並行作業を**隔離**するために切られる。ユーザーがこの worktree で Claude を起動した時点で、作業対象はこの worktree だと表明している。ディレクトリ境界を越えてスコープを広げると次の実害が出る。

- **他作業ツリーへの巻き込み**：別 worktree は別ブランチを同時にチェックアウトしている。そこを編集すると、ユーザーが並行作業中の場所に予期しない変更が混入する。
- **意図の逸脱**：「この worktree でやって」という暗黙の指示に反し、レビュー対象が他ツリーへ散らばって差分が追えなくなる。
- **二重チェックアウトの破綻**：git は同一ブランチを 2 つの worktree で同時チェックアウトできない。他 worktree が持つブランチへ `switch` しようとすると失敗する。

### 1. 自分が linked worktree にいるかの判定

`--git-common-dir` と `--git-dir` が **異なれば** linked worktree、一致すれば main working tree。現在ブランチは `--abbrev-ref HEAD` で取る。

```
git rev-parse --git-common-dir --git-dir   # 不一致なら linked worktree
git rev-parse --abbrev-ref HEAD            # 現在ブランチ
git worktree list                          # worktree ↔ ブランチ対応
```

いずれも settings.json の allow（`git rev-parse *` / `git worktree list`）に含まれ、承認なしで実行できる。

### 2. 原則：起動した worktree ディレクトリに閉じる

linked worktree で起動された場合、デフォルトは以下に従う。「permission」列は settings.json 上の扱い。

| 行為 | 方針 | permission（settings.json） |
|---|---|---|
| この worktree 内でのファイル編集・コミット | **可** | 許可 |
| この worktree 内でのブランチ切替・新規ブランチ作成 | **可**。複数ブランチ／積み上げ PR を扱ってよい | 許可（`switch`/`checkout *`） |
| 作業中ブランチ（積み上げ含む）の push | **可** | 許可（`push *`） |
| 他 worktree 配下のファイル操作 | **しない** | Edit/Write は許可 → ルールで範囲限定 |
| 他 worktree がチェックアウト中のブランチへの `switch` | **しない**（git も二重チェックアウトを拒否） | 許可だがルールで禁止 |
| 新規 worktree 作成（`git worktree add`） | 明示指示がなければ**しない** | 未許可（呼ぶと承認プロンプト＝二重の歯止め） |
| main への直接 push、無関係なブランチへの merge・rebase | **しない** | push は許可・merge/rebase は未許可 |

worktree のディレクトリ外（絶対パスで他 worktree や main checkout を指すパス）への**書き込み**は、原則スコープ外とみなす。

### 3. read-only な参照は可

スコープ制限は「書き込み」に限る。調査目的の read-only 操作は worktree 外を見てよい。下記はいずれも allow 済みで承認不要。

- 他ブランチとの diff 確認（`git diff <other-branch>` … `git diff *`）
- 履歴参照（`git log <other-branch>` … `git log *`）
- main の内容参照（`git show main:path` … `git show *`）

### 4. スコープを広げてよいケース

以下のように **ユーザーが明示的に指示したときのみ**、対象を現在 worktree ディレクトリの外へ広げる。

- 「main にも反映して」「別 worktree を直して」等、他ツリーを名指しした指示
- 「新しく worktree を切って」等、worktree 操作そのものの依頼

曖昧な場合（どの worktree が対象か不明確）は、勝手に広げず確認する。

### 5. 作業を別 worktree へ分岐する（`claude-worktree`）

今の worktree の作業を止めずに、独立した別ラインの作業を切り出したいときは `claude-worktree`（`bin/`）を使う。現在 worktree への変更はそのまま残り、分岐先は別ディレクトリ・別ブランチで進む。

```
claude-worktree [--seed <path>]... <name> [-b <branch>] [-- <prompt...>]
```

- worktree は `<メインリポジトリ toplevel>_<name>` に作られる（メイン基準なので worktree 内から切ってもパスがネストしない。区切りは tmux 安全な `_`。`.` は `tmux -t` の `window.pane` 構文と衝突するため不可）
- `-b` 省略時はブランチ名 = `<name>`。既存ブランチ名なら check out、無ければ新規作成
- `--` の後ろにプロンプトを渡すと、**新規の detached tmux セッション（名前 = worktree basename）を worktree dir に作り、その pane の中で interactive claude（`acceptEdits`）を起動**する。pane が独立するので `$TMUX_PANE` も独立し、claude-queue が起動元 pane と衝突せず正しく追跡する。interactive なので初期プロンプト処理後も REPL に留まり、`gts <session>` / `tmux attach -t <session>` で**いつでも attach して続行できる（`claude --resume` 不要）**
- プロンプト無しなら worktree 追加のみ（stdout にパスのみ出力。`git wa` の置き換え）
- `--seed <path>`（繰り返し可）は、現 checkout の `<path>` を新 worktree の同じ相対位置へコピーする。存在しない／checkout 外の seed は worktree 作成前に fail する
- settings.json で allow 済み（`claude-worktree` / `claude-worktree *`）なので承認なしで実行できる

分岐先は `acceptEdits` で自律的に編集を進める。タスクが自然に独立した複数ラインへ割れるときに、現在 worktree を汚さず並行で進める選択肢として使う。乱用は避け、分岐の必要性が薄いときは現在 worktree 内で進める。

#### 委譲プロンプトはファイルシステム的に自己完結させる

委譲プロンプトが参照するファイルは、原則すべて新 worktree の中に在る状態にしてから起動する。worktree 外の絶対パスを委譲先に読ませない。

理由は 2 つあり、どちらも「委譲先が最初の一歩で固まる」に直結する。

- **伝播しない**: 新 worktree は指定 branch を checkout するだけで、起動元 checkout の gitignore 済み・未 commit ファイルは持ち込まれない。絶対パスで指せば読めるが、それは起動元 checkout の外部ファイルを読ませているに過ぎない
- **承認で固まる**: worktree 外の絶対パス Read は `acceptEdits` でも permission prompt を出す。委譲先は fire-and-forget（人間不在）なので誰も承認できず、そこで停止する

したがって参照ファイルの扱いは次で分かれる。

| 参照したいファイル | どうするか |
|---|---|
| commit 済み（branch に載っている） | 何もしない。worktree に既に在る。相対パスで参照させる |
| gitignore 済み・未 commit（spec / plan / メモ等） | `claude-worktree --seed <path>` で worktree 内へ入れ、相対パスで参照させる |
| プロンプト本文へ畳める短い内容 | seed せずプロンプトに畳む（ファイル参照自体を消す） |

seed したファイルは gitignore 済みなら worktree 内でも untracked のままなので、委譲先の commit には載らない。

<!-- 文脈: main checkout の gitignore 済み spec を絶対パスで参照する委譲プロンプトを渡したところ、
     委譲先が worktree 外 Read の permission prompt で最初の一歩から動けなくなった incident。
     根本: 委譲先が承認なしに読めるのは新 worktree 内のファイルだけ。 -->

連携の全体像（git worktree → tmux セッション → claude-queue の 3 層と `claude-worktree` の位置づけ）は `docs/design/claude-tmux-worktree.md` を参照。

### 6. 委譲 worktree の後片付け（`git-reap-gone`）

§5 で分岐・委譲した作業が merge され終わったら、その worktree とブランチの後始末を頼まれることがある。「後片付けして」「委譲先を片付けて」等で依頼されたら、手作業で `git worktree remove` / `git branch -d` を撃たず、`git-reap-gone`（`bin/`）を保守的 predicate で回す。

```
git-reap-gone [--no-fetch] [<branch>...]
```

- **トリガーは推論せず `[gone]` 状態**。リモートが merge 時にブランチを削除 → `git fetch --prune`（スクリプト冒頭で自動実行）で local が `[gone]` 化する、という権威ある外部イベントだけを完了の合図にする。`--no-fetch` で冒頭 fetch を抑制できる（呼び出し側／cron が fetch を制御する場合）。
- **reap してよい条件（全通過のみ削除）**: ①統合先（`origin/HEAD` = 通常 `origin/main`）に対し未統合コミットが無い、②worktree が紐づくならそれが clean、③その worktree が今いる worktree でない。裸ブランチ（worktree 無し）は①のみで判定。
- **削除は安全形だけ**: `git worktree remove`（**`--force` 無し**）＋ `git branch -d`（**`-D` ではない**）。条件を欠くもの・git が拒否したものは **skip し、何が blocking か report** する。決して force にエスカレートしない。これにより dirty／別ブランチへ切替済み（→ `[gone]` ブランチに worktree が紐づかない）等で spawn 中の worktree は自動的に対象外になる。
- 引数でブランチ名を指定するとその対象だけを（同じゲートを通して）reap する。無指定なら全 `[gone]` を sweep。
- **manual 運用**。cron/janitor の常駐は当面作らない。ただし全 `[gone]` を sweep できる形なので、将来そのまま cron/loop に挿せる。
- settings.json で allow 済み（`git-reap-gone` / `git-reap-gone *`）なので承認なしで実行できる。
