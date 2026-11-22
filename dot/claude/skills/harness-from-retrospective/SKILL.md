---
name: harness-from-retrospective
description: 委譲されたタスクなどを完遂した直後に、自分の作業を振り返って「こうすればよかった」を恒久ハーネス（rule / CLAUDE.md / lint / test / hook / allowlist）の候補として拾い、観測として起票するときに使う。実装はしない。「この作業を振り返って提案して」「振り返ってハーネス提案して」等の依頼でも使う（提案は観測の起票として出る）。
allowed-tools: Read, Glob, Grep, Bash(gh-issue-file *)
---

# harness-from-retrospective

タスクを完遂した agent が**自分の実行文脈を振り返り**、再発防止・改善に値する学びを恒久ハーネスの
候補として拾い上げ、**観測 issue として起票して終わる**。実装はしない。

harness-from-feedback（入口＝ユーザーの指摘）に対し、本 skill は**入口＝自己内省**。起票した
観測は日次の crawler がグループへ束ね、件数が閾値に届いたグループだけが構造的な改善の PR まで
自動で回る（`dot/claude/rules/issue-workflow.md`）。設計は
`docs/superpowers/specs/2026-07-25-harness-from-retrospective-design.md` を参照。

## いつ呼ばれるか

- タスクを完遂した直後（PR の review・merge まで終えた、または途中で停止した時点）。振り返りの
  材料になる実行文脈がまだ手元に残っているうちに使う。ただし委譲プロンプト等で振り返りの
  スキップが明示されているタスク（承認済みのハーネスを実装するタスクなど）には使わない
  （ハーネス作業からハーネス候補を拾う再帰でノイズが増えるため）。ハーネスに触れるというだけでは
  スキップの根拠にならない。明示があるのに呼ばれたら、「対応すべきハーネスなし」として no-op
  終了する。
- 手動（「この作業を振り返ってハーネス提案して」等）。手動でも手順は同じで、方針は観測として
  起票する（起票の中身が提案である）。ユーザーが起票せず提示だけを求めたとき（「起票はしないで」等）は、
  手順 3 の起票を省き、方針を最終メッセージに書いて終える。

## 前提

- 振り返るのは**その作業をやり切った自分自身**。自分の実行文脈（推測で決めた箇所・accept で
  止まった箇所・代替の有無・繰り返した失敗）を材料にする。claude-queue 等の外部ソースは使わない。
- **起票までで止める**。grant（allowlist）を書いたり rule/test を実装したりはしない。

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
   - 内容の骨子（理由付きソフト指針の本文。由来は番号で示さず、一般化して本文へ書く。経緯は
     incident doc に置く。範囲・対象 repo が dotrc 以外のときの扱い・置き場所・書き方は `dot/claude/rules/rule-authoring.md`「由来は一般化して本文に書き、経緯は incident doc に置く」節）
   - 受け入れ確認（どの状況でロードされ何を防ぐか 等）

3. **観測として起票して終了**: 改善点ごとに観測 issue を 1 件起票する。重複を気にして起票を
   控えない。同じ指摘が別 session から何度も入ることが優先度の信号になる。
   - `gh-issue-file --global --list-groups` で open なグループを見て、根本原因が合うものがあれば
     `--parent <N>` を付ける。迷えば付けない（日次の振り分けが拾う）
   - 本文は harness template の見出し（やること（WHAT）/ 設計（HOW）/ 受け入れ確認 / 由来）に
     手順 2 の方針を写し、`$CLAUDE_JOB_DIR` 配下のファイルに書く。具体名（組織名・repo 名・
     サービス名など）を書かない
   - `gh-issue-file --global --kind harness --title <title> --body-file <path> [--parent <N>]`
   - exit 3 で denylist に当たったら、具体名を除いて書き直して再実行する。denylist が無いため
     に拒否されたら起票せず、方針を下の報告に書く
   - 最終メッセージには起票した URL だけを書く。方針の本文は issue にある。既定の background
     委譲先として走っているなら、最終メッセージは誰にも読まれないまま委譲元に閉じられるので、
     委譲元への完了報告（SendMessage）に URL を添えて届ける

   **改善点が無ければ「対応すべきハーネスなし」と述べて no-op 終了**する。実装や委譲はしない。

## 起票の後（この skill の外）

起票した観測をどう消化するかは `dot/claude/rules/issue-workflow.md` が持つ。この skill の task は
起票した時点で完了で、起票した観測を残タスクとして数えない。

すぐに直したい学びは、ユーザーが `harness-from-feedback` を起動して即時に委譲できる。
allowlist（grant）候補も渡してよい。ただし **grant を含む委譲は auto-merge させず、人間の
approve を待つ**（条件と理由の正典は `gh-commands.md` §5「grant 変更を含む PR は auto-merge
させない」）。この skill 自身が grant を書かないことは変わらない（下の不変条件）。

## 不変条件

- 起票まで。実装・委譲・grant 記述はしない。起票は `gh-issue-file` 経由に限る。
- 対象は「恒久ハーネスにする価値のある学び」。無ければ no-op（空振りは正常）。
