# GitHub Issue による agent task 管理

agent が生む task を GitHub Issue に集約し、起票経路を `bin/gh-issue-file` 1 本に絞って重複を
機械的にゲートする土台。agent 向けの規範は `dot/claude/rules/issue-workflow.md` にある。

## 問題

複数の Claude session が同じような task を独立に生み、特に harness 改善案が重複する。

構造的な出所は `harness-from-retrospective` にある。この skill は各委譲先の末尾で走り、提案まで
で止めて session の最終メッセージに残す。提案が横断的に集約される場所が無いので、別 session の
同じ気づきと照合する手段がそもそも存在しない。

## 一次情報 — 非対話起票に issue template は効かない

```
$ gh --version
gh version 2.93.0 (2026-05-27)

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
実行時にその `^## ` 行を読んで body を照合する。

## 代替案 — YAML issue form

人間の起票体験は Markdown template より良い（入力欄・必須指定・検証が web UI 側で効く）。
採らなかったのは、agent 経路が form を使えないためである。form を正典にすると本文骨格を
ラッパーへ再実装することになり、正典が 2 つに割れる。Markdown template なら同じファイルを
人間と agent の両経路が読む。

## 代替案 — 自己内省から自動起票

`harness-from-retrospective` の提案をそのまま `gh-issue-file` へ流す形は採らない。提案が
session 上に出ていれば、ユーザーはその場で説明を求められる。issue へ落とすとその往復が
失われ、提案の背景を読み解く手間が後の消化側に移るだけになる。

自動起票は issue の乱立も招く。dedup ゲートが止められるのは同一の気づきの重複までで、
恒久ハーネスに値しない提案そのものは止められない。その判断は
`dot/claude/rules/issue-workflow.md` §5「起票してよい粒度」が人間に置いている。

したがって起票するかどうかの判断はユーザーに残す。`harness-from-retrospective` は提案を
session 上に出して終わり、起票は人間の選択を経る。

## dedup を全件提示にした理由

`gh-issue-file` は既存の agent task を**全件** stderr に出し、`--not-dup-of` に全番号を書かせて
から起票する。キーワード検索で候補を絞る形は採らない。

自動生成した検索クエリは、外すと「候補 0 件」を返してゲートを素通りさせる。これは
`evidence-over-guesswork` §5 の「不在を成功条件にした確認」そのもので、重複を見逃したことに
気づけない形になる。全件提示なら、外れ方が「ノイズが多い」であって「見逃す」ではない。

候補が 0 件のときはゲートを掛けない。比較対象が無いのにゲートを掛けても、提示するものが無い
まま最初の 1 件で必ず真になるだけである。

## 候補範囲を `agent-task` 全件にした理由

同 `kind` に絞らず `agent-task` label の付いた issue すべてを候補にする。ある session が harness
として、別 session が task として同じ気づきを起票するのが、まさに潰したい重複の形だからである。
同 kind に絞るとこれを素通りする。提示は kind ごとにグルーピングして読みやすさを保つ。

## 既知の限界

- `--limit 200` に達するほど issue が増えたら、`--state open` への絞り込み → キーワード検索の
  順で落とす。全件提示の前提は issue 数が小さいことである。
- dedup の最終判断は agent の読解に依存する。ラッパーが保証するのは「一覧を提示したこと」と
  「全番号を明示させたこと」までで、title が似ているかどうかの判定はしない。
- 人間が web UI から起票した issue にも template の front matter 経由で `agent-task` label が付く。
  blank issue は無効化しているが、label を外して起票することは防げない。その issue は dedup の
  候補に載らない。

## setup（人間が 1 回実行する）

label はラッパーに作らせない。作成権限までラッパーに持たせると grant の射程が広がるためで、
label が無い状態の `gh issue create` はそのまま失敗する（ラッパーは gh の終了コードと stderr を
握り潰さない）。

`status/*` の description は `issue-workflow.md` §3 の label 表（正典）と同じ語で揃える。
GitHub の label description は GitHub 上に独立して表示される文言なので、doc 内参照に
差し替えることはできず、意味の再掲そのものは避けられない。ズレたら §3 側に合わせて直す。

```bash
gh label create agent-task     --description "agent が起票した task" --color 5319e7
gh label create kind/harness   --description "恒久ハーネスの追加・修正"   --color 0e8a16
gh label create kind/bug       --description "再現する不具合"           --color d73a4a
gh label create kind/task      --description "汎用の task"             --color 0075ca
gh label create status/triage  --description "起票直後。着手しない（委譲・インラインとも）" --color fbca04
gh label create status/ready   --description "HOW 確定。着手してよい（委譲・インラインとも）" --color 0e8a16
gh label create status/delegated --description "着手済み（委譲またはインライン）" --color c5def5
```

あわせて `dot/claude/settings.json` の allow へ次の 3 行を足す。allowlist は grant なので agent に
書かせず、人間が直接編集する。

```
Bash(gh-issue-file *)
Bash(gh issue view *)
Bash(gh issue list *)
```

`Bash(gh issue edit *)` は入れない。issue の title / body / label を任意に書き換えられる広い grant
になるうえ、`status/ready → status/delegated` の付け替えを行うのは人間が同席する session なので、
承認プロンプトの摩擦が小さい。

## 委譲との接続

`status/ready` が委譲可の唯一の条件である。起票は必ず `status/triage` で入り、
`triage → ready` の遷移は人間が行う。これが重複を潰す人間ゲートであり、同時に
`delegate-to-worktree` の「WHAT + HOW 確定」不変条件を label で表現したものでもある。

委譲時は `gh issue view <N> --json title,body` の本文をそのまま畳む。issue template の見出しは
委譲プロンプト雛形と一致させてあるので加工は要らない。`<name>` と `-b <branch>` は
`issue-<N>-<slug>`、PR 本文に `Closes #<N>` を入れて merge で自動 close させる。
