---
name: delegate-to-worktree
description: WHAT が固まった作業を別 workspace の自律 agent に委譲する。claude-worktree を session 起動形式（-- 付き）で呼び、detached tmux session 内に acceptEdits の claude を起こして implement-and-review skill に着手させる。「claude-worktree で作業して」「claude-worktree で worktree 作成から」「別 worktree / workspace でやらせて」「これを別 agent に任せて」「delegate して」系の依頼で使う。worktree を作るだけ（初期タスクを伴わない）の要求のときだけ add-only で呼ぶ。
allowed-tools: Bash(claude-worktree *), Bash(claude-worktree), Bash(git worktree list), Bash(git rev-parse *), Read, Glob, Grep
---

# delegate-to-worktree

固まった作業（WHAT）を、別 workspace の自律 claude に委譲する。`bin/claude-worktree` を
**session 起動形式**（`--` 付き）で呼び、detached tmux session の中に acceptEdits の
claude を起こす。起動先は `implement-and-review` skill で HOW を詰め、実装し、merge する。

運用ポリシー（いつ分岐するか・スコープを worktree に閉じるか）は
`dot/claude/rules/worktree-scope.md` §5 を参照。この skill はその「明示指示パス」の手順を担う。

## Pre-fetched context

!`git worktree list`
!`git rev-parse --abbrev-ref HEAD`

## 不変条件（厳守）

- **既定は session 起動形式**。必ず `claude-worktree <name> -b <branch> -- "<prompt>"` の
  `--` 付きで呼ぶ。`--` 無しの add-only モード（path を stdout に出すだけ）は使わない。
- **add-only 例外**: 「worktree だけ作って」など、明示的に初期タスクを伴わない要求の
  ときに限り `--` 無しで呼ぶ。判断に迷ったら session 起動を選ぶ。
- 起動後は fire-and-forget。起動成否の二重検証はしない（重複 session・dir 既存・name 検証は
  `bin/claude-worktree` 本体が行う）。

## 手順

1. **WHAT が固まっているか確認**。未確定なら、この skill に入る前に
   `superpowers:brainstorming` で WHAT を詰めること。この skill は WHAT 確定後の委譲を担う。
2. **自己完結プロンプトを組む**。起動先 claude は会話履歴を持たない。追加質問なしに
   着手できるよう、目的・背景・制約・関連ファイル・期待成果物を畳み込む。先頭に
   `implement-and-review` の明示起動命令を置く。フォーマット:

   ```
   implement-and-review を使って以下のタスクを進めてください。

   ## やること（WHAT）
   <目的 / 背景 / 制約 / 関連ファイル / 期待成果物 を自己完結で>

   ## 進め方
   1. まず HOW をユーザーと brainstorm（最初の質問を出して attach を待つ）
   2. 実装
   3. pr-review-merge で merge
   ```

3. **name / branch を決める**。
   - `<name>`: 依頼内容から簡潔な kebab-case で推論（`[A-Za-z0-9_-]+` のみ）。
     ユーザーが名を明示していたら最優先。pre-fetch した worktree 一覧と衝突しない名にする。
   - `-b <branch>`: repo の branch 命名規約に合わせる（例: `feat/<name>`）。
4. **起動する**: `claude-worktree <name> -b <branch> -- "<prompt>"`.
5. **報告して終了**: スクリプト出力（worktree / branch / session / attach コマンド）を
   そのままユーザーに伝える。ユーザーは `gts <session>` で attach して HOW を詰める。
