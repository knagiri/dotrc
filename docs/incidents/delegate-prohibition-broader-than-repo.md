# 委譲プロンプトの禁止事項が repo の境界より広く、委譲先が repo の手順と板挟みになった

## 経緯

業務 repo（monorepo）への委譲で、委譲元が `## 禁止事項` に「`.env*` ファイルを読まない・
編集しない」と例外なしで書いた。この文言は dotrc の skill・rule に由来するものではなく、委譲元が
その場で書いたものだった。

その repo のある app の CLAUDE.md は、OpenAPI スキーマの生成手順を「git 管理下のテンプレート
`.env.ci` を source してから生成コマンドを実行する」形で定めている。委譲先は OpenAPI の生成が
要る場面で、禁止事項に従えば repo の手順を実行できず、repo の手順に従えば禁止事項を破る状態に
なり、どちらも選べずに止まった（委譲先の報告による）。

repo 側の grant と doc は食い違っていなかった。repo の deny は実値を持つ `.env` 系だけを対象に
しており、Claude 設定に関する repo の doc も「実値を持つファイルは deny の対象で、git 管理下の
テンプレートは対象外」と切り分けている。誤りは、委譲プロンプトの禁止事項がこの境界より広かった
ことにある。

## 実行したコマンドと観測した出力

対象 repo の root で deny の `.env` 系を確かめた。`.env.ci` に一致する rule は無かった。

```
$ rg -n '\.env' .claude/settings.json
```

出力に並んだ deny は `Read(**/.env)`、`Read(**/.env*.local)` と、`.env.<環境名>`・`.envrc` を
個別に名指しする形だけで、`.env.ci` に一致するものは含まれなかった。

dotrc 側に一律禁止の出どころが無いことも確かめた。

```
$ git grep -n '\.env' origin/main -- dot/claude/settings.json dot/claude/skills
origin/main:dot/claude/settings.json:127:      "Read(.env)",
origin/main:dot/claude/settings.json:128:      "Read(app/.env)",
```

出たのは global deny の `.env` 完全一致 2 件だけで、`.env.ci` には一致しない。skill 側に `.env`
を一律に禁じる記述は無かった（base 指定にしたのは、この PR 自身が skill に例として `.env*` を
書き足すため）。

## 直し方

委譲プロンプトの禁止事項には、repo の deny・CLAUDE.md 等の doc・global の rule が既に担保して
いない、そのタスク固有の制約だけを書く。委譲先は worktree を cwd にした通常の session なので
repo の doc と global の rule を読み込み、deny は prompt と無関係に harness が強制する。それらを
禁止事項へ書き写しても効き目は増えず、要約の過程で今回のように境界が広がる。この件で守りたかった
実値を持つ `.env` 系は repo の deny が既に担保していたので、禁止事項に書く必要自体が無かった。
repo の grant を広げる変更は要らない（grant と doc は既に一致しており、
塞いでいたのは委譲プロンプトだけだったため）。

## 反映先

- `dot/claude/skills/delegate-to-worktree/SKILL.md` 不変条件「破壊的・不可逆・外向きの操作で
  スコープ外のものがあれば…」の項（禁止事項に書くのはタスク固有の制約だけ、とする段落）
