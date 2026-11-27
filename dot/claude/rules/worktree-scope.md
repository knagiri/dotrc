## worktree 作業スコープのルール

git worktree（linked worktree）内で起動された Claude Code は、**明示的に指示されない限り、その worktree ディレクトリ内の作業に閉じる**。
別 worktree・main チェックアウトへ作業を波及させない。

スコープの単位は **worktree ディレクトリであって、単一ブランチではない**。1 つの worktree 内でブランチを切り替えたり、新規ブランチを起こして PR を積み上げたりする運用は通常想定であり、妨げない。

関連ルール: 許可設定の仕組みは [claude-settings.md](./claude-settings.md)、承認が要るコマンドの回避は [bash-command-constraints.md](./bash-command-constraints.md) を参照。作業対象の dir が cwd とズレて `cd`/`git -C` で渡り歩きたくなったら、[working-directory.md](./working-directory.md) に従い `/cd` で cwd 自体を移す（§3 の read-only 覗き見はその例外）。

### なぜ閉じるのか

worktree は並行作業を**隔離**するために切られ、ユーザーがそこで Claude を起動した時点で、作業対象はこの worktree だと表明している。境界を越えると次の実害が出る。

- **他作業ツリーへの巻き込み**：別 worktree は別ブランチを checkout しており、編集するとユーザーが並行作業中の場所に予期しない変更が混入する。
- **意図の逸脱**：レビュー対象が他ツリーへ散らばって差分が追えなくなる。
- **二重チェックアウトの破綻**：git は同一ブランチを 2 つの worktree で同時に checkout できないので、他 worktree が持つブランチへの `switch` は失敗する。

### 1. 自分が linked worktree にいるかの判定

```
git rev-parse --git-common-dir --git-dir   # 不一致なら linked worktree、一致なら main working tree
git rev-parse --abbrev-ref HEAD            # 現在ブランチ
git worktree list                          # worktree ↔ ブランチ対応
```

いずれも settings.json の allow（`git rev-parse *` / `git worktree list`）に含まれ、承認なしで実行できる。

#### 状態の確認は `.git/` のパスを直接見ず、git コマンドに問う

linked worktree の `.git` はディレクトリではなく、`gitdir: <path>` を書いた 1 行のファイルである。
したがって `ls .git/MERGE_HEAD` / `cat .git/HEAD` のようにパスを直接叩く確認は、一般にしない。
配下のパスは解決できず "Not a directory" で落ちるが、存在チェックの文脈では「無い」と同義に
読まれ、状態が実在していても誤りに気づかないまま結論へ直結する（false negative）。

代わりに、worktree のレイアウトを知っていてどちらの working tree でも同じ答えを返す git に問う。

```
git rev-parse -q --verify MERGE_HEAD   # 中断中の merge があるか（exit 0 なら在る）
git status                             # rebase / cherry-pick を含む中断状態の全般
git rev-parse --git-path <name>        # 内部ファイルの実体パスが要るとき（例: MERGE_MSG）
```

`.git` がディレクトリだと確認できている場面では縛られなくてよい。ただし判定基準は「§1 で
main working tree と出たこと」ではない。submodule の working tree も §1 では一致を返すが、
その `.git` はファイルである。`.git` の種別は `test -d .git` 等で別途確かめる。

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

**トリガー**: §1 の判定で main working tree にいる。かつ、WHAT の固まった、commit を伴う実装作業に
着手しようとしている。

**既定の行動**: その場で `git switch -c` して編集を始めない。`delegate-to-worktree` skill 経由で
`claude-worktree` に委譲し、実装は新しい worktree の中で走らせる。

main checkout は「いつ来ても clean な main である」ことが期待される共有の起点だから。feature
branch で占有すると、次の調査や別依頼が無関係な branch を土台に始まり、「main に戻して」という
後始末をユーザーに求めることになる。委譲先は実装から merge まで自律で進むが、インラインでは
その仕組みに乗らず人間が逐一伴走する形になる。

**例外**（ソフト指針。当てはまるなら委譲せずこの場で進めてよい）:

- 調査・read-only の確認・質問への回答など、commit を伴わない作業
- ユーザーが「この場でやって」「ここで直して」等、main checkout での実行を明示的に指示した場合
- worktree を切るまでもない一手で終わる修正。ただし **PR を出して review → merge まで回す規模なら
  小さく見えても委譲側に倒す**（PR を伴う時点で、branch 占有が上記の実害を full に踏む）

linked worktree にいる場合はこの節のトリガーに当たらず、その worktree 内で進める。そこから
さらに別 worktree へ分岐するのも、独立した別ラインに割れるとき以外は避ける（隔離済みなので
分岐で得るものが小さい）。

### 委譲まわりで常に守ること

委譲の手順（`claude-worktree` の使い方、委譲プロンプトの組み方、報告を受けた後の閉じ方・
PR 監視・再委譲）は `delegate-to-worktree` skill、担当範囲外のタスクの切り出しは
`spin-off-session` skill、委譲先が返す成果物の置き場所は `implement-and-review` skill にある。
どの session でも効かせたいものだけをここに置く。

- **秘密ファイルを直接 source して token 不足を回避しない**（`~/.config/gh/personal.env` 等）。
  shell の env に token が無いのは、個人 PAT を `gh-*` wrapper の呼び出し時にだけ読む設計の結果で
  あり意図した状態である。env に載せた token は以後の全委譲先へ配られる。`gh-*` wrapper を
  使ってもなお token が届かず失敗するなら、回避策を撃たず委譲元へ報告する（仕組みは
  `dotrc/docs/design/claude-tmux-worktree.md`「委譲先の env と token」節）。
- **merge 済みの委譲 worktree とブランチの後片付けは、手作業の `git worktree remove` /
  `git branch -d` ではなく `git-reap-gone` を、統合先（通常 `main`）を checkout した main working
  tree で回す**。手作業では未統合 commit や dirty な worktree の確認が漏れるが、`git-reap-gone` は
  保守的な条件を全部通ったものだけを force 無しで消す。linked worktree からは統合先を checkout
  できないので、cwd がずれていれば `/cd` を頼む（条件の詳細は
  `dotrc/docs/design/claude-tmux-worktree.md`「委譲 worktree の後片付け」節）。
