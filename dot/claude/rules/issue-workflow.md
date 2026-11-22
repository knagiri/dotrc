## GitHub Issue による agent task 管理

agent が生む気づき（harness 改善案・不具合）と task を GitHub Issue に集約する運用。
`paths` を付けず常時ロードする。起票は特定ファイルの編集を伴わないので paths では発火せず、
[gh-commands.md](./gh-commands.md) と同じ扱いになる。

issue は 2 種類ある。気づきは**観測**（`kind/harness` / `kind/bug`）として重複を気にせず起票し、
日次の crawler がグループに束ねて、件数が閾値に届いたグループを構造的な改善の PR まで自動で回す。
人が明示的に頼む単発の作業は **task**（`kind/task`）として、従来どおり人間ゲートを経て消化する。
設計の根拠・却下案・既知の限界は `docs/design/agent-issue-workflow.md` を参照。

### 1. 起票経路は `gh-issue-file` だけ

agent が issue を起こすときは `bin/gh-issue-file` を使い、生の `gh issue create` は使わない。

```
gh-issue-file [--global] --kind <harness|bug|task> --title <title> --body-file <path> [--parent N] [--resolved-by <PR-URL>]
gh-issue-file [--global] --list-groups
```

dotrc 以外の repo で作業中に起票するときは `--global` を付ける。付けると template の探索・
denylist・起票先がすべて **`gh-issue-file` 自身が置かれた repo**（= dotrc）に揃う。付けないと cwd の
repo に `.github/ISSUE_TEMPLATE/<kind>.md` が無くて exit 1 になり、起票経路自体が無い。
`claude-worktree --global` と同じ意図・同じ綴り。

観測を既存のグループに付けたいときは `--list-groups` で open なグループを見て、根本原因が
合うものがあれば `--parent <N>` を付ける。迷えば付けない。外れても日次の振り分けが直す。
その場で直した指摘は `--resolved-by <PR-URL>` で起票する（close 済みで入り、件数には数える）。

生で叩くと次のゲートを迂回する。

- **本文の構造検証**: `gh issue create --title/--body` は非対話起票で issue template を適用しない
  ので、骨格を担保しているのはラッパー側だけである
- **固定 label**: 観測か task かで付く label が決まり、crawler はその label で対象を選ぶ
- **具体名の denylist**: 業務 repo のセッションからも public な dotrc へ人の目を通らずに入るので、
  ラッパーが title と本文を gitignore 済みの `.issue-denylist` と照合して止める。push した具体名は
  消せない
- **session marker**: 本文末尾に起票した session の id を付け、同じ session の重複を 1 件と数えさせる

[gh-commands.md](./gh-commands.md) §1 の表は issue 操作全般に `gh issue *` を挙げるが、**起票だけ**はこの rule が
`gh-issue-file` に狭める。閲覧（`gh issue view` / `gh issue list`）は表のとおり高位コマンドを
直接使ってよい。

### 2. exit code の読み方

| code | 意味 | 対応 |
|---|---|---|
| 0 | 起票した（`--list-groups` なら一覧を出した） | stdout の URL を報告する |
| 1 | 引数か body の不備 | stderr を読んで切り分ける |
| 3 | denylist に当たった、または denylist が無い環境で dotrc 以外の repo から起票した | 前者なら具体名を除いて書き直して再実行する。後者は起票せず、内容を完了報告に書く（denylist の作成は人が行う） |
| 128 | `--global` 無しで git repo 外から呼んだ（`set -e` 下で git 自体の失敗が素通しする） | cwd を repo 内へ移して再実行する |
| 上記以外の非 0 | gh の失敗がそのまま伝播する（`set -e` は gh の実際の終了コードを返し、1 に丸めない。実測: 未認証の gh は exit 4） | stderr を読む。委譲 worktree では token 未供給を疑う（`worktree-scope.md` §6 の既知 gap） |

code 1 は `bin/gh-issue-file` 自身の検証の失敗である。stderr が欠落見出しを名指ししていれば body
側の不備なので直して再実行、そうでなければ gh 側の失敗（label 未作成・認証エラー・ネットワーク
エラー等）なので body を直さず原因を潰してから再実行する。

### 3. task の `status/*` label と委譲の条件

| label | 意味 |
|---|---|
| `status/triage` | 起票直後。HOW が未確定でありうる。**着手しない**（委譲・インラインとも） |
| `status/ready` | HOW が確定し、着手してよい（委譲・インラインとも。§6 参照） |
| `status/delegated` | 着手済み（worktree が走っている、またはインラインで実装中） |

この表は task だけに使う。task の起票は必ず `status/triage` で入る（ラッパーが固定するので agent
の裁量では変えられない）。`triage → ready` は人間が行う。これが `delegate-to-worktree` の
「WHAT + HOW が固まっているか」という不変条件を label で表したものである。

`ready → delegated` の付け替えは**着手した側**（委譲を起こした session、またはインラインで
実装に入った session）が
`gh-issue-mark-delegated <N>`（`bin/`）で行う。ラッパーは `status/*` がちょうど
`status/ready` 1 個の issue だけを付け替え、それ以外は拒否する。この遷移に `gh issue edit` を
直接使わない。素の形は hosts.yml の token に落ちて権限不足で失敗し、`MISE_ENV=gh` を付けても
現在の label を確かめないので triage の issue にも撃てて、人間ゲートを飛ばしうるため。
直接撃つのは §6.2 の triage 経路だけである。人間不在の委譲先はこの付け替えを行わない
（担い手を「委譲」に限定すると、§6 のインライン経路で付け替え役が不在になるため）。

### 4. issue へのコメント投稿はしない

issue への reply コメントは、明示的に指示されない限り投稿しない。[gh-commands.md](./gh-commands.md) §3 の
PR reply ポリシーと同じ扱いで、既定は指摘の整理・要約・対応案の提示までに留める。

### 5. 起票してよい粒度

恒久的に効かせたい学びと、再発しうる不具合を観測として起票する。同じ気づきが既に起票されて
いそうでも控えない。別 session から同じ指摘が何度も入ること自体が優先度の信号であり、
複数の事例を横断して読めるほど構造的な改善策を設計しやすい。

そのタスク限りの症状・一過性の事象は起票しない（`harness-from-retrospective` の判断基準と
揃える）。1 回きりの気づきは閾値に届かず 30 日で閉じるだけなので害は小さいが、振り分けの
読解コストは件数に比例して乗る。

### 6. 起票で完了。消化するのは別の主体

#### 6.1 起票側

`gh-issue-file` が exit 0 を返した時点で、その気づきに対するこのセッションの task は完了
である。URL を報告して終わる。

- **起票した issue を残タスクとして数えない。** 完了報告や残タスク一覧に「#N（issue 化済み）」
  の形で載せない。issue 一覧が backlog の正典なので、セッション側に写すと二重管理になる
- 起票側が続きを持っているつもりでいると、消化の経路を飛ばして自分が実装しに行く誘惑が
  生まれる。帰属をここで切る
- task の **`status/triage → ready` を自分で付け替えない**（§3）。「ready にしてよいか」を人間に
  問うのは可。押すのは人間

#### 6.2 消化するのは誰か

観測は crawler が消化する。閾値に届いたグループごとに `claude-worktree --global` で委譲先を起こし、
委譲先は `design-from-observations` skill で観測を横断して設計し、PR を `pr-review-loop` まで回す。
merge は人間が行い、`Closes #<group>` でグループが閉じる。方針が違えば人間が理由をコメントして
PR を close し、crawler はグループを `group/rejected` にする。

task は次の経路で消化する。

| 経路 | 起点 | 実装する主体 |
|---|---|---|
| **既定** | 人間が `triage → ready` にし、そのうえで委譲を指示する | `delegate-to-worktree` が起こす別 worktree の agent |
| **名指しで引き取る** | 人間が「#N やって」と言う | 言われた session が引き取り、既定どおり worktree へ委譲する（main working tree にいる場合。[worktree-scope.md](./worktree-scope.md) §5）。既に linked worktree にいるなら §5 自身がその節をトリガーしないと言うので、その worktree 内で進める |
| **インラインを明示される** | 人間が「#N をこの場でやって」と言う | 言われた session がその場で実装（[worktree-scope.md](./worktree-scope.md) §5 の例外を明示された場合） |

どの経路でも `ready → delegated` の付け替えは着手した側が行い（§3 と同じ語）、PR 本文に
`Closes #<N>` を入れて merge で自動 close させる。

**名指しで引き取るときも §3 のゲートは飛ばさない。** `status/triage` のままの task を
「やって」と言われたら HOW が未確定でありうる。HOW をその場で人間と確定させてから着手する。
確定しないまま委譲すると委譲先が設計判断を抱え、`delegate-to-worktree` の不変条件を破る。

**`status/delegated` は「着手済み」の意味で使う。** worktree が走っている場合と
インラインで進める場合の両方を含む（§3 の label 表が正典）。着手専用の label を別に
増やさない（label が増えるほど、起票と振り分けで読む一覧が長くなるため）。

**起票と消化が同一ターンで指示された場合**（「issue に起こしてから実装して」）は 6.1 の
「起票で完了」を適用しない。その依頼は起票と消化をひとまとめにしたものなので、続けて
上表の経路へ入る。ただし §3 の label ゲートは飛ばさない。この経路に入った時点で task は
`status/triage` のままなので、ユーザーが同席している前提を使い、HOW をその場で確定させる。
**同一ターンでの実装指示自体を §3 のゲートの充足として扱ってよい**（ユーザーが `ready` を
別途明示的に押さなくても、その場の指示が「このまま着手してよい」という承認を代替する）。
この経路では label を人間に押させず、着手した側が `triage → delegated` へ直接付け替える
（6.1 の「`triage → ready` を自分で付け替えない」は、ゲートが人間の明示的な指示で満たされて
いない場合の規定であり、この同一ターン経路には当たらない）。付け替えは §3 のラッパーでは
通らない（ラッパーは同一ターンの指示の有無を区別できないので、triage からの遷移を拒否する）。
`MISE_ENV=gh mise exec -- gh issue edit <N> --remove-label status/triage --add-label status/delegated`
で撃ち、承認プロンプトを通す（ラッパーの無い書き込みの呼び方は [gh-commands.md](./gh-commands.md) §1）。

**消化側を状況から推測しない。** 緊急そうだから・文脈がロードされているから・今なら安いから、
を理由に自分で引き取らない。割り当ては人間（または crawler）が明示的に行う。

### 7. 観測とグループ

| label | 付く issue | 意味 |
|---|---|---|
| `observation` | 観測 | 1 つの気づき。中身は書き換えず、統合もしない |
| `group` | グループ（親 issue） | 根本原因を共有する観測を sub-issue として束ねる |
| `group/delegated` | グループ | 改善 PR を作る委譲先が走っている、または PR が open |
| `group/rejected` | グループ | 改善 PR が merge されずに close された。新しい観測が付くまで再委譲しない |
| `auto/structural` | PR | グループから自動で作られた改善 PR |

観測には `status/*` を付けない。振り分け・件数の集計・委譲・期限切れはすべて crawler
（`bin/issue-crawl`、日次）が行い、人間ゲートは改善 PR の merge / close だけである。数え方と
歯止め（直近 30 日・session 単位・閾値 3・同時 2 本）の正典は設計 doc にある。

crawler も委譲先も、repo owner が起票した issue だけを扱う。public な repo には誰でも issue を
書けるので、第三者の本文を自動実装の材料や指示にしないため。

グループと観測の label・親子・open/close を変えるのは crawler（とその振り分け用の `claude -p`）
だけで、書き込みは遷移を検査する `bin/gh-issue-group` を通す。agent が作業中にこれらを
直接触らない。状態を持つ主体が 1 つなら、委譲先と crawler の書き込みが食い違わない。
