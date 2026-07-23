---
name: delegate-to-worktree
description: WHAT と HOW（設計）が固まった作業を別 workspace の自律 agent に委譲する。claude-worktree を session 起動形式（-- 付き）で呼び、detached tmux session 内に acceptEdits の claude を起こして implement-and-review skill に着手させる。「claude-worktree で作業して」「claude-worktree で worktree 作成から」「別 worktree / workspace でやらせて」「これを別 agent に任せて」「delegate して」系の依頼で使う。worktree を作るだけ（初期タスクを伴わない）の要求のときだけ add-only で呼ぶ。
allowed-tools: Bash(claude-worktree *), Bash(git worktree list), Bash(git rev-parse *), Read, Glob, Grep
---

# delegate-to-worktree

固まった作業（WHAT + HOW）を、別 workspace の自律 claude に委譲する。`bin/claude-worktree` を
**session 起動形式**（`--` 付き）で呼び、detached tmux session の中に acceptEdits の
claude を起こす。起動先は `implement-and-review` skill で**確定済みの設計を実行し**、merge する。

運用ポリシーは `dot/claude/rules/worktree-scope.md` を参照。作業スコープを worktree に閉じる
原則は §2、main working tree にいるときの既定＝委譲は §5、分岐そのものの手順は §6。
この skill はその「明示指示パス」の手順を担う。

## Pre-fetched context

!`git worktree list`
!`git rev-parse --abbrev-ref HEAD`

## 不変条件（厳守）

- **委譲プロンプトは WHAT だけでなく HOW（設計）まで運ぶ。** HOW はこちら側（委譲元）で確定
  させてから渡す。委譲先で brainstorm させない。理由は 2 つ: 委譲先は detached で人間が不在
  なので設計対話が成立しない／長時間 agentic 実行は「最初の 1 ターンでフル仕様」を渡したときに
  最も精度が出る。
- **既定は session 起動形式**。必ず `claude-worktree --model opus <name> -b <branch> -- "<prompt>"`
  の `--` 付きで呼ぶ。`--` 無しの add-only モード（path を stdout に出すだけ）は使わない。
- **委譲先（B）のモデルは `--model opus` で固定する。** 長時間の agentic 実行を担う役なので、
  呼び出し元セッションのモデルを継承させない。
- **add-only 例外**: 「worktree だけ作って」など、明示的に初期タスクを伴わない要求の
  ときに限り `--` 無しで呼ぶ。判断に迷ったら session 起動を選ぶ。
- 起動後は fire-and-forget。起動成否の二重検証はしない（重複 session・dir 既存・name 検証は
  `bin/claude-worktree` 本体が行う）。

## 手順

1. **WHAT と HOW が固まっているか確認**。未確定なら、この skill に入る前に
   `superpowers:brainstorming` → `superpowers:writing-plans` で詰めること。この skill は
   設計確定後の委譲を担う。HOW の運び方は規模で 2 パスに分かれる。

   - **非自明なタスク**: spec / 実装計画を `docs/superpowers/` 配下に生成し、`--seed` で
     worktree へ入れて相対パスで参照させる。これらは gitignore 済み・未 commit なので
     branch checkout では worktree に載らない（[[spec-plan-docs-not-committed]]）。
   - **軽いタスク**: spec 化するまでもない小物は、HOW を委譲プロンプト本文に畳む。

2. **自己完結プロンプトを組む**。起動先 claude は会話履歴を持たない。追加質問なしに
   着手できるよう、目的・背景・制約・関連ファイル・期待成果物に加え、**確定した設計（HOW）**を
   畳み込む。先頭に `implement-and-review` の明示起動命令を置く。

   自己完結は**ファイルシステム的にも**要る。委譲先が承認なしに読めるのは新 worktree 内の
   ファイルだけで、worktree 外の絶対パス Read は permission prompt を出し、人間不在の委譲先は
   そこで固まる。commit 済みファイルは worktree に既に在るので相対パスで参照させる。gitignore
   済み・未 commit で委譲先が要るファイル（spec / 実装計画等）は `--seed <path>` で worktree 内へ
   入れ、相対パスで参照させる（詳細は `worktree-scope.md` §6）。フォーマット:

   ```
   implement-and-review を使って以下のタスクを進めてください。

   ## やること（WHAT）
   <目的 / 背景 / 制約 / 期待成果物 を自己完結で>

   ## 設計（HOW）
   <確定した設計。非自明なら --seed した spec / 実装計画を相対パスで指し、
    「これに厳密に従う」と明示する。軽いタスクならここに畳む>

   ## 進め方
   1. 設計は確定済み。brainstorm せず実行に入る
   2. 実装
   3. pr-review-automerge で merge
   ```

3. **name / branch を決める**。
   - `<name>`: 依頼内容から簡潔な kebab-case で推論（`[A-Za-z0-9_-]+` のみ）。
     ユーザーが名を明示していたら最優先。pre-fetch した worktree 一覧と衝突しない名にする。
   - `-b <branch>`: repo の branch 命名規約に合わせる（例: `feat/<name>`）。
4. **起動する**: `claude-worktree --model opus [--seed <path>]... <name> -b <branch> -- "<prompt>"`.
5. **報告して終了**: スクリプト出力（worktree / branch / session / model / attach コマンド）を
   そのままユーザーに伝える。委譲先は設計確定済みなので attach 待ちにはならない。ユーザーは
   `gts <session>` でいつでも様子を見られる。
