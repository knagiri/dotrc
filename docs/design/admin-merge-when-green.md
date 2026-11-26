# CI が通ったら admin bypass で merge する経路

repo によっては、admin が approve 無しで bypass merge してよい運用を取っている。GitHub の auto-merge は
required な CI が通っても approve が無ければ merge しないので、`gh-automerge` ではその運用に乗れない。
そこで `pr-review-loop` が収束した PR について、手元で CI の完了を待ち、`gh pr merge --admin` で merge する
経路を `bin/gh-merge-when-green` と `pr-automerge` の分岐として持つ。ゲート・終了コード・待機の細目の
正典はラッパーのヘッダにある。

## merge の条件を 2 つに絞る

merge してよい条件は「レビューループが収束している」と「その SHA のチェックが全部通っている」だけに
する。ruleset を読んで bypass 対象の rule 種別を判定する、といった GitHub 側の設定の解釈はしない。
解釈を足すほど、設定の変更や API の形の違いで黙って誤判定する経路が増えるため。required かどうかも
問わず全チェックを見る。`gh pr checks --required` は既に報告された required しか見えず、まだ作られて
いない workflow を見落とすので、全件を見たうえで「全件完了」を 2 回続けて観測してから merge する。

## ゲートを機械と判断で分ける

ラッパーが確かめるのは、機械的に決まるものだけである: repo の許可リスト、author が token の本人で
fork でなく base が default branch であること、変更パスの許可リスト、head の一致、チェックの結果。
差分が委譲した範囲に収まっているか、振る舞いの変更にテストがあるか、設計・契約を決める変更でないか、
は判断を要するので、`pr-review-loop` の判定役が収束時に `bypass_gate=ok|ng:<理由>` として出し、
`pr-automerge` がそれと人間の未解決 thread の有無を見てからラッパーを呼ぶ。どちらかを満たさなければ
`gh-automerge` にも落とさず、通常の PR として残す。

## 許可リストは agent が書けない場所に置く

- repo の許可リストは dotrc のマシンローカル設定 `ADMIN_MERGE_REPOS`（空白区切りの `OWNER/NAME`。
  `docs/design/dotrc-machine-config.md`）。未設定・形が不正なら何もしない。
- パスの許可リストは対象 repo の main working tree の root に置く git 管理外の `.dotrc-admin-merge-paths`。
  worktree 内のコピーではなく main working tree から読むので、worktree で動く agent がリストを緩めても
  効かない。初期状態は空（ファイルが無い）で、空なら何も merge しない。安全と確かめたパスを人が足して
  いく。
- 書式と解釈は `.gitignore` と同じにし、照合は git 自身（空の一時 repo の `info/exclude` と
  `git check-ignore --no-index`）に任せる。自前の glob 実装は、gitignore と細部が食い違ったときに
  黙って許可を広げうるため。
- `.github/`（PR が自分を判定する CI を書き換えられる）と `.claude/`（permission の grant）は、リストに
  何が書かれていても対象外にする。

リストの内容ハッシュによる trust（`db-query` の paranoid trust の方式）は入れていない。ファイルが
checkout の外（`~/.config`）と main working tree の git 管理外にあり、どちらも agent の作業範囲の外に
あることで足りるとしている。

## 監査

bypass merge は ruleset の rule-suites API（`rule_suite_result=bypass`）で、誰が・どの SHA を・いつ
bypass したかを後から引ける。
