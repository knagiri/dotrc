---
name: repo-baseline
description: 新しい repo を作るとき、または remote・PR フロー・CI・doc の配置が欠けた既存 repo で作業していると気づいたときに、baseline の適用を提案・実行するのに使う。「repo を作って」「repo の初期設定」「baseline を当てて」「CI を用意して」系の依頼でも使う。
allowed-tools: Read, Glob, Grep, Bash(git rev-parse *), Bash(git remote *), Bash(gh repo view *)
---

# repo-baseline

repo に、agent と運用するための土台（GitHub の設定・CI・doc の配置）を当てる。新規 repo では
全項目を揃え、既存 repo では現状との差分を提示して承認された項目だけを適用する。

doc の役割分担は `~/.claude/rules/repo-docs.md` が正典で、この skill は配置と手順だけを持つ。

## 原則

- **外から見える変更（GitHub の設定・repo の作成・push）はユーザーの承認後にだけ行う。**
  差分の提示までは自分で進めてよい。黙って書き換えると、ユーザーが意図して置いた設定を
  失わせても気づけないため
- **既存の運用を上書きしない。** 既存 repo（特に勤務先の repo）は既に一定の水準で運用されている
  ことが多い。既存の設定・CI・doc の配置・慣習がある項目には触れず、欠けている項目だけを提案する
- **個人 repo 専用の値は owner が個人 account の repo にだけ提案する。** required approvals 0、
  ruleset の bypass list を空にすること、作成時の既定 private がこれに当たる。agent とユーザーが
  同じ GitHub identity で動く前提の値なので、org の repo では前提が成り立たない

## baseline

| 項目 | baseline | 理由 |
|---|---|---|
| repo 作成（remote が無いときのみ） | `gh repo create`、既定は private（個人 repo） | Free plan の private repo では ruleset・branch protection・auto-merge が使えないことがある。手順 1 で確かめる |
| merge 方式 | merge commit のみ許可（squash / rebase は無効） | `gh-automerge` が `--merge` で merge するため |
| auto-merge | 有効 | `pr-automerge` が auto-merge を張るため |
| merge 後の branch 自動削除 | 有効 | `git-reap-gone` が `[gone]` を完了の合図にするため |
| 既定 branch の保護 | ruleset で PR 必須・CI を required check・force push と削除を禁止 | |
| required approvals | 0（個人 repo） | 同じ identity では自分の PR を approve できず、1 以上だと merge できない。人間の review が要る PR は `pr-automerge` を呼ばないことで担保する（`gh-commands.md` §5） |
| bypass list | 空（個人 repo） | owner が bypass できると、同じ identity の agent も bypass できる |
| CI | 言語に合わせた lint + test の GitHub Actions。テスト対象が無くても空に近い workflow を置く | |
| CD | deploy 先があれば方針を design doc に書く（実装はしない）。無ければ「CD 無し」と書く | 決めた結果として残すため |

## 手順

### 1. 判定

```
git rev-parse --show-toplevel
git remote -v
gh repo view --json owner,isInOrganization,defaultBranchRef,visibility
```

- 新規か既存か。GitHub の remote が無いと `gh repo view` が失敗する。その失敗自体を「remote 無し
  ＝新規扱い」の合図とする。既存でも commit が 0 件、または GitHub の remote が無ければ、新規と
  同じく `gh repo create` から push までを提案する。commit 0 件では push できないので、
  `gh repo create` の前に初回 commit を作る
- owner が個人 account か org か（`isInOrganization`）。org なら個人 repo 専用の値を提案しない
- `visibility` が private で、プランが Free の可能性があるとき（個人 account の private repo 等）は、
  ruleset・branch protection・auto-merge が使えないことがある。使えるかは手順 4 の失敗の文面で
  判別する。使えないと分かったら、repo を public にするか、ruleset と auto-merge の項目を外すかを
  ユーザーに選んでもらう

### 2. 現状の読み取り（読み取りだけ）

```
gh api repos/{owner}/{repo} --jq '{allow_merge_commit,allow_squash_merge,allow_rebase_merge,allow_auto_merge,delete_branch_on_merge}'
gh api repos/{owner}/{repo}/rulesets
gh api repos/{owner}/{repo}/rulesets/<id>   # 既存の ruleset ごとに中身を読む
```

加えて `.github/workflows/` の有無と中身、`README.md` / `CLAUDE.md` / 設計 doc / 経緯の doc の
配置を読む。旧来の branch protection が既定 branch にあるかも見る（`gh api repos/{owner}/{repo}/branches/<branch>/protection`。
無ければ 404）。

### 3. 差分の提示と承認

baseline と現状の差分を 1 項目 1 行で一覧にし、項目ごとに承認を得る。

- 既存の ruleset / branch protection があれば上書きしない。足りない rule だけを差分として示し、
  既存 ruleset の更新か別 ruleset の追加かをユーザーに選んでもらう
- org の repo では、既に設定のある項目を差分に入れない

### 4. 適用（承認された項目だけ）

repo の設定:

```
gh api -X PATCH repos/{owner}/{repo} -F allow_merge_commit=true -F allow_squash_merge=false -F allow_rebase_merge=false -F allow_auto_merge=true -F delete_branch_on_merge=true
```

ruleset は JSON を一時ファイル（`$CLAUDE_JOB_DIR` は interactive session で未定義のことがあるので、
`mktemp` で作る）に書いて渡す。`--input -` に heredoc で渡してもよい。

```
gh api -X POST repos/{owner}/{repo}/rulesets --input <file>
```

```json
{
  "name": "default branch protection",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [ { "context": "<job 名>" } ] } }
  ]
}
```

- `required_status_checks` の `context` は CI が一度走って job 名（check の名前）が確定してから
  入れる。CI がまだ走っていない repo では、まず `required_status_checks` 抜きで ruleset を作り、
  CI の PR が走った後に rule を足す。存在しない名前を required にすると、その check は永久に
  pending のままで merge できなくなる
- 403 等で失敗したら、黙って失敗扱いにせず、エラー文面で 2 つに分ける
  - token の権限不足: 実行するコマンドをそのまま示し、ユーザーに `! <command>` で実行してもらって
    止まる。wrapper や allow は足さない
  - プランが未対応（upgrade を求める文面等。private repo の Free plan で起こりうる）: `!` で
    実行しても解決しない。手順 1 の選択（public にする／該当項目を外す）へ戻る
  - 手順 2 の branch protection の GET も、404 でなく 403 を返してプラン未対応を示すことがある

### 5. CI

repo の言語に合わせた lint と test の workflow を `.github/workflows/` に置き、PR として入れる
（どの linter / test runner にするかは repo の言語と既存の設定から決める）。テスト対象がまだ
無ければ、checkout だけの空に近い workflow でよい。CD は baseline の表のとおり design doc に
方針か「CD 無し」を書く。

### 6. doc

- **新規 repo**: `README.md` / `CLAUDE.md` / `docs/design/` / `docs/incidents/` を短い雛形で作り、
  `docs/superpowers/`（作業中の spec / plan）を `.gitignore` に入れる。各 doc の中身は
  `repo-docs.md` の役割に従う。雛形は見出しと 1〜2 行に留め、書くことの無い節を埋めない
- **既存 repo**: 配置は動かさない。`repo-docs.md` の役割とずれている箇所（README に設計判断や
  経緯が入っている等）を指摘し、移す先の候補を示す。移すかどうかはユーザーが決める

### 7. 委譲先用の allow

テスト実行など、委譲先でも要る定型の検証コマンドの allow を `<repo>/.claude/settings.json`
（tracked）に置くことを提案する。置き場所の考え方は `claude-settings.md` の「3 層の使い分け」。
