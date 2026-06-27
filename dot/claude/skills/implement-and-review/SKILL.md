---
name: implement-and-review
description: worktree に委譲されたタスクを brainstorm→実装→merge で完遂する。HOW をユーザーと brainstorm し（detached session のため最初の質問を出して attach を待つ）、実装し、pr-review-merge で自律 merge する。delegate-to-worktree から渡されたプロンプト先頭の明示命令で起動される。
---

# implement-and-review

別 workspace（detached tmux session, acceptEdits）に委譲されたタスクを、
HOW の brainstorm → 実装 → merge まで完遂する。`delegate-to-worktree` が渡した
プロンプト先頭の明示命令でこの skill に入る。

作業スコープは起動された worktree ディレクトリ内に閉じる
（`dot/claude/rules/worktree-scope.md` 参照）。

## 入力

プロンプトの `## やること（WHAT）` に目的・背景・制約・関連ファイル・期待成果物が
自己完結で渡される。会話履歴は無い。WHAT はこのプロンプトが唯一の出所。

## 手順

1. **HOW を brainstorm**: `superpowers:brainstorming` を使い、WHAT を「どう実装するか」に
   落とす。この session は detached で起動直後ユーザーは attach していないため、
   brainstorming の最初の質問を出した時点で REPL で待機する。ユーザーが
   `gts <session>` / `tmux attach -t <session>` で attach して HOW を詰める。
2. **実装**: 設計が固まったら実装する。`superpowers:test-driven-development` 等、
   repo の規約に従う。コミットは論理単位で小さく。
3. **review→merge**: 実装が一段落し PR を出したら `pr-review-merge` を呼び、
   author とは独立した立場でのレビュー・required CI 確認を経て自律 merge する。

## 不変条件

- WHAT を勝手に広げない。委譲されたタスクの範囲で完遂する。
- worktree ディレクトリ外への書き込みはしない（read-only 参照は可）。
