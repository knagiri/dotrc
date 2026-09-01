---
name: es-create-pr
description: コンテキストに基づいた説明付きで GitHub Pull Request を作成する
allowed-tools: Bash(git status *), Bash(git diff *), Bash(git log *), Bash(git rev-parse *), Bash(git fetch origin *), Bash(git push *), Bash(git branch -m *), Bash(git ls-files *), Bash(gh repo view *), Bash(gh pr create *), Bash(gh pr edit *), Bash(gh pr list *), Bash(gh pr close *), Bash(gh run list *), Bash(./scripts/agent_pr/run.sh *), Bash(echo *), Read, Glob, Grep, AskUserQuestion
---

# es-create-pr

業務 repo の共通 skill `es-create-pr` を、個人設定側で上書きするための shim。同名 skill は
personal が project を上書きするので、repo の CLAUDE.md が名指しする `es-create-pr` という
名前・起動条件はそのままに、中身だけがこれに差し替わる。

<!--
  存在理由: 業務 repo に agent レーン（`agent/**` への push を GitHub Actions が拾い、GitHub App
  の installation token で PR を作る = PR の author が bot になるので push した本人が approve
  できる）が入ったが、「既存の es-create-pr を前提にワークフローを組んでいる人がいる」という
  要望により、repo 共通の es-create-pr には統合されなかった。既定の手順へ組み込むかは各自の
  個人設定に委ねられている。

  したがって repo 側が「共通 skill は agent レーンを扱わない」という方針をやめたら、この shim は
  役目を終える。その時点で見直すこと。
-->

## この shim が持つもの

タイトル・本文・コンテキスト収集は個人 skill **`my-create-pr` を正**とし、そちらに従う。
ここが差し替えるのは **PR 作成の段だけ**。手順を写し取らないので、`my-create-pr` 側が
変わっても drift しない。

## 手順

1. **`~/.claude/skills/my-create-pr/SKILL.md` を Read し、その手順 1〜5 に従う**（コンテキスト
   収集 → 未コミット変更の確認 → PR テンプレート → 本文ドラフト → self-check）。手順 6 の
   「Push → 作成」だけを以下で置き換える。

2. **レーンの自己判定**: `./scripts/agent_pr/run.sh` が存在しなければ、この repo に agent
   レーンは無い。`my-create-pr` の手順 6 をそのまま実行して終わる（`gh pr create`）。

3. 存在する場合、現在のブランチ名と push 状況で分岐する。

   | 現在のブランチ | 動作 |
   |---|---|
   | `agent/` で始まる | そのまま agent レーン（手順 4） |
   | `agent/` 以外 **かつ未 push**（upstream 未設定） | `git branch -m agent/<type>/<topic>` でリネームしてから agent レーン |
   | `agent/` 以外 **かつ push 済み** | 通常レーン（`my-create-pr` 手順 6） |

   push 済みかは `git rev-parse --abbrev-ref --symbolic-full-name @{upstream}` が成功するかで見る。

   リネームを未 push に限るのは、`run.sh` が `HEAD:refs/heads/<branch>` へ push するので
   ローカルと別名のリモートブランチを作れてしまい、そうすると upstream の追跡と
   `git-reap-gone` の後片付けが壊れるため。push 済みのブランチは既にレーンが決まっていると
   みなし、混ぜない。

   `<type>` は元のブランチ名の prefix をそのまま引き継ぐ（`fix/foo` → `agent/fix/foo`）。有効な
   prefix は `feature` / `fix` / `hotfix` / `refactor` / `test` / `ci` / `docs` / `dependencies`
   で、`run.sh` が push 前にこの形式を検査する。prefix が無い・一覧に無い場合は適切なものを
   選んで付ける。**type を省くと Release Drafter の autolabeler にマッチせず、リリースノートで
   未分類になる。**

4. **agent レーン**: push と PR 作成の待機を `run.sh` に任せ、返ってきた PR 番号へタイトルと
   本文を入れる。

   ```
   ./scripts/agent_pr/run.sh agent/<type>/<topic>
   ```

   PR 番号を標準出力に返す（実測で push から約 9 秒）。

   ```
   gh pr edit <番号> --title "<title>" --body-file - <<'PR_BODY_EOF'
   <body>
   PR_BODY_EOF
   ```

   - **`gh pr create` は実行しない。** PR の author を bot にするため、作成はワークフローに任せる。
   - **`gh pr ready` は不要。** 以前は draft で PR を作っていたが、現在は最初から ready で作る
     （draft でも CI が回る repo なので、draft → ready にすると `opened` と `ready_for_review`
     で CI が二重に走る）。
   - タイトルと本文がプレースホルダ（タイトル = ブランチ名、本文 = `requested by @<actor>`）で
     見えるのは `gh pr edit` までの数秒。

5. **`run.sh` が返らなかった場合**: 原因は `PR_BOT_ALLOWLIST`（repository variable）に未登録か、
   runner の遅延。通常レーンへ切り替える前に、遅延した PR が無いか確認する。

   ```
   gh run list --workflow create-pr.yml
   gh pr list --head <ブランチ>
   ```

   確認を挟むのは、`run.sh` のタイムアウトが push もワークフロー実行も取り消さないため、後から
   PR が作られうるから。見つかればそれを使う（手順 4 の `gh pr edit` へ）。見つからず通常レーンへ
   切り替えるなら、agent ブランチ側の PR があれば close し、ブランチを削除してから、`agent/`
   以外の名前で push し直す。
