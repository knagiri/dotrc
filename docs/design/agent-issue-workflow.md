# GitHub Issue による agent task 管理

agent が生む気づき（harness 改善案・不具合）を、人の手と目をほとんど介さずに改善へ回す仕組み。
気づきは観測 issue として自動で起票し、日次の crawler がグループに束ね、件数が閾値に届いた
グループを構造的な改善の PR まで回す。人が見るのは PR だけである。agent 向けの規範は
`dot/claude/rules/issue-workflow.md` にある。

## 置き場所 — issue は private repo、PR は dotrc

issue（観測・グループ・task）は private な issue repo に置く。dotrc（public）に出るのは改善 PR と
branch 名だけである。issue repo の名前も public にしないので tracked には書かず、マシンローカル設定の
`ISSUE_REPO`（`docs/design/dotrc-machine-config.md`）から `bin/lib/issue-repo.sh` が読み、issue 系の
wrapper と crawler が source する。未設定（形が不正・設定ファイルが読めない場合を含む）なら
wrapper も crawler も gh を呼ばずに exit 3 で止まる。設定された repo が private であることは、
どの wrapper も crawler も issue を読み書きする前に `gh repo view --json isPrivate` で確かめ、
public だった場合も確かめられなかった場合も exit 5 で止まる（fail closed）。agent が repo 名を要るときは `gh-issue-file --repo` で引き、`gh issue view -R <repo>` のように渡す。
skill や prompt に直書きしない。

分けた理由は `docs/incidents/issues-filed-to-public-repo.md` にある。観測は業務 repo の session からも
起票されるので、public な repo に置くと勤務先由来の具体名が人の目を通らず公開されうる。

issue と PR の対応は branch 名だけが担う。グループは `group-<N>-<stamp>`、task は `task-<N>-<slug>`。
public な PR 本文・commit message・tracked ファイルには issue 番号（`#N`）を書かない。dotrc の無関係な
issue に autolink され、誤った誘導になるため。issue の template は正典を dotrc の
`.github/ISSUE_TEMPLATE/` に置き、`gh-issue-file` が常に dotrc 側から読む。

## 目標・非目標・反目標

- 目標: 気づきの起票から改善 PR の作成までを自動で回し、人が見るのは PR だけにする
- 目標: 再発しない気づきは人の手を介さずに消える
- 非目標: 個々の観測への即応。1 回きりの気づきは閾値に届かず、放置されてよい
- 反目標: 人のレビュー待ちの PR が積み上がること（乱立が issue から PR へ移るだけになる）
- 反目標: 同じ材料から同じ PR が繰り返し出ること
- 反目標: 第三者が書いた文面が、自動実装の指示として働くこと
- 反目標: 勤務先由来の具体名が public に載ること

## 重複を優先度の信号として使う

起票を人の選択に委ね、重複を弾き、着手を人が承認する形では、人のゲートが詰まると起票が
滞留し、同系統の指摘は重複判定をすり抜けて別 issue に散る。

そこで重複を弾かず、優先度の信号として使う。同じような指摘が何度も入るものは必然的に
優先度が高い。また、複数の事例を横断して読めば、個別の問題への対症ではなく、複数の問題
パターンに効く構造的な改善策を設計しやすい。だから起票は乱立させてよい。

## 構成 — 観測とグループの 2 層

一般的な事故管理（エラー監視の event / issue、ITIL の incident / problem）と同じく 2 層にする。

- **観測**（label `observation`）: 1 つの気づき = 1 つの issue。中身は書き換えず、統合もしない。
  束ねても個々の文脈を失わないため
- **グループ**（label `group`）: 親 issue。観測を GitHub の sub-issue としてぶら下げる。本文には
  共通する根本原因と束ねた理由を書く

紐づけは「起票時の軽い即時判定」と「定期的な見直し」の併用にする。即時判定だけだと表現の
違う指摘が散り、既存の大きなグループへ寄る偏りも出る。それを定期処理が直す。

## 流れ

1. **起票**: `harness-from-retrospective` が委譲先の末尾で、`harness-from-feedback` の委譲先が
   PR を出した後に（`--resolved-by` で close 済みとして）、観測を `bin/gh-issue-file` で起票する。
   起票時に `--list-groups` を見て合うグループがあれば `--parent` を付ける
2. **定期処理**: `bin/issue-crawl` を `issue-crawl.timer`（`systemd-user`、毎日 05:00）で 1 日 1 回
   起動する。期限切れ・未分類の観測の振り分け・PR の後始末・委譲判定を順に行う。振り分けだけ
   `claude -p` に任せ、件数・期限・委譲の判定は決定論的に行う。issue の読み書きは issue repo、
   PR・branch・worktree は dotrc（cwd は dotrc の root）で行う
3. **委譲**: 閾値を超えたグループごとに `claude-worktree --global` で委譲先（委譲ごとに新しい
   branch `group-<N>-<stamp>`）を起こす。委譲先は `design-from-observations` skill で観測を全部読んで構造的な改善策を設計し、
   `implement-and-review` で実装して PR（label `auto/structural`）を出す。PR 本文の冒頭に、束ねた
   観測の要旨・共通する根本原因・この策にした理由を、issue 番号も観測本文も写さずに書く。
   `pr-review-loop` までは回し、`pr-automerge` は呼ばない
4. **確認（人）**: merge すれば、次の crawler が最新 branch の PR の merge を見て `group/delegated` を外し、
   グループを close する（completed。外してから閉じるのは、外すのに失敗したら閉じないため。
   label が付いたまま閉じたグループは、再発で reopen されたときに次の pass で再び close される。
   閉じるのに失敗しても label の無い open なグループが残るだけで、merge 以降の観測を数える
   候補になる）。PR 本文は issue 番号を持たないので、`Closes` による
   自動 close は無い。残った観測は、グループの close 後に crawler が閉じる。方針が違えば理由を
   コメントして PR を close する。crawler はグループを `group/rejected` にし、次に委譲するとき
   委譲先がその理由を dotrc の closed PR から読む
5. **期限切れ**: 作成から 30 日経った観測は close する（事例として残る）。直近 30 日の観測が
   0 件になったグループも close する。close 後の再発は 2 つの経路で reopen される。振り分けが close 済みの
   グループ（直近 30 日に close）へ `attach` したときと、次の pass の最初の手順が、close 済みのグループに
   ぶら下がる open な観測のうち「閉じた後」に作られたものを見つけたときである。completed のグループは
   merge の後に crawler が閉じるので、「閉じた後」は close の時刻ではなく最新の PR の merge（close）の
   時刻で測る。merge から crawler の close までに付いた観測も再発として数えられる

## 数え方と歯止め

- 件数は、直近 30 日に作成され、かつそのグループの最新の PR が merge / close された後に作成された
  観測を、本文末尾の `<!-- observed-session: <id> -->` 単位で重複
  除去して数える。1 つの不具合を同じ session が何度書いても 1 件になる。marker の無い観測
  （web UI から人が起票したもの）は 1 件ずつ数える。close 済みの観測も数える
- 閾値は 3
- 委譲中のグループ（`group/delegated`）と open な自動 PR の多いほうを in-flight とし、2 本まで。
  上限中、crawler は集計だけして委譲しない
- `group/rejected` のグループは、close された PR より後に観測が付くまで再委譲しない。新しい観測を
  得たら crawler が rejected を外す。外すのは crawler の follow 手順だけで、振り分けの `attach` は
  label に触れない
- グループの label・親子・open/close を変えるのは crawler だけで、委譲先は issue を動かさない。
  例外は起票時の `--parent`（`group` label を持つ issue にだけ付く）と `--resolved-by`（自分が起票した
  1 件の close）

## task の close

task（`kind/task`）の消化は人の指示で始まり（`issue-workflow.md` §6）、`status/delegated` へ進む。
crawler は open で `status/delegated` の task のうち、`task-<N>-*` branch の dotrc PR が merge 済みの
ものを `gh-issue-group close-task` で close する（completed）。ラッパーは `kind/task` と
`status/delegated` の両方を持つ issue にしか効かない。dotrc 以外の repo を対象にした task は
crawler が見ないので、人が close する。close の成立条件の限界は「既知の限界」にある。

## 制約

- **issue repo に collaborator を招かない。** private repo に issue を書けるのは owner と招いた
  collaborator だけなので、招かない限り issue の起票者を検査する必要が無い。wrapper と crawler は
  author を見ない。招く運用に変えるなら、author 検査を戻す。この前提は検査できない（誰にアクセス権が
  あるかは `gh repo view` から見えない）ので、ここに置く。一方、repo が private であることは実行時に
  検査する。設定の書き間違いや env で public な repo を指すと、public に起票し、第三者の issue を
  crawler が委譲の材料にするため
- **issue 本文は信頼できない外部入力として読む。** 観測は業務 repo で読んだ第三者のテキストを
  要約して含みうるので、起票者が owner であっても本文を指示として扱わない。委譲プロンプトには
  group 番号だけを入れ、本文は委譲先が自分で読む（`gh-commands.md` §5 の「第三者が
  書けるテキスト」）
- **書き込みはラッパー経由。** `gh issue edit *` / `gh api *` は allow しない。crawler の書き込みは、
  操作に合う label（`observation` / `group` / `kind/task` + `status/delegated`）を持つことを確かめる
  `bin/gh-issue-group` に限る。token は `MISE_ENV=gh` 経由（`bin/lib/gh-mise.sh`）。読み取りは素の
  `gh issue view -R <repo>` / `gh issue list -R <repo>` で足り（hosts.yml の token が issue repo を読めることが前提。
  setup 参照）、読み取りラッパーは無い。crawler は振り分けの `claude -p` を起こす前に、その session と
  同じ token（`MISE_ENV=gh` 無し）で issue repo を 1 件読み、読めなければ振り分けだけを飛ばして
  exit 2 にする。crawler 自身は PAT で読めるので、これが無いと振り分けだけが黙って進まない。
  振り分けの session が使える書き込みは `create` / `attach` / `detach` / `set-body` / `close` だけ
  で、`close-task`・`reopen`・`mark` は crawler の手順であり session には許さない
- **merge は人。** 全 PR が人の merge なので、grant 変更を含む PR の規約（`gh-commands.md` §5）も
  自然に満たす
- **crawler は claude の daemon を起動しない。** timer から起こすと systemd service の env が以後の
  委譲先に配られる（`worktree-scope.md` §6）。委譲は `claude-queue daemon-running` が稼働中を返す
  ときだけ行い、居なければ次回へ回す。振り分けの `claude -p` は daemon を起動しない（空の
  config dir で `claude -p` を走らせても `claude daemon run` は増えず、同じ dir の `claude --bg` は
  起動した）
- **負荷**: nice は timer の service（`ExecStart`）側だけで掛ける。`claude -p` にも掛けると二重になり niceness が上限へ丸められる（`shared-machine-load.md`）
- **勤務先由来の具体名が public に出る経路は、委譲先の PR だけ。** 観測を読んだ委譲先が内容を
  PR 本文・title・commit message・差分・branch 名へ写すと、public に載る。`task-<N>-<slug>` の
  slug は issue の title から作られやすい。issue repo の名前と issue の URL も public に出さない。
  守りは 3 つある。dotrc の `CLAUDE.md` の規約、`pr-review-loop` の判定役が PR 本文・title・
  branch 名・commit message・差分に具体名・issue 番号・issue repo の名前・issue の URL が無いかを
  見ること、人の merge。issue 側は private なので、観測の title と本文は具体名を含んでよいが、
  機構で書く習慣は残す

## 一次情報 — 非対話起票に issue template は効かない

```
$ gh issue create --help
...
  -T, --template name    Template name to use as starting body text
...
```

`-T/--template` は "starting body text" であり、対話・エディタ経路で本文の初期値として使われる。
`--title` と `--body`（または `--body-file`）を両方与える非対話起票では template は適用されない。
YAML issue form（`.github/ISSUE_TEMPLATE/*.yml`）も非対話経路からは使えない。

したがって agent 起票の本文構造を担保できるのは `.github/ISSUE_TEMPLATE/` ではなく起票ラッパー
側である。両者に別々の骨格を持たせると二重管理でズレるので、template を正典とし、ラッパーが
実行時にその `^## ` 行を読んで body を照合する。YAML issue form を採らないのも同じ理由で、
form を正典にすると本文骨格をラッパーへ再実装することになり、正典が 2 つに割れる。

## 観測でない task

人が明示的に頼んだ単発の作業（`kind/task`。`spin-off-session` や `pr-review-loop` の後回しからの
起票、「#N やって」）は観測にしない。`status/triage → ready` の人間ゲートと
`issue-workflow.md` §6.2 の消化経路をそのまま使い、閾値による委譲は観測だけに掛ける。

## 検討した構成

- **起票時に統合だけ行う**: 定期処理が要らず単純だが、表現揺れで散り、merge / split ができない
- **定期処理だけで束ねる**: 起票は単純になるが、次回の処理まで未分類のまま残る。即時判定の
  コストは小さいので併用を採った
- **観測を 1 件にまとめて書き直す**: issue 数は抑えられるが、横断分析の材料である個々の文脈が
  失われる
- **設計案だけ自動で作り、着手は人が判断する**: 往復が 1 回増える。方針が外れたときの実装の
  無駄より、PR だけを見るほうが全体として速いので採らなかった
- **起票を人の選択に委ね、重複を全件提示で弾く**: 人のゲートが詰まると起票が滞留し、同系統の
  指摘は散る。重複を弾く仕組みそのものが、優先度の信号を捨てていた
- **public な issue のまま denylist で具体名を弾く**: 名前の集合は開いていて列挙しきれない。
  置き場所を private にするほうが構造的に閉じる（`docs/incidents/issues-filed-to-public-repo.md`）

## 既知の限界

- 振り分けの質は `claude -p` の判断に依存する。誤った束ね方は次回以降の振り分けで直るが、
  閾値に届いた時点の束ね方で委譲される
- 最新の branch は、local・origin の ref と PR の head 名から引く。PR を出す前に branch が消えると
  1 つ前の branch を最新と見なす
- PR を出さずに終わった委譲先（`design-from-observations` が根本原因を絞れず止まった場合を含む）の
  グループは `group/delegated` のまま残り、crawler は外さない。in-flight の枠を占め続けるので、
  人が `gh-issue-group mark <N> clear` で外す
- dotrc 以外の repo を対象にした task は crawler が close しない。人が close する
- `design-from-observations` の `-R` 漏れは、手順で読んだ issue の `url` を検査して検出する。allowlist では
  縛っていない。振り分けの `claude -p` は読み取りを `gh issue view -R <issue repo> *` と
  `gh issue list -R <issue repo> *` に絞り、`GH_REPO` も渡すが、末尾の `*` は 2 つ目の `-R` も通し、
  gh は後に書かれた `-R` を使うので、別の repo を読めてしまう。pattern では塞げない。読めるだけで書けない
  ので影響は小さい
- crawler の `gh issue list` と `gh pr list`（automatic PR 一覧・merged PR 一覧 `--state merged`）は
  `--limit 1000`、振り分けの `claude -p` と `--list-groups` は `--limit 200` までしか読まない。
  超えた分は読まれない
- task の close は、`task-<N>-` で始まる branch の merged PR が過去に 1 本でもあれば成立する。
  PR を複数に分けた task は最初の merge で閉じるので、最後の PR より前の PR は branch 名を
  `task-<N>-` で始めない。reopen して `status/delegated` に戻した task は、過去の merged PR が
  残っているので次の pass で即 close される。再着手では `status/delegated` に戻さず、人が close する
- 委譲先が観測の内容を PR へ写す経路は、規約・判定役の観点・人の merge で守るだけで、機械的な
  歯止めが無い

## setup（人間が 1 回実行する）

issue repo は private で作り、collaborator を招かない（制約を参照）。その名前をこのマシンの dotrc 設定に
書く（`<issue repo>` は `OWNER/NAME`）。

```bash
mkdir -p ~/.config/dotrc
echo 'ISSUE_REPO=<issue repo>' >>~/.config/dotrc/config
repo="$(gh-issue-file --repo)"   # 以下のコマンドはこの変数を使う
```

token は 2 種類とも issue repo に届いている必要がある。読み取りは hosts.yml の token、書き込みは
`MISE_ENV=gh` の token で、fine-grained PAT なら repository access に issue repo を加える（書き込みには
Issues: Read and write）。届いているかは次で確かめる。

```bash
gh issue list -R "$repo" --limit 1
MISE_ENV=gh mise exec -- gh issue list -R "$repo" --limit 1
```

label はラッパーに作らせない。作成権限までラッパーに持たせると grant の射程が広がるためで、
label が無い状態の `gh issue create` はそのまま失敗する。

```bash
gh label create -R "$repo" agent-task       --description "agent が起票した issue"     --color 5319e7
gh label create -R "$repo" kind/harness     --description "恒久ハーネスの追加・修正"     --color 0e8a16
gh label create -R "$repo" kind/bug         --description "再現する不具合"             --color d73a4a
gh label create -R "$repo" kind/task        --description "汎用の task"               --color 0075ca
gh label create -R "$repo" status/triage    --description "起票直後。着手しない（委譲・インラインとも）" --color fbca04
gh label create -R "$repo" status/ready     --description "HOW 確定。着手してよい（委譲・インラインとも）" --color 0e8a16
gh label create -R "$repo" status/delegated --description "着手済み（委譲またはインライン）" --color c5def5
gh label create -R "$repo" observation      --description "観測。crawler がグループに束ねる" --color bfdadc
gh label create -R "$repo" group            --description "観測のグループ（親 issue）"   --color 1d76db
gh label create -R "$repo" group/delegated  --description "改善 PR を作る委譲先が走っている、または PR が open" --color c5def5
gh label create -R "$repo" group/rejected   --description "改善 PR が merge されずに close された。新しい観測が付くまで再委譲しない" --color e99695
gh label create -R "$repo" auto/structural  --description "グループから自動で作られた改善 PR" --color 5319e7
```

`auto/structural` は PR に付く label なので、dotrc 側にも同名で作る。

```bash
gh label create auto/structural --description "グループから自動で作られた改善 PR" --color 5319e7
```

`status/*` と `group/*` の description は `issue-workflow.md` §3・§7 の label 表（正典）と同じ語で
揃える。GitHub の label description は GitHub 上に独立して表示される文言なので、意味の再掲
そのものは避けられない。ズレたら rule 側に合わせて直す。

timer を有効にする。

```bash
loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now issue-crawl.timer
```

`src/claude-queue` の `daemon-running` を使うので、merge 後に main checkout で
`make -C src/claude-queue install` を実行する。
