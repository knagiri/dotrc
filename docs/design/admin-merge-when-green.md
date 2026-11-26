# CI が通ったら admin bypass で merge する経路

repo によっては、admin が approve 無しで bypass merge してよい運用を取っている。GitHub の auto-merge は
required な CI が通っても approve が無ければ merge しないので、`gh-automerge` ではその運用に乗れない。
そこで `pr-review-loop` が収束した PR について、手元で CI の完了を待ち、`gh pr merge --admin` で merge する
経路を `bin/gh-merge-when-green` と `pr-automerge` の分岐として持つ。ゲート・終了コード・待機の細目の
正典はラッパーのヘッダにある。

## GitHub 側の設定は解釈せず、CI の結果だけを見る

CI について見るのは「その PR のチェックが全部通っている」ことだけで、ruleset を読んで bypass 対象の rule
種別を判定する、といった GitHub 側の設定の解釈はしない。解釈を足すほど、設定の変更や API の形の違いで
黙って誤判定する経路が増えるため。required かどうかも問わず全チェックを見る。`gh pr checks --required` は
既に報告された required しか見えず、まだ作られていない workflow を見落とすので、全件を見たうえで
「全件完了」を 2 回続けて観測してから merge する。

## ゲートを機械と判断で分ける

ラッパーが確かめるのは、機械的に決まるものである: repo の許可リスト、author が token の本人で fork でなく
base が default branch であること、変更パスの許可リスト、head の一致、人間が起こした未解決 thread と人間の
CHANGES_REQUESTED review が無いこと（`--admin` は required approval も迂回するので、thread を持たない
review の差し戻しもラッパーが見る）、チェックの結果。差分が委譲した範囲に収まっているか、振る舞いの変更にテストがあるか、設計・契約を
決める変更でないか、は判断を要するので、`pr-review-loop` の判定役が収束時に `bypass_gate=ok|ng:<理由>`
として出し、`pr-automerge` がそれを見てからラッパーを呼ぶ。満たさなければ `gh-automerge` にも落とさず、
通常の PR として残す。

## 許可リストは checkout の外に置く

- repo の許可リストは dotrc のマシンローカル設定 `ADMIN_MERGE_REPOS`（空白区切りの `OWNER/NAME`。
  `docs/design/dotrc-machine-config.md`）。他の設定と違い、同名の環境変数は無視して config ファイルから
  だけ読む。呼び出し側が env で bypass merge してよい repo を名乗れないようにするため。
- パスの許可リストは `~/.config/dotrc/admin-merge-paths/<OWNER>/<NAME>`。checkout の中に置くと、PR や
  agent が作った別の clone の内容でリストを差し替えられるので、checkout の外に置く。初期状態は空
  （ファイルが無い）で、空なら何も merge しない。安全と確かめたパスを人が足していく。
- 書式と解釈は `.gitignore` と同じにし、照合は git 自身（空の一時 repo の `info/exclude` と
  `git check-ignore --no-index`）に任せる。自前の glob 実装は、gitignore と細部が食い違ったときに
  黙って許可を広げうるため。gitignore の制約から、`dir/` を許可するとその下を `!` で外せない（外したい
  ときは `dir/*` で書く）。
- 変更ファイル一覧は、head が渡された SHA と一致すると確かめた後に `compare/<base>...<SHA>` から読む。
  PR の現在の head から読むと、head が A -> B -> A と動いたときに B の一覧を判定して A を merge しうる。
  SHA に固定すれば一覧と merge 対象が同じ commit になり、動きを検出する再読込が要らない。
- `.github/`（PR が自分を判定する CI を書き換えられる）と `.claude/`（permission の grant）は、リストに
  何が書かれていても対象外にする。repo ごとの他の grant の置き場所は、その repo のリストから外す。
- ラッパーの gh は mise を経由せず hosts.yml の login で呼び、呼び出し側の GitHub 関係の env を落とし、
  最初に解決した repo を以降の全呼び出しに `-R` で固定する。checkout の mise config や env から、別の
  repo・別の token へ向け直されないようにするため。

`~/.config/dotrc/` は checkout の外なので、agent が書くには承認（auto mode では classifier の判定）を
経る。deny では塞いでおらず、人のレビューを前提に agent へ変更を頼む余地を残している。リストの
内容ハッシュによる trust（`db-query` の paranoid trust の方式）は入れていない。

## 限界

- `--admin` は required check も迂回する。required な workflow の run が、他のチェックの完了から 2 回の
  観測より遅れて作られると、それを待たずに merge される。
- 許可リストの場所は `XDG_CONFIG_HOME` / `HOME` から決まり、待機の knob（`GH_MERGE_WHEN_GREEN_*`）も
  env で変えられる。呼び出し側がこれらを前置すれば、別の config を読ませたり、2 回の観測の間隔を
  縮めたりできる。テストを env で行うための形で、塞いでいない。
- 判断を要するゲート（`bypass_gate`）は呼び出し側の申告で、ラッパーは検証しない。ラッパーは allowlist
  済みなので、`pr-review-loop` を経ずに直接呼ばれれば機械的なゲートだけが残る。
- `gh pr checks` は check runs を読むので、fine-grained PAT では常に失敗する（exit 9）。hosts.yml の
  token が fine-grained のホストでは admin 経路は使えず、毎回 exit 9 で止まる（PR は通常の PR として
  残る）。classic か OAuth token のホストでだけ機能する。

## 監査

bypass merge は ruleset の rule-suites API（`rule_suite_result=bypass`）で、誰が・どの SHA を・いつ
bypass したかを後から引ける。
