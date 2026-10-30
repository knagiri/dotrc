# merge を見送る理由で review まで回らなくなった

## 経緯

PR の自律 review と merge を 1 つの skill（`pr-review-automerge`）が担っていた。agent が自分の
判断でこの skill を止め、merge だけでなく review まで回らないケースがあった（ユーザー報告）。
この事例は報告を受けたものであり、この経緯を書いた委譲では再現していない。そのとき agent が
何を根拠に止めたか、その結果どんな差分が review を経ずに残ったかは観測しておらず、ここには
書かない。

原因は構造にあると判断した。

1. review と merge が 1 skill なので、merge を見送る理由があると skill ごと呼ばれなくなる
2. grant 変更を含む PR について、`dot/claude/rules/gh-commands.md` §5 と `harness-from-feedback`
   自身が「`pr-review-automerge` を起動させず PR 作成で停止させる」と定めており、merge を
   止めるための規定が review まで落としていた（下の観測）
3. 雛形（`delegate-to-worktree` の「3. pr-review-automerge で merge」等）と skill の
   description が merge を終点として書いており、review は merge へ至る途中工程にしか見えない

## 観測

分割前の `origin/main`（70e2104）で、grant 変更の規定が skill ごと止めていた箇所。

```
$ git show origin/main:dot/claude/rules/gh-commands.md | rg -n 'PR 作成で停止|PR 作成で止まる'
144:`pr-review-automerge` を起動させず PR 作成で停止させ、merge は人間が行う。
$ git show origin/main:dot/claude/skills/harness-from-feedback/SKILL.md | rg -n 'PR 作成で停止|PR 作成で止まる'
33:  プロンプトでは `pr-review-automerge` を起動させず PR 作成で停止させる（上の「マージは委譲先の
65:   - allowlist（grant）を含む場合は、**`pr-review-automerge` を起動せず PR 作成で停止する**旨を
118:     ただし allowlist（grant）を含む場合は PR 作成で止まるので、**人間の approve と merge が
```

## 直し方

skill を `pr-review-loop`（review の待機 → 判定・修正ループ → 遅着 review の再確認。merge は
しない）と `pr-automerge`（CI の fail 確認 → PR 本文の整合 → `gh-automerge` → 終端判定）に
分け、合成 skill は作らない。呼び出し側が `pr-review-loop` → `pr-automerge` の順に呼ぶので、
merge を見送るときは後者だけを呼ばなければよく、review を落とす経路が構造上なくなる。

`pr-automerge` は冒頭で、`pr-review-loop` が収束時に出した `head_sha` / `last_seen` と現在の
HEAD・最新の review activity を照合し、合わなければ merge せず止まる。review を経ない merge を
手順側でも塞ぐためである。

grant 変更の規定は「`pr-review-loop` までは回し、`pr-automerge` は呼ばない。merge は人間が
approve してから」に変えた。

## 反映先

- `dot/claude/skills/pr-review-loop/SKILL.md`（新設。旧 `pr-review-automerge` の review 部分）
- `dot/claude/skills/pr-automerge/SKILL.md`（新設。旧 `pr-review-automerge` の merge 部分と冒頭のゲート）
- `dot/claude/skills/implement-and-review/SKILL.md` 手順 4〜6 と不変条件「merge を見送る理由は、
  一般に review を見送る理由にならない」
- `dot/claude/rules/gh-commands.md` §5「grant 変更を含む PR は auto-merge させない」
- `dot/claude/skills/harness-from-feedback/SKILL.md` 不変条件・手順 4・手順 6
- `dot/claude/skills/delegate-to-worktree/SKILL.md` 委譲プロンプトの雛形
