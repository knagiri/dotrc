# gh ラッパー（`bin/gh-*`）の設計

`bin/` の `gh-*` ラッパーがなぜ存在し、なぜその形をしているかを書く。各ラッパーの呼び方と
終了コードの扱いは、使う側の正典（rule / skill）にある。終了コードの意味（契約）は各ラッパーの
ヘッダコメントが持つ。

| ラッパー | 使い方の正典 |
|---|---|
| `gh-pr-comments` / `gh-pr-checks` / `gh-pr-create` / `gh-pr-edit-body` | `dot/claude/rules/gh-commands.md` §1 |
| `gh-await-reviews` / `gh-list-threads` / `gh-resolve-thread` / `gh-reply-thread` | `dot/claude/skills/pr-review-loop/SKILL.md`「使うラッパー」 |
| `gh-automerge <PR> [<SHA>]` | `dot/claude/skills/pr-automerge/SKILL.md`「`gh-automerge` の契約」 |
| `gh-automerge --disable <PR>` | `dot/claude/skills/implement-and-review/SKILL.md` 手順 4 |
| `gh-request-approval <PR> <SHA>` / `gh-request-approval --enabled` | `bin/gh-request-approval` のヘッダ（下の「`gh-request-approval`」） |
| `gh-issue-file` / `gh-issue-mark-delegated` / `gh-issue-group` | `dot/claude/rules/issue-workflow.md` |

allowlist にどう載せるかは `dot/claude/rules/claude-settings.md`「gh コマンドの allow 方針」。

## 書き込み用 token の供給

`bin/` の gh ラッパーはすべて `bin/lib/gh-mise.sh` を source し、`MISE_ENV=gh` を付けた 1 回の
`mise exec` で書き込み用の個人 PAT を載せて gh を呼ぶ。PAT を shell の env に置かないのは設計上の
意図で、理由は `bin/lib/gh-mise.sh` のヘッダと `dotrc/docs/design/claude-tmux-worktree.md`
「委譲先の env と token」にある。`gh-issue-file` の設計理由（起票経路を 1 つに絞る理由）は
`docs/design/agent-issue-workflow.md` にある。

## grant を最小化するためにラッパーを置く

自律的な review→merge ループ（`pr-review-loop` / `pr-automerge`）の判定役・修正役は、信頼できない
PR コメントを読んで自律実行する。raw な `gh pr merge *` / `gh api graphql *` / `gh pr edit *` を
allow すると、prompt injection 1 つで任意の mutation・protection バイパス・PR の書き換えに届く。
そこで操作を 1 種類に固定したラッパーだけを allow する。

- **フラグを素通ししない。** 特に `gh-automerge` は `--admin` 等の protection バイパスフラグを
  付けられない。merge method は `--merge`（merge commit）で、logical commits を潰さない
- **例外は `gh-pr-create` だけ**で、全フラグを素通しする。包んでいるのは grant の広さではなく
  env（`MISE_ENV=gh` の token）で、`Bash(gh pr create *)` が既に allow 済みである以上、
  `Bash(gh-pr-create *)` は権限を広げない。base 決定や diff の作法は `my-create-pr` 側に残る
- **thread への reply は `gh-reply-thread` に限る。** thread への reply は raw な `gh api` でしか
  撃てず（GraphQL mutation でも REST の `pulls/<N>/comments/<id>/replies` でも）、それを allow
  すると任意の endpoint・query・mutation が通る。ラッパーは thread の起点コメントの author を
  read-only query で引き、`__typename` が `Bot` のときだけ `addPullRequestReviewThreadReply` を撃つ
  ので、人間が起こした thread へ reply する経路が構造的に塞がる。見るのは起点コメントだけなので、
  bot 起点の thread に人間が加わった場合は止まらない（利用側の責務）
- **PR 本文の更新は `gh-pr-edit-body` に限る。** 素の `gh pr edit` は title / base / reviewer /
  label まで書き換えられる。ラッパーは `gh pr edit <PR> --body-file <file>` だけを撃つ
- **issue の label 遷移はラッパーが現在の label を検査してから撃つ。** 素の `gh issue edit` は
  任意の label・title・本文を書き換えられ、triage の issue にも撃てて人間ゲートを飛ばしうる。
  `gh-issue-mark-delegated` は `status/*` がちょうど `status/ready` 1 個のときだけ付け替える。
  `gh-issue-group` は対象を `gh issue view -R <repo> --json state,parent,labels` で読み、操作に
  合う label（`observation` / `group`。`close-task` は `kind/task` と `status/delegated` の両方）を
  持つときだけ、操作ごとに固定した `gh issue create` / `edit` / `close` / `reopen` を撃つ（attach は
  既に親を持つ観測を拒否する）。起票者は見ない（issue repo は private で collaborator を招かない
  前提。`docs/design/agent-issue-workflow.md`）

ラッパーは **repo 単位**で、特定 PR に固定されない（`gh-automerge <別PR>` も allowlist 上は通る）。
`--auto` は branch protection / required checks を尊重するので、未通過の PR を強制 merge はできない。
fallback の直接 merge も同じで、ゲートを掛けるのは GitHub 側の branch protection であり、ラッパーは
バイパスフラグを一切付けない。

## `gh-automerge` の clean 拒否 fallback

GitHub は `mergeStateStatus` が `CLEAN` の PR に auto-merge を張るのを拒否する（待つものが無いため。
stderr に `clean status`）。CI workflow を持たない repo は PR 作成直後にこの状態へ入るので、
fallback が無いと auto-merge が構造的に届かない。そこでこの拒否 1 種類にだけ
`gh pr merge --merge <PR>` へ落ちる。それ以外の失敗（required check 未達、conflict、repo で
auto-merge が無効、など）は fallback せず終了コードごと返す。auto-merge が無効な repo では
fallback は効かず、merge ステップは完了しない。

## `gh-automerge` の grant 変更ゲート

grant 変更を含む PR を auto-merge させない規約の正典は `pr-automerge` skill にある。しかし
その規約を守る場面は `pr-automerge` を呼ばない場面なので、正典の本文が読まれる経路が無い。
読み落としたまま呼ばれても止まるよう、allowlist で許可された唯一の merge 経路である
`gh-automerge` が merge の前に PR の差分を見て、grant 変更があれば merge を撃たずに exit 5 で返す。判定条件はラッパーの
ヘッダが正典である。

判定は取りこぼしを許さず過検出を許す側に倒す。過検出のコストは人間の approve を 1 回挟む
ことだけだが、取りこぼすと広い grant が人目を通らず main へ入る。settings ファイルはファイル
単位で拾う（permissions 以外の hooks・env も実行されるものを変える）。SKILL.md / agent 定義は
frontmatter だけが grant に効くので、base と head の frontmatter を比べ、本文だけの変更は通す。
hunk の位置で判定しないのは、frontmatter の長さが差分からは分からず、frontmatter をまたぐ
hunk を取りこぼしうるため。差分や内容が読めないときは grant 変更とみなして止める（fail
closed）。frontmatter を比べるファイルは、base と head のどちらかで frontmatter を検出できなければ
（1 行目で開かない・閉じない）比較できないので止める。検出できない同士を
空文字列の一致として通すと、frontmatter の書き方を崩すだけで素通りするため。

symlink（mode 120000）は、パスによらず差分のどこかに現れたら止める。`skills/<new>` や
`agents/<dir>` に skill・agent を含むディレクトリへの link を足すと、ファイル名が一致しないまま
deploy 後の frontmatter（grant）が増える。repo に symlink は無いので、過検出のコストはほぼ無い。
差分は `gh pr diff`（SHA を取れない）ではなく `compare/<tip>...<head>` を diff media type で取る。
`<tip>` は base branch の現在の tip で、`baseRefName` を読んで `git/ref/heads/<baseRefName>` で SHA に
解決する。PR の `baseRefOid` は base が進んでも更新されない snapshot なので使わない（head が新しい base を
merge したうえで base 側の frontmatter 変更を戻すと、snapshot 起点の compare ではその file が無変更に見えて
漏れる）。three-dot は merge base 起点なので merge が持ち込む範囲と同じになり、判定した diff と固定する
head が同じ commit にそろう。大きな差分の diff media type の挙動（打ち切り・件数上限・エラー）は公式 docs に
記述が無く、200 でファイルが欠ける可能性を排除できない。そこで判定したファイル数を同じ呼び出しで読んだ
`changedFiles` と照合し、不一致、`changedFiles` が数値でない、または 300 以上（compare の `files`
配列の上限。完全性の保証が無い）のときは止める。

ゲートが見るのは settings ファイルと frontmatter だけである。`bin/` の allowlist 済み wrapper の
本体、スクリプトに書いた `--permission-mode` / `--allowedTools`、hook の実体、deploy の link map
の変更は通る。これらは人間側の規約で担保する。grant 変更を含む PR では、委譲プロンプトで
`pr-automerge` を呼ばせず、merge は人間が approve してから行う。ゲートの範囲を広げて機械的に
止めることはしない。広げるほど過検出（人間の approve を挟む回数）が増え、判定の根拠も
frontmatter のような構造から外れるため。

判定した head は `--match-head-commit` で固定する。ゲートが見るのは判定時点の head の差分だが、
auto-merge は有効化後に push された commit ごと merge しうる（write 権限者の push では
auto-merge は解除されない）。固定しないと、ゲート通過後に grant 変更を push すれば素通りする。
gh はこの SHA を `expectedHeadOid` として auto-merge 有効化と直接 merge の両方の mutation に渡す。
直接 merge では GitHub が head の一致を merge の条件として明記しているが、auto-merge 有効化では
「期待する head OID」としか書かれておらず、後の push での挙動は文書化されていない。そのため
auto 経路では保証ではなく打てる最善の手当てであり、auto-merge が有効な PR へ push する側は先に
`--disable` で解除する（下記）。`--match-head-commit` が確かめられるのは auto-merge の有効化時と
fallback の直接 merge 時だけで、有効化された auto-merge の要求は期待する head を保持しない。有効化後に
push された head を締め出すのは `--disable` の規約と、repo が有効にしていれば push 時の stale review の
dismiss である。

省略可能な `<SHA>`（40 桁の小文字 hex。gh を呼ぶ前に検証する）を渡すと、ゲートが読んだ head が
`<SHA>` と一致することを確かめ、一致しなければ merge を撃たずに exit 6 で返す（3 は `--disable`、5 は
ゲートが使い、gh 自身は 0/1/2/4 を文書化している）。これで判定・固定する head が呼び出し側の見た SHA
そのものになる。`<SHA>` を省いた挙動は従来どおり（読んだ head を固定する）。`--disable` 形は `<SHA>` を
受け付けない。

gh は cwd の repo の main working tree を基準にした `gh_mise` で呼ぶ（`gh_mise_main_root`）。linked
worktree の tracked な `mise.toml` はどの branch からでも変えられるので、そこを基準にすると merge の
呼び出しへ `GH_TOKEN` 等の `GH_*` を注入されうる。working tree の外（submodule・bare repo・別置きの
git dir を含む）では gh を呼ぶ前に exit 1 で返す。

実例: dotrc/docs/incidents/convention-in-skill-not-invoked.md

`--disable` 形は、既存 PR へ修正を積む間に前周回の auto-merge が発火するのを止めるためにある
（`implement-and-review` 手順 4）。

実例: dotrc/docs/incidents/automerge-clean-status-unreachable.md
実例: dotrc/docs/incidents/automerge-fired-during-followup-review.md

## `gh-request-approval`

設定を置いた repo で、repo 側の approve 用ワークフローを起動して approve を依頼するだけのラッパーである。
approve を待たず、merge にも auto-merge の有効化にも触れない（`--admin` にも到達しない）。approve を
出すのは repo 側のワークフロー（GitHub App）で、auto-merge は通常どおり `gh-automerge <PR> <SHA>` で
張り、merge の成否は branch protection と auto-merge が決める。

`gh-request-approval <PR> <SHA>` は env を空にして自分を re-exec し、main working tree 基準の `gh_mise` で
repo を解決して `-R` に固定する。PR のゲート（OPEN・author が token の本人・fork でない・base が
default branch・人間の未解決 thread と author を問わない CHANGES_REQUESTED が無い・変更パスが設定の
許可リストに収まり、常に拒否するパスに触れない）と head の一致を確かめてから
`gh workflow run <workflow> -R <nwo> --ref refs/heads/<default> -f pr=<PR> -f head_sha=<SHA>` を撃って
終わる。常に拒否するパスは root の `.github/`・`.codex/`・`.githooks/`・`.mcp.json`、深さを問わず
パスの 1 要素として現れる `.claude/`・`.agents/`、root と `docs/` の CODEOWNERS、`:` 始まりのパスで、
rename 元も含めて見る。終了コードは 0 起動した・1 引数や gh の想定外・3 設定不備・4 ゲート拒否・
5 head 不一致・6 起動失敗。

`--enabled` は `gh repo view` で repo を解決し、設定の 2 ファイルがあることとワークフロー名の形を
確かめるだけで、PR には触れない（2 ファイルが無ければ 4、読めない・ワークフロー名の形が不正なら 3）。

設定（`~/.config/dotrc/bot-approve/<OWNER>/<NAME>/` の `workflow` と `paths`。HOME は getent 由来）は
人が置き、agent もラッパーも書かない。設定を置くのは ruleset で push 時の stale review の dismiss が
有効な repo に限る（前提条件で、ラッパーは確かめない）。ゲートと終了コードの正典は
`bin/gh-request-approval` のヘッダ、設計の理由と限界は `docs/design/bot-approve-request.md`。

## fine-grained PAT では check runs を読めない

`gh pr checks` は statusCheckRollup（check runs）を読むが、fine-grained token には check runs を
読む権限がそもそも存在しない（GitHub の fine-grained 権限一覧に Checks の項目が無く、check runs の
REST リファレンスも classic token の `repo` スコープしか挙げていない）。実測でも `gh pr checks` は
GraphQL の "Resource not accessible by personal access token"、`commits/<sha>/check-runs` は 403 に
なる一方、`actions/runs?head_sha=`（Actions: Read）と `commits/<sha>/status`（Commit statuses:
Read）は通る。

- `gh-pr-checks` は後者 2 つの read-only な `gh api` を合成して代替する。高位コマンドが使えない
  ための代替であり、`gh api` を避ける方針（`gh-commands.md` §1）の例外ではない。third-party
  GitHub App が作る check run は拾えず、required かどうかも判定しない（branch protection の参照には
  別権限が要る）。required の充足判定は auto-merge に委ねる
- `gh pr view <N>` / `gh pr view <N> --comments` も内部クエリに statusCheckRollup を含むので、同じ
  token では失敗しうる（`--comments` ではコメント本文が一切返らないことがある。実測は別 repo・別
  token での事例）。`gh pr view` は `--json title,body` のように必要フィールドだけ指定すると rollup を
  引かない。`gh-pr-comments` は read-only な `gh pr view --json reviews,comments` の薄いラッパーで、
  `--json comments` だけでは standalone comments しか返らず review body（Copilot の review サマリ等）
  を落とすため、両方を引く
