---
name: proofread-doc
description: 「この doc を校正して」「designdoc をレビューして」「書きすぎを直して」「文章を推敲して」「冗長なので削って」「この設計ドキュメントを読みやすくして」等、人が読む文書（designdoc / ADR / spec / README 等）の校正・推敲・レビューを依頼されたときに使う。AI に書かせた doc を人手で仕上げるとき、他人の doc PR をレビューするときも含む。
allowed-tools: Read, Grep, Glob
---

# proofread-doc

doc の校正を 4 パスに分けて順に回す。パスごとに検出対象も直しかたも別物なので、まとめて
1 回で見ずに分ける。特に文体パス（パス 3）で止めると「書きすぎ」が残る。

**判定基準はこの skill には書かない。** 実体は `doc-authoring` rule 側にあり、ここは進め方
だけを持つ（二重管理を避けるため）。

## 手順 0: 基準を読む

`doc-authoring` rule は `paths`（`**/*.md` / `**/*.mdx`）でスコープされており、対象 doc を
Read / Edit した時点で自動的にコンテキストへロードされる。**既にロード済みならそれを使い、
無いときだけ Read する。** 未ロードで Read するパスは、dotrc の checkout 内で作業している
なら `dot/claude/rules/doc-authoring.md`、それ以外は `~/.claude/rules/doc-authoring.md`。
以下の各パスは、この rule の同番号の観点を指す。

対象 doc を通読し、doc の種類（designdoc / ADR / spec / README …）と読者を把握する。パス 2・3・
4 の判断は読者が誰かに依存する。

スキルのディレクトリにある [workflow.md](workflow.md) を読み、4 パスと結果の提示に従う。
