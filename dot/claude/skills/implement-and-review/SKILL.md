---
name: implement-and-review
description: worktree に委譲されたタスクを実装→merge で完遂する。HOW は委譲元で確定済みなので brainstorm せず、難度別の実装 subagent へ dispatch しながら実装し、verification を経て pr-review-automerge で自律 merge する。delegate-to-worktree から渡されたプロンプト先頭の明示命令で起動される。
---

# implement-and-review

別 workspace（detached tmux session, acceptEdits）に委譲されたタスクを、
実装 → verification → merge まで完遂する。`delegate-to-worktree` が渡した
プロンプト先頭の明示命令でこの skill に入る。

作業スコープは起動された worktree ディレクトリ内に閉じる
（`dot/claude/rules/worktree-scope.md` §2 参照）。

## 入力

プロンプトの `## やること（WHAT）` に目的・背景・制約・期待成果物が、`## 設計（HOW）` に
確定済みの設計が自己完結で渡される（非自明なタスクでは HOW は `--seed` された spec /
実装計画への相対パス参照になる）。会話履歴は無い。このプロンプトと seed 済みファイルが
唯一の出所。**HOW は委譲元で確定済み**であり、ここで設計をやり直す役ではない。

## 手順

1. **設計は確定済み**: 渡された HOW（本文 or seed 済み spec / 実装計画）を読み、そのまま
   実行に入る。**brainstorm はしない。** 仕様に本質的な欠落・矛盾があり、どう解釈しても
   進めないときに限り、質問を出して REPL で待機する（この session は detached なので
   ユーザーが `gts <session>` / `tmux attach -t <session>` で attach して答える）。
   解釈の幅が結果を大きく変えないなら、前提を明示して進める。
2. **実装**: 実装計画があれば `superpowers:executing-plans` に従い、タスク単位で進める。
   実装作業は**難度に応じて subagent へ dispatch する**（モデルは各 agent 定義の
   `model:` frontmatter で固定されている）。
   - `impl-light` — 機械的・低リスク（定型編集、リネーム、単純な追記）
   - `impl-standard` — 既定。一定のロジック・複数ファイルにまたがる変更
   - `impl-heavy` — 最難。複雑ロジック・非自明な設計判断を含む変更

   自分で直接書くのは、軽微・逐次的で dispatch のオーバーヘッドが見合わないものに留める
   （ハイブリッド）。`superpowers:test-driven-development` 等、repo の規約に従う。
   コミットは論理単位で小さく。
3. **verification**: PR を出す前に、テスト・ビルド・lint が通ることだけを確認する
   （`superpowers:verification-before-completion`）。**重い self-review はしない** —
   レビュー本体は独立した文脈を持つ次の手順に委ねる。自分が書いたコードを同じ文脈で
   レビューしても、実装時の思い込みごと追認するだけになるため。
4. **review→merge**: PR を出したら `pr-review-automerge` を呼び、author とは独立した立場での
   レビュー・required CI 確認を経て自律 merge する。

## 不変条件

- WHAT を勝手に広げない。委譲されたタスクの範囲で完遂する。
- HOW を勝手に作り直さない。確定済みの設計に従う。
- worktree ディレクトリ外への書き込みはしない（read-only 参照は可）。
