## GitHub Issue による agent task 管理

agent が生む task（harness 改善案・不具合・設計課題）を GitHub Issue に集約する運用。
`paths` を付けず常時ロードする。起票は特定ファイルの編集を伴わないので paths では発火せず、
[gh-commands.md](./gh-commands.md) と同じ扱いになる。

設計の根拠・却下案・既知の限界は `docs/design/agent-issue-workflow.md` を参照。

### 1. 起票経路は `gh-issue-file` だけ

agent が issue を起こすときは `bin/gh-issue-file` を使い、生の `gh issue create` は使わない。

```
gh-issue-file --kind <harness|bug|task> --title <title> --body-file <path> [--not-dup-of N[,N...]]
```

生で叩くと 2 つのゲートを迂回する。ひとつは本文の構造検証で、`gh issue create --title/--body`
は非対話起票で issue template を適用しないため、骨格を担保しているのはラッパー側だけである。
もうひとつは重複の検出で、複数 session が独立に同じ気づきを起票するのがこの土台で潰したい形
なので、既存 task の提示を通らない起票はその目的を素通りする。

[gh-commands.md](./gh-commands.md) §1 の表は issue 操作全般に `gh issue *` を挙げるが、**起票だけ**はこの rule が
`gh-issue-file` に狭める。閲覧（`gh issue view` / `gh issue list`）は表のとおり高位コマンドを
直接使ってよい。

### 2. exit code の読み方

| code | 意味 | 対応 |
|---|---|---|
| 0 | 起票した | stdout の URL を報告する |
| 1 | 引数か body の不備 | stderr を読んで切り分ける |
| 2 | dedup ゲート | 下記のとおり候補を**読んでから**判断する |
| 128 | git repo 外から呼んだ（`root="$(git rev-parse --show-toplevel)"` が `set -e` 下で素通しする git 自体の失敗） | stderr に `fatal: not a git repository ...` が出る。cwd を repo 内へ移して再実行する |
| 上記以外の非 0 | 末尾で `exec` する `gh issue create`、または dedup ゲート手前で叩く `gh issue list` の失敗がそのまま伝播する（`set -e` は代入付き command substitution の失敗も gh の実際の終了コードのまま返し、1 に丸めない。実測: 未認証状態の `gh issue list` は exit 4） | stderr を読む。委譲 worktree では token 未供給を疑う（`worktree-scope.md` §6 の既知 gap） |

code 1 は `bin/gh-issue-file` 自身の検証の失敗であり、末尾で `exec gh issue create` した先の gh の
失敗や、dedup ゲート手前で叩く `gh issue list` の失敗はそれぞれの終了コードのまま返る（上表の
「上記以外の非 0」）。stderr が欠落見出しを名指ししていれば body 側の不備（code 1）なので直して
再実行、そうでなければ gh 側の失敗（label 未作成・認証エラー・ネットワークエラー等、
`gh issue list` / `gh issue create` のどちらでも起こりうる）なので body を直さず原因を潰してから
再実行する。

exit 2 のときは既存 agent task の一覧が stderr に出る。候補の title を読み、

- **重複していれば起票しない。** 既存 issue の番号を報告して終わる
- **重複していなければ**、提示された `--not-dup-of <CSV>` をそのまま付けて再実行する

`--not-dup-of` に番号を書くのは「一覧を実際に読んだ」ことの表明である。単なる `--force` だと
読まずに通せる。一部しか覆っていなければ再度 exit 2 になるので、前回の提示以降に増えた issue も
必ず目に入る。

### 3. `status/*` label と委譲の条件

| label | 意味 |
|---|---|
| `status/triage` | 起票直後。HOW が未確定でありうる。**委譲しない** |
| `status/ready` | HOW が確定し、委譲してよい |
| `status/delegated` | 委譲済み（worktree が走っている） |

起票は必ず `status/triage` で入る（ラッパーが固定するので agent の裁量では変えられない）。
`triage → ready` は人間が行う。これが重複を潰す人間ゲートであり、同時に
`delegate-to-worktree` の「WHAT + HOW が固まっているか」という不変条件を label で表したもの
でもある。

`ready → delegated` の付け替えは委譲を起こした session が
`gh issue edit <N> --remove-label status/ready --add-label status/delegated` で行う。
`gh issue edit` は allowlist に入っていないので承認プロンプトを踏むが、委譲を起こすのは人間が
同席する session なので摩擦は小さい。人間不在の委譲先はこの付け替えを行わない。

### 4. issue へのコメント投稿はしない

issue への reply コメントは、明示的に指示されない限り投稿しない。[gh-commands.md](./gh-commands.md) §3 の
PR reply ポリシーと同じ扱いで、既定は指摘の整理・要約・対応案の提示までに留める。

### 5. 起票してよい粒度

恒久的に効かせたい学びと、再発しうる不具合を起票する。そのタスク限りの症状・一過性の事象は
起票しない（`harness-from-retrospective` の判断基準と揃える）。判断に迷うものは起票せず、
完了報告に書いて人間の判断に回すほうが安い。issue が増えるほど dedup ゲートの提示が長くなり、
読解のコストが全 session に乗るため。

---

由来: 複数の Claude session が独立に同じような task を生み、特に harness 改善案が重複していた
こと。構造的な出所は `harness-from-retrospective` が提案までで止めて session の最終メッセージに
残す設計にあり、提案が横断的に集約される場所が無いので別 session の同じ気づきと照合できなかった。
