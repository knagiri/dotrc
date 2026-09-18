---
name: my-commit
description: Conventional Commits 形式で変更をステージ・commitする
allowed-tools: Bash(git status *), Bash(git diff *), Bash(git log *), Bash(git add *), Bash(git commit *), Bash(echo *), Read, Glob, Grep
---

## Pre-fetched context

!`git status --short`
!`git diff --stat`
!`git log --oneline -5`

## Instructions

変更をcommitする。完了後にまとめを出力しないこと。

1. **変更を論理単位に分割する。** 原則は分割。結合するのは、片方がなければもう片方が意味をなさないほど密結合な場合のみ。各ファイル・ハンクを以下の観点で分類する:
   - **スコープ**が異なる（例: 異なるアプリ、異なるパッケージ） → 別commit
   - **意図**が異なる（例: バグ修正 vs 新機能 vs リファクタリング vs ドキュメント） → 別commit
   - 構造的整理と振る舞いの変更が混在 → 別commit（構造整理を先にする）
   - 迷ったら分割する。小さいcommitのほうがレビューもリバートも容易。
   - このPRと関係のない変更はcommitしない
2. commitごとに: `git add <files>` → `git diff --cached --stat` → commit（1 ファイル内で分けるときは後述の節）
3. メッセージ: Conventional Commits 形式 (`type(scope): description`)、**常に英語**（ユーザーの言語によらず）、命令形。
   - body にはその変更を行った**理由**や背景を簡潔に記述する。将来の読み手が diff を読み直さなくても動機を理解できる程度に。
   - subject line だけで自明な場合（例: typo 修正）に限り body を省略してよい。
4. ユーザーへの確認が必要なのは以下の場合**のみ**: 無関係な変更が多数あり分類が不明確、シークレットの可能性がある、commitすべきでない生成ファイルが含まれる。

## 1 ファイルに別々の論理変更が混ざったとき

分割が要る状態を作らないのが第一。論理変更を 1 つ書いたら commit してから次へ進む。混ぜてから
分けるのは避けられる手戻りである。

混ざってしまったら、patch を経由して hunk 単位で stage する（`git add -p` / `-i` は対話 UI の
ため使えない）。

```
git diff -- <file> > "$(git rev-parse --git-path split.patch)"
# split.patch を Edit ツールで開き、この commit に含めない hunk（@@ 行から次の @@ 行の手前まで）を削る
git apply --cached "$(git rev-parse --git-path split.patch)"
git diff --cached                        # この論理変更だけが stage されたか確認
```

patch は `git rev-parse --git-path` で解決した `.git` 配下に置く。repo の外へ書き出すと
承認プロンプトが出うるが、`.git` 配下は repo の内側なので出ない。`$VAR` に代入せず
command substitution をそのまま埋め込んでいるのも同じ理由（bash-command-constraints.md
参照）。`--git-path` は linked worktree でも正しい実パスを解決する（`.git` がファイルの
worktree でも安全。worktree-scope.md §1）。hunk の削除は Edit ツールで行う（`sed` は
command-selection.md により使わない。Edit は Bash の allowlist と無関係に動くので、この
編集自体は承認が要らない）。

`--cached` は index にだけ適用するので working tree は変わらず、削った hunk は unstaged の
まま残る。commit したら、残りの変更に同じ手順を繰り返す。

`git checkout -- <file>` で working tree を HEAD へ戻し、論理変更を 1 つずつ書き直して commit
する手順は取らない。working tree を捨てる破壊的な操作なので、退避が不完全なら作業を失い、
書き直しに漏れがあっても比較対象が無ければ気づけない。
