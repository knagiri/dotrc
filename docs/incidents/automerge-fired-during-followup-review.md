# 既存 PR へ修正を積む review の途中で、有効化済みの auto-merge が merge を成立させた

## 経緯

ある PR は `pr-automerge` で auto-merge を有効化済みで、人間の approve を待っていた。そこへ修正
依頼が入り、委譲元は `worktree-scope.md` §6 に従って同じ name・branch で新しい委譲先を起こし、
「既存 PR の指摘への対応。新しい PR は作らない」を渡した。委譲先が修正 commit を push して
`pr-review-loop` を回している最中に、人間がその push を見て approve した。既に有効だった
auto-merge がその時点で merge を成立させ、この周回の review が終わる前に merge された。

review で追加の修正が出ていれば、委譲先は merge 済みのブランチへ push するところだった。
`implement-and-review` の既存 PR 対応の段落は、push して review → merge を回すことしか定めて
おらず、前の周回で有効化した auto-merge がまだ生きていることを扱っていなかった。

## 観測

上の順序（auto-merge 有効化 → 修正 commit の push → review 中の approve → merge）は委譲元の
報告による。コマンド出力や PR の timeline は残しておらず、この順序を再現してもいない。
`--disable` の挙動は stub を使ったテストでだけ確かめており、実在の PR には撃っていない。

## 直し方

- `bin/gh-automerge` に `--disable <PR>` を足した。`gh pr view --json state,autoMergeRequest` で
  読み、merge 済み / close 済みなら exit 3、既に無効なら何もせず exit 0、有効なら
  `gh pr merge --disable-auto <PR>` を撃ち、読み直して無効になったことを確かめる。既存の allow
  `Bash(gh-automerge *)` のまま使え、受け付ける形は `<PR>` と `--disable <PR>` の 2 つだけなので
  `--admin` 等には届かない
- `implement-and-review` は、既存 PR への対応では着手直後（最初の push より前）に
  `gh-automerge --disable <N>` を呼ぶ。exit 3 なら push せずに中断して報告する。再有効化は収束後の
  `pr-automerge` がそのまま担う
- `test/gh-wrappers.test.sh` に `--disable` の 4 分岐と不正な引数の拒否を足し、各ガードを
  1 つずつ壊した変異をテストが捕まえることを同じファイルで確かめている

人間に「review 完了報告まで approve しないで」と頼む運用は採らなかった。頼みごとは忘れられうる
一方、auto-merge が無効なら approve は merge を成立させない。

PR を draft に戻す案も採らなかった。bot のレビュアーが draft を飛ばすと `gh-await-reviews` が
待ち続けうるうえ、ready に戻すラッパーが別に要る。

## 既知の限界

auto-merge を止めても、人間が merge ボタンを押せば merge される。これは仕組みでは防いでいない。
`--disable` から最初の push までの間に誰かが auto-merge を有効化し直す競合も扱っていない。

## 反映先

- `bin/gh-automerge`（header コメント）
- `dot/claude/skills/implement-and-review/SKILL.md` 手順 4「委譲プロンプトが既存 PR への対応を指示しているとき」
- `dot/claude/skills/pr-automerge/SKILL.md`「不変条件（厳守）」
- `dot/claude/skills/delegate-to-worktree/SKILL.md` 手順 6「PR 監視に起こされ、修正が要ると判断したら」
- `dot/claude/rules/gh-commands.md`「5. merge と review thread 操作（自律レビューループ用）」
