---
name: harness-from-retrospective
description: 委譲タスクを完遂した agent が自分の作業を振り返り「こうすればよかった」を恒久ハーネス（rule / CLAUDE.md / lint / test / hook / allowlist）の候補として拾い、方針として提示する。実装はせず提案まで。implement-and-review の末尾から呼ばれるほか、「この作業を振り返って提案して」等で手動起動する。
allowed-tools: Read, Glob, Grep
---

# harness-from-retrospective

タスクを完遂した agent が**自分の実行文脈を振り返り**、再発防止・改善に値する学びを恒久ハーネスの
候補として拾い上げ、**方針として提示して終わる**。実装はしない（承認後に harness-from-feedback が担う）。

harness-from-feedback（入口＝ユーザーの指摘）に対し、本 skill は**入口＝自己内省**。両者は
「内省で発見・提案 → 人間が承認 → feedback で実装」と直列に合成される。設計は
`docs/superpowers/specs/2026-07-25-harness-from-retrospective-design.md` を参照。

## いつ呼ばれるか

- `implement-and-review` の末尾（pr-review-automerge の後）。ただし委譲プロンプトに自己内省を
  スキップする明示があれば呼ばれない（ハーネスタスク自身の内省による再帰ノイズを避けるため）。
- 手動（「この作業を振り返ってハーネス提案して」等）。

## 前提

- 振り返るのは**その作業をやり切った自分自身**。自分の実行文脈（推測で決めた箇所・accept で
  止まった箇所・代替の有無・繰り返した失敗）を材料にする。claude-queue 等の外部ソースは使わない。
- **提案までで止める**。grant（allowlist）を書いたり rule/test を実装したりはしない。

## 手順

1. **自己内省**: 「この作業、こうすればよかった」を実行文脈から抽出する。accept stall に限らず
   横断的に拾う。例:
   - 一次情報を取らず推測で方針を決めて失敗した → プロセス失敗 → rule 候補
   - accept 要求を出したが代替手段があった → 「代替があった」を rule 候補（allowlist 化ではない）
   - 繰り返し stall した benign なコマンド → narrow allow / bin ラッパー候補

   恒久ハーネスにする価値のある「次から効かせたい学び」だけを対象にする。そのタスク限りの
   症状・一過性の事象は拾わない。

2. **対策（方針）を組む**: 各改善点に次を付ける（harness-from-feedback にそのまま渡せる粒度で）:
   - 指摘の言語化（根本原因）
   - artifact 種別: rule / CLAUDE.md 追記 / lint / test / hook / allowlist
   - 配置パスと対象 repo（現 repo or dotrc）
   - 内容の骨子（理由付きソフト指針の本文・由来）
   - 受け入れ確認（どの状況でロードされ何を防ぐか 等）

3. **方針を提示して終了**: 上記を構造化した**最終メッセージ**として出力する（新規ファイルは
   作らない。出力は実行中セッションの最終メッセージとして残る。`--tmux` 委譲先なら
   `gts <session>` / `tmux attach` で後から読める。既定の background 委譲先は人間不在で走り、
   最終メッセージは誰にも読まれないまま委譲元に閉じられるので、`implement-and-review` 手順 6 の完了報告
   （SendMessage）に要点を添えて委譲元へ届ける）。**改善点が無ければ
   「対応すべきハーネスなし」と述べて no-op 終了**する。実装や委譲はしない。

## 承認後（この skill の外）

ユーザーが方針を review し、承認した項目の行き先を選ぶ。経路は 2 つあり、**どちらを選ぶかは
ユーザーが決める**。

- **今すぐ実装する** → `harness-from-feedback` を起動する。以降は harness-from-feedback の
  既存フロー（要件確定 → 委譲 → 実装 → PR）
- **backlog へ回す** → `gh-issue-file` で起票する（`issue-workflow.md` §1）。以降はその rule の
  §3 の人間ゲートと §6 の消化経路に乗る。起票した時点でその気づきに対する task は完了で、
  実装するのは別の主体になる（§6.1 / §6.2）

**この skill が自動で起票することはない。** 起票するかどうかの判断はユーザーに残す。理由は
`docs/design/agent-issue-workflow.md`「代替案 — 自己内省から自動起票」を参照。

allowlist（grant）候補も harness-from-feedback へ渡してよい。ただし **grant を含む委譲は
auto-merge させず、人間の approve を待つ**（条件と理由の正典は `gh-commands.md` §5「grant 変更を
含む PR は auto-merge させない」）。この skill 自身が grant を書かないことは変わらない（下の
不変条件）。変わるのは、承認後の実装を人間に限るか委譲できるかのほうである。

## 不変条件

- 提案のみ。実装・委譲・grant 記述はしない。
- 対象は「恒久ハーネスにする価値のある学び」。無ければ no-op（空振りは正常）。
