# 観測 issue が public repo へ自動起票され、勤務先由来の具体名が人の目を通らず公開されうる構造だった

## 経緯

agent の気づきは観測 issue として dotrc（public）へ自動起票される。起票は業務 repo の session からも
同じ経路で行われ、title と本文は agent が書く。人が内容を見る段階は無く、起票した時点で公開される。
勤務先由来の具体名は一度公開すると消せない。

最初の対策は、起票ラッパーに denylist を置いて既知の名前を含む本文を弾くことだった。名前の集合は
開いていて（新しい組織・repo・サービスが増え続ける）、列挙しきれない。漏れた名前はそのまま通り、
弾けたかどうかを確かめる手段も無い。機械的な歯止めとして成り立たないので denylist は撤去し、書く側の
規約に頼る暫定状態になった。

## 判断

issue の置き場所を private repo に移す。public な dotrc に出るのは改善 PR と branch 名だけになり、
観測の本文が公開される経路そのものが無くなる。内容を検査して弾く方式は、検査対象の集合が開いている限り
漏れを残すが、置き場所を変えれば検査が要らない。

残るリスクは、観測を読んだ委譲先が内容を public な PR に写す 1 経路である。規約、`pr-review-loop` の判定役の
観点（PR 本文と差分に具体名・issue 番号が無いか）、人の merge で守る。あわせて issue 番号を public な PR・
commit に書かないことにした。dotrc の無関係な issue へ autolink されるためで、issue と PR の対応は
branch 名に持たせる。issue repo の名前も public にしないため tracked には書かず、マシンローカル設定から読む。

## 反映先

- `docs/design/agent-issue-workflow.md`、`docs/design/dotrc-machine-config.md`
- `dot/claude/rules/issue-workflow.md`、`dot/claude/rules/gh-commands.md`
- `dot/claude/skills/pr-review-loop/SKILL.md`（判定役の観点）
- `bin/lib/dotrc-config.sh`、`bin/lib/issue-repo.sh`、`bin/gh-issue-file`、`bin/gh-issue-group`、`bin/gh-issue-mark-delegated`、`bin/issue-crawl`
- `dot/claude/crawler/cluster-prompt.md`
- `dot/claude/skills/` の `design-from-observations` / `delegate-to-worktree` / `harness-from-feedback` /
  `harness-from-retrospective` / `spin-off-session` の各 `SKILL.md`
