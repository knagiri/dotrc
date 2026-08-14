---
paths:
  - "**/skills/**/SKILL.md"
  - "**/agents/*.md"
---

## SKILL.md / agent 定義の description は「いつ使うか」に絞る

frontmatter の `description` には skill / agent の**起動トリガー**（どんな状況・症状で使うか）
を書き、本文の手順・ワークフローは要約しない。SKILL.md や agent 定義を書く・直す作業でだけ
効く話なので `paths` でスコープし、常時ロードはしない。

出典: `superpowers:writing-skills` skill の "Skill Discovery Optimization" → "1. Rich
Description Field" 節（"CRITICAL: Description = When to Use, NOT What the Skill Does"）。

### 要約を避ける理由は 2 つある

**(a) 本文の方針変更に取り残される。** description は本文とは別の場所で保守されるため、
本文の手順を変えても description の要約だけ旧方針のまま残りやすい。しかも description は
skill 一覧として常時 system prompt に載るので、旧方針が「毎回ロードされる誤情報」として
居座る。本文中の記述なら読んだ agent が矛盾に気づけるが、description は本文を読む前に
参照されるので気づく機会がそもそも無い。

**(b) 本文を読まずに済ませるショートカットが生まれる。** これは非直感的なので実測ごと
残す。上記の節いわく、description が "code review between tasks" とワークフローを要約して
いたために、本文のフローチャートが 2 段階レビュー（spec 準拠 → コード品質）を明示していた
にもかかわらず agent はレビューを 1 回しか実行しなかった。description を
"Use when executing implementation plans with independent tasks"（要約なし）に変えたところ、
agent は正しくフローチャートを読んで 2 段階を実行した。要約された手順は agent にとって
「本文を読まなくても済む要点」に見え、本文はスキップされる documentation に落ちる。

### トリガー用キーワードは落とさない

description は skill の起動条件そのものを兼ねるので、整理する過程で検索性を削らない。
ユーザーが言いそうな語（「ハーネス化して」「delegate して」等）・症状・同義語は残す。
減らす対象は「何をするか（手順）」であって「どういうときか（トリガー）」ではない。

### 本文の方針を変えたら description を点検する

要約を含まない description なら本文の変更で乖離しにくいが、手順の変更がトリガー条件
そのものを変えることはある（適用範囲が狭まった、別 skill へ分割した等）。本文の方針・
手順を変える PR では、description が旧方針を述べていないか点検する。

### agent 定義も同じ

`agents/*.md` の description は「どんなタスクで dispatch するか」を示す点で skill と同根。
選択に必要な役割の一行説明（「〜を担う実装役」等）は残してよいが、本文に書いた手順・判断
基準をそこへ写さない。乖離（a）と本文スキップ（b）はどちらも同じように起きる。

### 既存 description の一括是正はしない

現状 dotrc の SKILL.md description の多くはこの指針に反してワークフローを要約している
（`implement-and-review` が典型）。これらは順次個別に是正する対象で、一括では書き換えない。
description は起動トリガーを兼ねているため、まとめて書き換えると skill が発火しなくなる
回帰を招きうる。どのキーワードを残すかはユーザーが個別に判断すべき領域であり、agent が
自律 merge するフローで巻き取る種類の変更ではない。

---

由来: knagiri/dotrc#26。`implement-and-review` の SKILL.md 本文から「無条件に subagent 委譲を
促進する」ニュアンスを外したのに、frontmatter の description は旧方針（「難度別の実装 subagent
へ dispatch しながら実装し」）を述べたまま残り、独立した判定役に指摘されて直した。根本原因は
同期の失念ではなく、description が本文の手順を要約していたこと自体。
