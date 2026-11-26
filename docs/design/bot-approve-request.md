# approve 用ワークフローを起動して auto-merge する経路

approve を 1 件必須にしている repo では、agent が作った PR は `pr-review-loop` が収束しても、人が approve
するまで merge されない。そうした repo の一部では、approve を出す GitHub App 用のワークフロー
（`workflow_dispatch`）を repo 側に置き、ワークフロー自身の検査を通った PR にだけ App 名義で approve を
付ける。dotrc は `bin/gh-request-approval` でそのワークフローを起動し、approve が付いたら auto-merge を
張る。CI の完了と required check の充足は GitHub の auto-merge に任せ、`--admin` は使わない。ゲート・
終了コード・待機の細目の正典はラッパーのヘッダにある。

## repo 側ワークフローとの契約

ワークフローは inputs に `pr`（PR 番号）と `head_sha`（40 桁）を取り、default branch の ref（`refs/heads/<default>`。裸の名前だと同名の tag に解決されうる）から起動される。
起動者の allowlist、起動者 = PR author、open / base が default branch / fork でない、head が `head_sha` と
一致、`.github/` `.claude/` を含まない、を検査し、通れば `head_sha` に固定して APPROVE する。dotrc 側の
ゲートはこれと重なるが、ワークフロー側の検査は dotrc が手を出せない最後の砦なので、どちらか一方に寄せない。

## ゲートを機械と判断で分ける

ラッパーが確かめるのは機械的に決まるものである。repo の設定があること、PR の author が token の本人で
fork でなく base が default branch であること（approve 待ちの後にも再確認する）、人間が起こした未解決
thread と、author を問わない CHANGES_REQUESTED が無いこと、変更パスが許可リストに収まり `.github/`
`.claude/`・root と `docs/` の CODEOWNERS に触れないこと、head が渡された SHA であること。
差分が担当領域に収まっているか、振る舞いの変更にテストがあるか、設計・契約を決める変更でないかは判断を
要するので、`pr-review-loop` の判定役が収束時に `approve_gate=ok|ng:<理由>` として出し、`pr-automerge` が
それを確かめてからラッパーを呼ぶ。満たさなければ `gh-automerge` にも落とさず、通常の PR として残す。
auto-merge を張っておくと、後で人が approve した時点でゲートを通っていない PR が merge されるため。

## 信頼の根拠

ラッパーが読むものと gh に渡すものを、呼び出し側が差し替えられないようにする。

- **設定は getent 由来の HOME 配下に置く。** `<HOME>/.config/dotrc/bot-approve/<OWNER>/<NAME>/` の
  `workflow`（ワークフローのファイル名）と `paths`（変更してよいパス、`.gitignore` 書式）。両方そろった repo
  だけを許可とみなす。専用の有効化フラグは設けず、設定の有無で兼ねる。`paths` の初期値は空で、空なら
  何も通さない。安全と確かめたパスを人が足していく。checkout の中に置くと PR の内容で差し替えられるので
  外に置き、`HOME` / `XDG_CONFIG_HOME` を見ずに `getent passwd` から引く。
- **env を空にして自分を re-exec する。** 冒頭で `env -i` により `HOME`（getent 由来）・固定の `PATH`・
  re-exec 済みの印だけを渡して自分を起動し直す。`XDG_CONFIG_HOME`、`PATH` の前置、`GH_*`、`GIT_*`、
  `MISE_*` などは効かない。shebang は `#!/bin/bash -p` で、caller の PATH から bash を引かず、privileged
  mode が export された関数（`BASH_FUNC_*`）の取り込みと `BASH_ENV` / `ENV` / `SHELLOPTS` などの読み込みを
  止める。印があるのに他の export 変数が残っていれば止まる。印を偽れば掃除は飛ばせるが、その場合も
  読まれる変数は残らない。待機の上限を env で変えられないのはこの帰結で、定数にしている（480 秒。最後の
  poll と 1 interval を足しても Bash tool の上限 600 秒に収まる）。
- **token は main working tree 基準で解決する。** gh はすべて `gh_mise_main_root` を基準にした `gh_mise` で
  呼ぶ。mise は main checkout・その祖先 directory・global の config を読み、linked worktree 自身の
  tracked な `mise.toml`（任意の branch が書き換えられる）からの `GH_TOKEN` 等の注入を受けない。token は main checkout の
  `mise.gh.local.toml` があればその個人 PAT、無ければ hosts.yml になる。最初に解決した repo は以降の全
  呼び出しに `-R` で固定する。
- **approve は内容に紐づけて待つ。** 待機の終了条件は `reviewDecision == APPROVED` ではなく、App（PR author
  以外の Bot）の APPROVED review で `commit_id` が渡された SHA に一致するものである。dismiss stale reviews が
  無効な repo では、push 後も古い commit への approve が残り `reviewDecision` は APPROVED のままなので、
  それを待つと approve されていない内容に auto-merge を張りうる。
- パスの照合は git 自身（空の一時 repo の `info/exclude` と `git check-ignore --no-index`）に任せる。自前の
  glob は gitignore と細部が食い違ったときに黙って許可を広げうるため。変更ファイル一覧は head が渡された
  SHA と一致すると確かめる前提で、`compare/<base>...<SHA>` から SHA に固定して読む。

## 限界

- `paths` は gitignore の意味論で照合されるので、除外した親 directory の下は否定パターンで戻せない
  （`src/` と `!src/x` の組では `src/x` も通る）。否定を効かせたいときは `src/*` と書く。
- 人が起こした thread を agent が resolve すると、人間 thread の検査は通ってしまう（agent は利用者本人の
  token を使うので `resolvedBy` では区別できない）。resolve しないことは規約（`gh-commands.md` §5）で
  守っている。
- `approve_gate` は判定役の自己申告で、ラッパーは検証しない。ラッパーは allowlist 済みなので、
  `pr-review-loop` を経ずに直接呼ばれれば機械的なゲートだけが残る。
- 設定ファイルは規約で守っているだけである。checkout の外への書き込みは承認（auto mode では classifier の
  判定）を経るが、settings.json で deny してはおらず、Bash 経由の書き込みは塞げない。
- App の approve が required approval として数えられるかは、repo の ruleset の review 設定で決まる。
  ruleset の review 設定を変えたら、App の approve が数えられるかを確かめ直す。
- approve と auto-merge は張った時点の SHA に固定されるが、その後 PR に push されると、dismiss stale reviews が
  無効な repo では古い approve が数えられたまま auto-merge が新しい head を merge しうる。auto-merge を張った
  後の PR に push しない（修正を積むなら先に `gh-automerge --disable` する）ことで守っている。
- 待機は approve が付くまでで、CI は待たない。approve 後に CI が落ちれば auto-merge は成立せず、PR は
  auto-merge が有効なまま残る。
