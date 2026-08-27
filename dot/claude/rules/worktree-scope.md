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

#### 状態の確認は `.git/` のパスを直接見ず、git コマンドに問う

linked worktree の `.git` は**ディレクトリではなくファイル**である（`gitdir: <path>` を書いた
1 行のテキストファイルで、実体は main repo 側の `.git/worktrees/<name>/` にある）。したがって
`ls .git/MERGE_HEAD` / `cat .git/HEAD` / `ls .git/rebase-merge` のようにパスを直接叩く確認は、
一般にしない。

理由は、状態が実在していても「無い」と読めてしまう（false negative）ため。`.git` がファイル
なので配下のパスは解決自体が成立せず、`ls` は "No such file" ではなく "Not a directory" で
落ちる。だが存在チェックの文脈ではどちらも「無い」と同義に読まれ、しかもコマンドとしては
ただの非ゼロ終了なので、誤りに気づかないまま結論へ直結する。

代わりに git 自身に問う。git は worktree のレイアウトを知っているので、main working tree でも
linked worktree でも同じ答えを返す（下記コマンドは `git status` のような porcelain と
`git rev-parse` のような plumbing が混在するが、この区別はここでは関係ない。共通するのは
`.git/` 配下へ直接パスを通さず git のコマンド層を経由する点）。

```
git rev-parse -q --verify MERGE_HEAD   # 中断中の merge があるか（exit 0 なら在る）
git status                             # rebase / cherry-pick を含む中断状態の全般
git rev-parse --git-path <name>        # 内部ファイルの実体パスが要るとき（例: MERGE_MSG）。worktree/submodule でも正しい実パスを返す
```

`.git` が**ディレクトリだと確認できている**場面は、上の false negative の理由が当てはまらない
ので縛られなくてよい。ただし判定基準は「linked worktree でないこと」ではない。§1 の
`--git-common-dir` / `--git-dir` 一致判定は submodule の working tree でも「一致」を返し、
これは分類として誤りではない（submodule はそれ自体が別 repo の main working tree であり、
`--git-common-dir` と `--git-dir` は両方とも `<super>/.git/modules/<name>` を指すため）。破綻
するのは「main working tree なら `.git` はディレクトリ」という**含意**のほうで、submodule の
`.git` は `gitdir: <super>/.git/modules/<name>` を書いた 1 行のファイルである。つまり §1 の
「main working tree」という結果だけで `.git` がディレクトリだと決め打つと、submodule で
この例外がまさに防ごうとしている false negative を許すことになる。`.git` の種別は
`test -d .git` 等で別途確かめてから縛りを外す。

<!-- 文脈: 別 repo での monorepo 作業中、main を merge して衝突解消の途中で
     git commit が hook のタイムアウトで中断した際、`ls .git/MERGE_HEAD` で状態を
     確認して「マージが失われた」と誤認しかけた incident。`.git` がファイルである
     ためパス probe が成立していなかっただけで、`git rev-parse -q --verify
     MERGE_HEAD` では MERGE_HEAD は実在し、そのまま復帰できた。根本: worktree の
     レイアウトを確認せず main working tree と同じ前提でファイルパスを直接叩いたこと。 -->

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

### 5. main working tree にいるなら、実装作業は既定で委譲する

**トリガー**: §1 の判定で `--git-common-dir` と `--git-dir` が **一致** する（= linked worktree
ではなく main working tree にいる）。かつ、WHAT の固まった、commit を伴う実装作業に着手しようと
している。

**既定の行動**: その場で `git switch -c` して編集を始めない。`delegate-to-worktree` skill 経由で
`claude-worktree` に委譲し、実装は新しい worktree の中で走らせる（分岐の手順は §6）。

main checkout は「いつ来ても clean な main である」ことが期待される共有の起点だから、既定を
委譲側に置く。feature branch を切って占有すると次の実害が出る。

- **以降の作業がその feature branch 上で始まる**: 次の調査や別依頼をこの checkout で受けたとき、
  無関係な feature branch を土台にしてしまう。
- **手戻りをユーザーに要求する**: 「main に戻して」という後始末の指示が要る。委譲していれば
  main checkout はそもそも動いていない。
- **自走ラインに乗らない**: 委譲先は `acceptEdits` + `pr-review-automerge` で実装から merge まで
  自律的に進む。main checkout でインラインに進めると、その仕組みに乗らず人間が逐一伴走する形になる。

**例外**（ソフト指針。当てはまるなら委譲せずこの場で進めてよい）:

- 調査・read-only の確認・質問への回答など、commit を伴わない作業
- ユーザーが「この場でやって」「ここで直して」等、main checkout での実行を明示的に指示した場合
- worktree を切るまでもない一手で終わる修正。ただし **PR を出して review → merge まで回す規模なら
  小さく見えても委譲側に倒す**（PR を伴う時点で、branch 占有が上記の実害を full に踏む）

linked worktree にいる場合はこの節のトリガーに当たらない。既に隔離された作業ツリーにいるので、
既定はその worktree 内で進める（§6 末尾）。

<!-- 文脈: main checkout の session が「不要 skill を削除して」を受け、委譲せずその場で feature
     branch を切って commit / push / PR まで走り、main checkout が占有されてユーザーから「main に
     戻して」の手戻り指示が要った incident。根本: §6 は分岐を「並行作業の選択肢」としか書かず
     末尾で抑制していたため、main working tree にいるときの既定＝委譲というトリガーが無かった。 -->

### 6. 作業を別 worktree へ分岐する（`claude-worktree`）

今の worktree の作業を止めずに、独立した別ラインの作業を切り出したいときは `claude-worktree`（`bin/`）を使う。現在 worktree への変更はそのまま残り、分岐先は別ディレクトリ・別ブランチで進む。

```
claude-worktree [--self] [--tmux] [--model <alias>] [--seed <path>]... <name> [-b <branch>] [-- <prompt...>]
```

- worktree は `<メインリポジトリ toplevel>_<name>` に作られる（メイン基準なので worktree 内から切ってもパスがネストしない。区切りは tmux 安全な `_`。`.` は `tmux -t` の `window.pane` 構文と衝突するため不可）
- `-b` 省略時はブランチ名 = `<name>`。解決順はローカルブランチ優先 → 無ければ `origin/<branch>` を追跡 checkout → どちらにも無ければ新規作成。fetch はしない（未 fetch なら新規作成に落ちる）
- `--` の後ろにプロンプトを渡すと、**既定では `claude --bg`（background agent, `acceptEdits`）が worktree dir で起動する**。tmux session も pane も作らない。委譲先はタスクを完遂しても session を終えず `idle` で残るので、委譲元が下記のとおり閉じる（**worktree も残る**ので、後片付けは §7 の `git-reap-gone`）。到達は `claude attach <short-id>`（`claude-worktree` が stdout に出す）か、claude-queue の picker（`C-q q`）から。承認待ちで止まった委譲先へ入る経路もこれ
- `--tmux` を付けると従来どおり **detached tmux セッション（名前 = worktree basename）を作り、その pane で interactive claude を起動**する。人間が同席して協同する委譲（HOW をその場で詰める等）に使う。`gts <session>` でいつでも attach でき、REPL に留まる
- `claude-worktree` が委譲元 session の name を解決し、プロンプト末尾へ `## 委譲元` 節（`報告先 name: <name>`）を自動付加する（`--tmux` 経路でも同じ。解決できないときは何も付かない）。委譲先はこれを受け取り、完了・不足・中断を SendMessage で委譲元へ報告する。**permission 承認だけはこの経路に乗らない**（tool call の途中で凍結するため委譲先自身が動けない）。承認は人間が attach して行う
- 委譲元は委譲先から完了報告を受けたら、質問へ返信したかに関わらず `claude-stop-bg <short-id>` で閉じる（§7 の後片付けと同じく、保守的なラッパー経由で行う）。自然終了に任せない理由は 2 つ: 委譲先は完遂しても `idle`（承認待ちの `status: waiting` とは別状態）で次の入力を待ち続け、放置すると約 60 分居座る。しかもその自然消滅では `SessionEnd` が飛ばないため claude-queue の `terminated_at` が NULL のまま幽霊行が残る。追跡がきれいに閉じるのは `claude stop`（= `claude-stop-bg`）経路だけ
- プロンプト無しなら worktree 追加のみ（stdout にパスのみ出力。`git wa` の置き換え）
- `--self` は worktree の基準 repo を、cwd の repo ではなく **`claude-worktree` 自身が置かれている repo**（symlink 解決後。= dotrc）にする。無関係な project で作業中に dotrc のグローバル harness（rules / skills / bin）を切りたいときに使う。`--seed` のコピー元は `--self` の有無に関わらず cwd の checkout のまま
- `--seed <path>`（繰り返し可）は、現 checkout の `<path>` を新 worktree の同じ相対位置へコピーする。存在しない／checkout 外の seed は worktree 作成前に fail する
- 現 checkout の `.claude/worktree-seed`（1 行 1 パス、repo root からの相対。行頭 `#` はコメント）に挙げたパスは、`--seed` を渡さなくても**既定で seed される**。委譲先が無いと動けない gitignore 済み設定（token を供給する設定ファイル、ローカルの `.env` 等）を repo 側が名指しする場所で、script にファイル名を埋め込まない。明示 `--seed` と違い**挙げたパスが無いときは skip する**（fail しない）。一覧自体が無い repo も同様に何もしない。明示 `--seed` と重なっても二重コピー・二重ログにはならない。ただし絶対パスや checkout の外へ出る entry は fail する（commit されてレビューされる一覧なので、壊れた行は黙って通さない）
- この repo では `mise.local.toml` を挙げている。委譲先は既定で PR を出すので GitHub token の供給は前提であり、それを mise 経由で流しているため。ファイル自体は `_.file = "~/..."` の pointer で秘密は home 配下に残るので、worktree にも repo にも秘密は入らない
- 委譲先で token が無いときに `~/.config/gh/personal.env` 等の秘密ファイルを直接 source する回避策は使わない。`.claude/worktree-seed` 経由の供給が正規経路であり、それが効かないなら seed 側の不具合として直す
- `--model <alias>` は起動する claude のモデルを固定する（friendly alias。`opus` / `sonnet` / `haiku`）。省略すると継承した既定モデルのまま。委譲先は長時間の agentic 実行を担うので、`delegate-to-worktree` / `harness-from-feedback` は `--model opus` を付けて呼ぶ
- settings.json で allow 済み（`claude-worktree` / `claude-worktree *`、`claude-stop-bg` / `claude-stop-bg *`）なので承認なしで実行できる

分岐先は `acceptEdits` で自律的に編集を進める。タスクが自然に独立した複数ラインへ割れるときに、現在 worktree を汚さず並行で進める選択肢として使う。**既に linked worktree にいるなら**乱用は避け、分岐の必要性が薄いときはその worktree 内で進める（隔離済みなので分岐で得るものが小さい）。この抑制は main working tree にいる場合には適用しない。そこでの既定は §5 のとおり委譲する。

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

連携の全体像（git worktree を土台に、既定の background 起動（`claude --bg`）と `--tmux` の tmux セッションへ分岐し、どちらも claude-queue が追跡するという層構成と、`claude-worktree` の位置づけ）は `docs/design/claude-tmux-worktree.md` を参照。

### 7. 委譲 worktree の後片付け（`git-reap-gone`）

§6 で分岐・委譲した作業が merge され終わったら、その worktree とブランチの後始末を頼まれることがある。「後片付けして」「委譲先を片付けて」等で依頼されたら、手作業で `git worktree remove` / `git branch -d` を撃たず、`git-reap-gone`（`bin/`）を保守的 predicate で回す。

```
git-reap-gone [--no-fetch] [<branch>...]
```

- **トリガーは推論せず `[gone]` 状態**。リモートが merge 時にブランチを削除 → `git fetch --prune`（スクリプト冒頭で自動実行）で local が `[gone]` 化する、という権威ある外部イベントだけを完了の合図にする。`--no-fetch` で冒頭 fetch を抑制できる（呼び出し側／cron が fetch を制御する場合）。
- **統合先のローカルブランチ（通常 `main`）を checkout した状態で実行する**。そうでなければブランチ・worktree・working tree のいずれも触らず exit 1 し（冒頭の `git fetch --prune` は既に走っている）、どのブランチへ switch すればよいかを案内する（既に別 worktree で checkout 済みならそちらの path を案内する）。`git branch -d` は「upstream があればそれ、無ければ HEAD」の 2 択でしか判定できず base を渡せない。`[gone]` は upstream が消えた状態なので必ず HEAD 基準に落ち、HEAD が統合先でないと下の gate と別の起点を測ることになるため。続けて `$base`（`origin/HEAD`）への `git merge --ff-only` を試み、古いローカル統合先を追随させる（`--no-fetch` の有無に依らず実行。失敗しても abort せず警告して続行する — gate の安全性は ff に依存せず、失敗の帰結は skip が増えるだけで誤削除方向には倒れない）。
  - **linked worktree にいる場合は `git switch` できない**（統合先は main working tree が既に checkout 済みで、git が二重 checkout を拒否する）。この tool を呼ぶ agent 自身がまさに linked worktree 内にいることが多いので、統合先を checkout している main working tree 側で実行する。cwd がそこにズレているなら [working-directory.md](./working-directory.md) に従い `/cd` を頼んで止まる。
- **reap してよい条件（全通過のみ削除）**: ①統合先（`origin/HEAD` = 通常 `origin/main`）に対し未統合コミットが無い、②HEAD から到達可能（`git branch -d` が実際に使う判定の先取り。**worktree を消す前**に確認するので「worktree だけ消えてブランチが残る」中途半端な状態が構造的に生じない）、③worktree が紐づくならそれが clean、④その worktree が今いる worktree でない。裸ブランチ（worktree 無し）は①②のみで判定。
- **削除は安全形だけ**: `git worktree remove`（**`--force` 無し**）＋ `git branch -d`（**`-D` ではない**）。条件を欠くもの・git が拒否したものは **skip し、何が blocking か report** する。決して force にエスカレートしない。これにより dirty／別ブランチへ切替済み（→ `[gone]` ブランチに worktree が紐づかない）等で spawn 中の worktree は自動的に対象外になる。
- 引数でブランチ名を指定するとその対象だけを（同じゲートを通して）reap する。無指定なら全 `[gone]` を sweep。
- **manual 運用**。cron/janitor の常駐は当面作らない。ただし全 `[gone]` を sweep できる形なので、将来そのまま cron/loop に挿せる。
- settings.json で allow 済み（`git-reap-gone` / `git-reap-gone *`）なので承認なしで実行できる。
