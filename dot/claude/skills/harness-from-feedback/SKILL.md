---
name: harness-from-feedback
description: 作業中のユーザーの指摘・訂正を、その場の修正で終わらせず再発防止の恒久的な仕組み（.claude/rules / CLAUDE.md / lint / test / hook）へ変換したいとき。次セッション以降に自動で効かせる。「ハーネス化して」「再発防止して」「ルール化して」等の明示依頼でも発動する。
allowed-tools: Bash(claude-worktree *), Bash(git rev-parse *), Bash(git worktree list), Read, Glob, Grep
---

# harness-from-feedback

作業中のユーザーの指摘を、恒久的なハーネス（rules / CLAUDE.md / lint / test / hook）へ変換する。
この skill 自身は **薄い**。実装・検証・コミット・マージはしない。要件を固め、自己完結プロンプトに
畳み、`claude-worktree` を直接起動して委譲する。委譲先は実装 → `pr-review-automerge` で自律マージする。

設計の全体像は `docs/superpowers/specs/2026-06-30-harness-from-feedback-design.md`、worktree 運用は
`dot/claude/rules/worktree-scope.md`、rules の書き方は `dot/claude/rules/rule-authoring.md` を参照。

## Pre-fetched context

!`git worktree list`
!`git rev-parse --abbrev-ref HEAD`

## 不変条件

- 実装・検証・コミット・マージは**委譲先が担う**。この skill は要件確定とプロンプト畳み・起動まで。
- `delegate-to-worktree` は経由しない（グローバル＝dotrc への切替を持たないため）。`claude-worktree` を
  直接呼び、プロンプト先頭に `implement-and-review` の起動命令を置く（同じ起動規約）。
- マージは委譲先の `pr-review-automerge` が repo の保護ゲート（approve / required CI）に従って行う。
  ゲートの無い repo（dotrc に branch protection が無い場合を含む）では即マージし得る点に注意。

## 手順

1. **言語化**: 何を指摘されたか／どの誤挙動か／根本原因か を 1〜3 行で要約する。その場の症状でなく
   **根本原因に当てる**。

2. **強制レベル決定**（弱いが十分な仕組みを選ぶ。下にいくほど強い）:
   - 文脈依存の領域規約 → `.claude/rules/<topic>.md`（領域限定なら `paths` グロブ）
   - 常時オンの一行規約 → ルート `CLAUDE.md` に追記（肥大させない）
   - 機械判定できる規約 → lint ルール or チェックスクリプト
   - ロジックの正しさ → テスト追加
   - コマンド/ツール誤用 → ルール ＋ 必要なら PreToolUse フックでブロック

   ルールは順守が不完全な指針。縛り切りたいコストの高い必須事項は lint/test/hook へ昇格する。
   常時適用か文脈依存かの振り分けはこの skill が判断する（毎回ユーザーに問わない）。

3. **配置先判定**: 現プロジェクト固有なら現 repo の `.claude/`。横断的・個人の癖ならグローバル
   （dotrc）。**グローバル化のときだけユーザーに確認する**。

4. **プロンプト畳み**（自己完結。委譲先は会話履歴を持たない）:
   - 先頭に `implement-and-review` 起動命令
   - 参照ファイルは worktree 内で完結させる。通常は本文へ畳み込む。畳めない未 commit・gitignore
     済みファイル（spec 等）は `--seed <path>` で worktree へ入れ相対パスで参照させる（worktree 外の
     絶対パス Read は承認待ちになり、人間不在の委譲先が固まる。`worktree-scope.md` §6）
   - artifact 種別（rule / CLAUDE.md 追記 / lint / test / hook）・配置パス・対象 repo
   - 内容の骨子（理由ベースのソフト指針の本文・由来）
   - rule を書く場合は「**既存のルールファイル（リポジトリの `.claude/rules/*.md`、dotrc なら `dot/claude/rules/*.md`）を1つ Read して形式を踏襲せよ**」と指示する（Read 経由で `rule-authoring` メタルールを確実にトリガーさせるため）
   - `paths` グロブ（領域限定なら）
   - **受け入れ確認**: test/lint は過去の誤りを実際に捕まえること。ルールのみなら「どの状況で
     ロードされ何を防ぐか（paths と想定シナリオ）」を明記させる
   - コミットメッセージは指摘を参照する旨

   プロンプト雛形:

   ```
   implement-and-review を使って以下のハーネスを実装してください。

   ## やること（WHAT）
   - 指摘: <1〜3行の言語化（根本原因含む）>
   - artifact: <rule / CLAUDE.md / lint / test / hook>
   - 配置: <パス>（対象 repo: <現 repo or dotrc>）
   - 内容の骨子: <理由付きソフト指針の本文 / 由来>
   - rule の場合: 既存のルールファイル（.claude/rules/*.md、dotrc なら dot/claude/rules/*.md）を1つ Read して形式（paths/理由併記/ソフト指針/由来）を踏襲すること
   - 受け入れ確認: <test/lint が過去の誤りを捕まえる / rule のロード条件と防げるシナリオ>
   - commit: 指摘を参照したメッセージで

   ## 進め方
   1. 要件は上で確定済み。開く論点が無ければ brainstorm はスキップして実装へ
   2. 実装し、受け入れ確認を満たす
   3. PR を出し、pr-review-automerge で merge
   ```

5. **起動**: `claude-worktree` を直接呼ぶ。branch は `harness/<slug>`、name は `harness-<slug>`
   （`[A-Za-z0-9_-]+`、pre-fetch した worktree 一覧と衝突しない名に）。
   委譲先は `delegate-to-worktree` と同じ B の役なので、`--model opus` でモデルを固定する。
   - リポジトリ固有: `claude-worktree --model opus [--seed <path>]... harness-<slug> -b harness/<slug> -- "<prompt>"`
   - グローバル（dotrc）: `claude-worktree --self --model opus [--seed <path>]... harness-<slug> -b harness/<slug> -- "<prompt>"`

6. **報告して終了**（fire-and-forget）: `claude-worktree` の出力（worktree / branch / session /
   model / attach コマンド）をそのまま伝え、加えて以下を簡潔に報告する:
   - 捕捉した指摘（言語化）
   - 置いた場所（rules / CLAUDE.md / lint / test / hook）と対象 repo
   - ロードされる条件（paths と想定シナリオ。rule の場合）
   - branch 名とマージ方法（委譲先が pr-review-automerge まで自走。マージは保護ゲート依存）
   - マージ後の後始末（ガイダンス）: `git-reap-gone`（`[gone]` 化した委譲ブランチ／worktree を
     保守的に reap。詳細は worktree-scope.md §7）
