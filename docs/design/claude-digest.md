# claude-digest — Claude Code セッションの朝の日報

`bin/claude-digest` は、Claude Code のセッション記録から「昨日なにが着地したか」と
「次にどの session をどの順で見るか」を毎朝まとめる。ユーザー個人用。

狙いは 達成の記録 と session の交通整理 の 2 つだけで、session を開けば分かる内容には
踏み込まない。出力は session を優先度順に並べた 1 本のリストで、各 session に「着地したもの」と
「残っているもの」が付く。

## 関連ファイル

| 領域 | 実体 |
|---|---|
| 本体 | `bin/claude-digest` |
| テスト | `test/claude-digest.test.sh` |
| スケジュール | `dot/systemd-user/claude-digest.{service,timer}` |
| 展開 | `bin/deploy.sh` の `MergeLinkMap["systemd-user"]` |
| 朝の読み方 | `dot/tmux.conf` の `bind-key e` |
| 隣接する仕組み | `src/claude-queue/`、`bin/claude-worktree`、`bin/git-reap-gone`（`docs/design/claude-tmux-worktree.md`） |

## 全体構造 — 2 段の map-reduce

```
~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl
        │
        │  段1（map）: 1 session = 1 チャンク → claude -p
        ▼
~/.claude/digests/<YYYY-MM-DD>/<session-uuid>.md      中間サマリ
        │
        │  段2（reduce）: 中間サマリ全部 + git から取った事実 → claude -p
        ▼
~/.claude/digests/<YYYY-MM-DD>.md                     日報
```

中間サマリをファイルに残すのは、**段2 だけ作り直せるようにするため**。日報の書きぶりを
直したいときに再生成が要るのは段2 だけで、段1 の LLM 呼び出し（session 数ぶん）は使い回せる。
これがそのまま冪等性でもあり、`--generate` を同じ日に何度撃っても中間サマリは再利用され、
過去日の backfill も同じ経路で通る。

### CLI

```
claude-digest                       最新の日報を表示
claude-digest <YYYY-MM-DD>          日付指定で表示
claude-digest --generate [<date>]   生成。日付省略時は「直近に閉じた日」
claude-digest --generate --dry-run [<date>]
                                    収集した事実ブロックを出力して終わる（LLM を呼ばない）
```

`--dry-run` は仕様の 3 形式に対する追加で、**収集ロジックを LLM 抜きで観測するために足した**。
テストはすべてこの出力に対して書かれている。

表示は stdout が tty のときだけページャに渡し、`bat` → `less` → `cat` の順で選ぶ
（選択理由は `bin/claude-digest` の `show()` 内コメントを参照）。ページャの選択は
claude-digest 側に一本化しており、`dot/tmux.conf` の binding はページャを指定しない。

## 日の境界は JST 05:00

深夜作業を前日側に落とすため、日は 05:00 JST から 05:00 JST までとする。

`timestamp` は ISO 8601 UTC のミリ秒付き（`2026-09-08T12:08:36.197Z`）。UTC に +4 時間
（JST の +9h から境界の 5h を引く）して日付を取れば、それがその entry の「日」になる。

```jq
(.timestamp | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) as $e | ($e + 14400 | strftime("%Y-%m-%d"))
```

**`fromdateiso8601` は小数秒を受け付けない。** `.197Z` を渡すと
`date "2026-09-08T12:08:36.197Z" does not match format "%Y-%m-%dT%H:%M:%SZ"` で落ちるため、
`sub` は飾りではなく必須である。実測上すべての timestamp がミリ秒付きなので、この 1 手が
欠けると transcript が丸ごと読めなくなる（jq が非 0 で落ち、スクリプトはそのファイルを
skip する）。

検証済みの境界挙動:

```
2026-09-08T19:30:00Z -> JST 09-09 04:30 -> day=2026-09-08   （深夜作業は前日側）
2026-09-08T20:30:00Z -> JST 09-09 05:30 -> day=2026-09-09
```

## transcript の構造

### 何が入っているか

1 session = 1 ファイル（`<session-uuid>.jsonl`）。追記専用の JSONL で、`type` は 15 種類ほど。
実測（ある 1 ファイル、1256 行）:

```
assistant 399 / user 265 / attachment 182 / ai-title 76 / last-prompt 78 / mode 77
permission-mode 77 / system 71 / atis-latch 43 / relocated 40 / pr-link 37
file-history-snapshot 23 / queue-operation 12 / file-history-delta 5 / cost-state 1
```

`timestamp` を持たない entry（`last-prompt`, `ai-title` 等）があるので、日の判定は
`.timestamp` の有無で必ずガードする。

### `type == "user"` の内訳は `origin.kind` で割れる

`user` entry は人間の発言だけではない。同ファイルの実測:

```
origin.kind == "human"              22   人間のプロンプト
origin.kind == "peer"                1   別 session からの SendMessage（本文は .origin.body）
origin.kind == "task-notification"   4   委譲先 subagent の完了通知
origin == null                     238   tool_result 等
```

`task-notification` の `.message.content` は 1 本の文字列で、`<result>` に委譲先の最終報告が
全文入る。日報にとって最重要の素材であり、定型の `<note>`（毎回同じ約 300 文字）だけ剥がす。

### 素材として採るもの・捨てるもの

| 種別 | jq |
|---|---|
| 人間のプロンプト | `.type=="user" and .origin.kind=="human"` の `.message.content`（string） |
| assistant の発話 | `.type=="assistant"` の `.message.content[] \| select(.type=="text") \| .text` |
| 委譲先 subagent の最終報告 | `.type=="user" and .origin.kind=="task-notification"` の `.message.content` |
| peer 報告（SendMessage） | `.type=="user" and .origin.kind=="peer"` の `.origin.body` |

除外: `tool_use` / `tool_result` / `thinking` / `attachment`。`isSidechain: true` の entry と
`<project>/<uuid>/subagents/agent-*.jsonl` も対象外（subagent の中間思考であって、成果は
`task-notification` の `<result>` に集約されるため）。

**jq の落とし穴**: `.message.content[]?` の中へ入ると `.sessionId` などトップレベルの
フィールドは null になる。必要なら `.sessionId as $s |` で先に束縛する。

### 素材ゼロの session は一覧に載せない

上の表で 1 件も採れなかった session は、`session_ids` を確定する段階で落とす。事実ブロックにも
日報にも一切現れない。`system` / `attachment` / `last-prompt` しか持たない 10 行程度の
transcript が実際に生まれ、確認すべきことが何も無いのに「確認すべき session」として並ぶため。

判定は**段1 が使う `material.jq` そのもの**で、その出力が空なら落とす。`title` の有無や
`first_prompt` の有無で代用しない — assistant の発話だけを持つ session はそのどちらも欠くが
素材はあるので、代用すると誤って落ちる。

抽出は収集ループの中で作業用 `mktemp -d` へ 1 度だけ行い、段1 はその結果を読み直す。書き出し先が
`$CLAUDE_DIGEST_DIR` の外なので、`--dry-run` の「何も書かない」は保たれる。

### 素材量（2026-09-08、cli セッションのみ）

```
採用: asst_text 270,847 / task_notif 210,405 / human_prompt 43,990 / peer 30,144 = 555,386 文字
除外: tool_result 2,353,805 / tool_use 951,834                                  = 3,305,639 文字
session: 69 件 → cli のみで 30 件。平均 8,289 文字 / 最大 70,668 文字
```

実装後に同じ日を測り直したところ `task_notif` / `human_prompt` / `peer` は 1 文字違わず一致し、
`asst_text`（219,230）と tool 系（tool_result 1,837,530 / tool_use 936,131）は tool payload の
数え方の違いぶんだけ小さく出た。結論は変わらない — **採る側が約 50 万字、捨てる側がその 6 倍**。

**チャンク単位を session にしたのはこの数字による。** 最大 70,668 文字は 1 回の `claude -p` に
そのまま乗る大きさで、これ以上細かく割る理由がない。逆に日ぶんを 1 チャンクにすると 55 万字に
なり乗らない。session 境界は「1 つの仕事」の境界でもあるので、要約の単位としても自然である。

### compaction は非破壊 — PreCompact フックでの退避は要らない

JSONL は追記専用で、compaction は**新しい要約 entry を後ろに足すだけ**である。boundary より
前の entry は本文を保ったまま残る。したがって「compaction で失われる前に退避する」ための
PreCompact フックは不要で、日報は常に生の transcript を読めばよい。

対照（実測、最大の compacted ファイル 5912 行）:

```
最初の compact_boundary            1295 行目
その compactMetadata.trigger       manual
preservedMessages.allUuids         5 件だけ
boundary より前の 1294 行           本文を持つ entry 130 件、計 92,294 文字がそのまま残存
```

context に引き継がれたのは 5 メッセージだけなのに、ファイル上はその手前の 1294 行が丸ごと
読める。これが「非破壊」の意味である。設計時の測定（同じ boundary 位置 1295、preserved 5 件、
本文 601 entry / 338,290 文字 — 数え方の広さの差）と一致した。

corpus 全体では、body transcript 1009 ファイルのうち compaction 済みは 13 ファイル・22 回で、
`trigger` は**全て `manual`**（設計時は 970 ファイル中 10 ファイル・15 回）。自動 compaction は
まだ 1 度も起きていない。

## 冪等キーは `uuid`。パスをキーにしてはいけない

transcript ファイルは cwd の relocate に追随して project ディレクトリ間を移動する。
実測: 調査中に同一 session の jsonl が `-…-hw-infrastructure/` から
`-…-eversteel-backend-api/` へ移った。`relocated` という entry type が存在するのもこのため。

`uuid`（= ファイル名の basename、`.sessionId` と一致することを 50 ファイル抽出で確認）は
全ファイル横断で重複が無い。したがって収集の重複排除は uuid で行い、パスは一切キーにしない。
候補は mtime の新しい順に読み、同じ uuid を 2 度目に見たら捨てる。

**mtime は候補を絞る前フィルタにのみ使い、活動判定には使わない。** 滞留セッションは meta 行の
書き換えで mtime だけ更新され続けるためである。前フィルタとして安全なのは「その日の entry を
含むファイルの mtime は必ずその日のウィンドウ開始以降」が成立するから — 候補が増える方向にしか
ぶれない。ウィンドウ開始は絶対時刻（`<day-1>T20:00:00Z`）で渡すので、backfill でも
`-mtime -N` の N を絞りすぎる事故が起きない。

実際の絞り込みは `.timestamp` で行う。性能は問題にならない: 全 915 ファイル・771MB の jq
全走査が設計時実測 3.8 秒、実装後の `--generate --dry-run` 1 日ぶんが約 13 秒（git の fetch を
含む）。

## 事実側は git のみ — gh / PAT に依存しない

「着地した PR」も「残骸ブランチ」も git だけから取る。gh を必須依存にしない理由は 2 つ、
いずれも実測:

- 手元の token は eversteel org を解決できない
  （`gh pr list --repo eversteel/eversteel-backend-api` が `Could not resolve to a Repository`）
- 業務リポジトリの PR author は GitHub App（`app/backend-api-ci`）なので `--author=@me` が 0 件になる

`gh` に頼れば PR のタイトル・レビュー状態まで取れるが、上の 2 点で**動かない環境がある**以上、
朝 5 時に無人で走るツールの依存にはできない。必要な情報は git から全部取れる。

### 対象リポジトリの導出

その日の entry の `.cwd` を集め、正規化して畳む。

```
git -C "<cwd>" rev-parse --path-format=absolute --git-common-dir   # → <main-repo>/.git
```

の dirname が main repo の toplevel。worktree もサブディレクトリも 1 発で畳める。

cwd が既に消えている場合（reap 済み worktree。2026-09-08 は 88 cwd 中 21 件）は git に訊けない
ので、2 段のフォールバックを持つ:

1. 旧 worktree レイアウト `<repo>_<name>` — basename の末尾 `_<suffix>` を剥がす
2. 現行レイアウト `<repo>/.worktrees/<name>`（`dot/claude/rules/worktree-scope.md` §6）—
   実在する最初の祖先ディレクトリまで遡って git に訊く

2 の遡りは 1 を包含しないので両方要る（旧レイアウトの worktree dir は repo の隣にあり、
親を辿っても repo に当たらない）。過去の transcript には旧レイアウトが残るため、後方互換として
1 は落とせない。

### 生成前に fetch。ただし `--prune` は付けない

対象リポジトリごとに `git fetch --quiet --no-tags` を撃つ。**`--prune` は付けない。**
`[gone]` を作るのは `git-reap-gone` のトリガーであり（`worktree-scope.md` §7）、日報が
勝手に握ってはいけない。日報は `[gone]` を観測して報告する側に留まる。

### 自分の識別はハードコードしない

git config の `user.email` から GitHub の数値 user ID を実行時に導出する。

```bash
email="$(git -C "$repo" config --get user.email)"   # 65004703+gili-Katagiri@users.noreply.github.com
id="${email%%+*}"
case "$id" in (*[!0-9]*|'') pat="$email" ;; (*) pat="<${id}+" ;; esac
```

noreply 形式（`<数値ID>+<login>@users.noreply.github.com`）でないリポジトリでは、メール
アドレスそのものにフォールバックする。数値 ID を使うのは、表示名やログイン名が変わっても
不変だからである。

**`--author` は正規表現なので `-F`（固定文字列）を必ず付ける。** 手元の git は
`grep.patternType` 未設定＝ BRE 既定なので `+` は今のところリテラルだが、ERE や perl に
切り替わった瞬間 `<65004703+` は「`<6500470` の後に `3` が 1 回以上」になる。BRE でも `.`
はメタ文字なので、メールアドレスへフォールバックした側（`plain@example.com`）は今この瞬間
`plain@exampleXcom` にマッチする。`-F` はその両方を同時に塞ぐ。

対照込みの実測（`eversteel-backend-api`、2026-09-08 の 1 日）:

```
全 commit                52 件
-F --author='<65004703+' 19 件（表示名 3 通り・メール 2 通りを一括で拾う）
偽 ID '<99999999+'        0 件（空振りで真になっていない）
他メンバー '<53592008+'   3 件（機構は動作しており、かつ上の 19 には含まれない）
```

過去 90 日の全 author 25 identity を確認し、`65004703` を含むのは自分の 3 つだけで他人と
衝突しないことも確認済み。

### 着地した PR

merge commit の subject 末尾 `(#N)`（GitHub が「PR タイトルを merge commit のタイトルに使う」
設定のときの形）か `Merge pull request #N from ...` から PR 番号を取り、

```
git log -F --author="$pat" --no-merges "<merge>^1..<merge>^2"
```

が 1 件以上ある merge だけを「自分の PR」とする。merge commit 自身の author はボタンを押した
人（多くの場合 bot）なので、**マージされた側に自分の commit があるか**で判定する。

実測（2026-09-08、`eversteel-backend-api`）で 7 本。実装後の再実行でも同じ 7 本が出た:

```
#6817 mine=5  / #6844 mine=13 / #6885 mine=5 / #6888 mine=6
#6928 mine=1  / #6929 mine=3  / #6924 mine=1
```

### session ↔ PR の紐付けは交差で取る

「その日の着地 PR 番号」∩「その session の transcript が言及する PR 番号（`pull/[0-9]+`）」。

交差を取らないと雑音が乗る。実測で、12 日間走った session は PR 番号を 23 個列挙していたし、
別リポジトリの `#591`〜`#600` が番号だけで混ざった。逆に着地側だけを見ると、どの session の
仕事だったのかが分からない。

交差自体も repo でスコープする。PR 番号は repo をまたぐと一意でないので、突き合わせるのは
番号ではなく repo + 番号であり、session 側は「その session が触った repo」の集合を持つ。
番号だけで突き合わせると、repo A の `#201` に言及した session へ repo B の `#201` が付く。
「紐付いた着地」の集合も同じキーで持つ。裸の番号でキーすると、repo A の `#201` が紐付いた
時点で repo B の `#201` が紐付き済みとみなされ、どこにも出ないまま消える。

同じ理由で、残骸ブランチの状態も repo + ブランチ名でキーする（ブランチ名も repo をまたぐと
一意でない）。事実ブロックの着地・残骸の各行は repo パスを先頭に持ち、読み手も段 2 の LLM も
同名・同番号を区別できる。

関係は n:m でよい（1 PR に実装 / レビュー / automerge の複数 session、1 session に複数 PR）。
交差しなかった着地は「紐付かなかった着地」として別枠に出す — 消すのではなく、
紐付かなかったという事実を残す。

## 残骸（git のみ）

その日の各 entry の `.gitBranch` を集め、4 段でフィルタする。

1. その日 transcript に現れたブランチであること
2. `main` と既定ブランチ（`origin/HEAD`）を除く
3. `origin/main` に未統合（`git rev-list --count origin/main..<branch>` > 0）
4. tip commit の author が自分（上の数値 ID パターン）

4 が要るのは、他人が動かしている長命な共有ブランチを落とすため。実測で
`develop ahead=442` の tip author が別メンバーだった。**この 1 件だけが落ち、他は全部残る** —
フィルタが効きすぎていないことの対照になっている。

3 の base（`origin/HEAD`、無ければ `origin/main`）がどちらも解決できない repo — origin が
無い、あるいは `origin/HEAD` 未設定で既定ブランチが `main` でもない — では、ブランチを測る
相手が無い。この場合は着地を証明できないとみなして OPEN（`base=unknown`）に倒す。
LANDED は「片付け」欄すなわち `git-reap-gone` の対象を意味するが、`git-reap-gone` 自身も
base に `origin/HEAD` を要求するので、base の無い repo で
出した片付け助言はそもそも実行できない。着地側の集計も同じ repo を対象外にしており、両者の
扱いが揃う。

なお 4 は `git log -1 -F --author=<pat> <branch>` では書けない。`-1` はフィルタ後の出力を
1 件に切るので、この形は「この履歴の中で自分が書いた一番新しい commit」を返し、他人のブランチ
でも共有の root commit を拾ってしまう。tip の author を `%an <%ae>` で取り出して固定文字列で
突き合わせる。

分類（実測: 2026-09-08 は 18 ブランチ）:

```
DONE   5 件  ブランチ自体が消滅（reap 済み）→ 日報には出さない（やることが無い）
LANDED 7 件  ahead=0 → git-reap-gone の対象として「片付け」に列挙する
OPEN   6 件  origin/main に未統合 → session の「残り」として出す
```

### 「落ちたままのテスト」は独立したシグナルとして追わない

`is_error` はテスト失敗を捕まえない。実測（2026-09-08）でテスト系コマンド 43 件のうち
`is_error` が立ったのは 0 件。対照として同日の tool_result 全体では 32 件立っているので、
フィルタが空振りしているのではなく、テストランナーの非 0 終了が `is_error` にならないだけである
（実装後の再測定でも、より狭い正規表現でテスト系 8 件・エラー 0 件、全体 1446 件中 24 件と
同じ形だった）。

失敗は本文テキストには現れるが、書式がツールごとに違い、かつ「1 回落ちた」と「落ちたまま
終わった」を機械的に区別できない。したがってこれは決定論的なシグナルにせず、OPEN ブランチが
**なぜ OPEN なのか**の理由として段1 の LLM に書かせる。

## 到達手段

`claude agents --json` の roster（`sessionId` で join できる）と cwd の実在で 3 分類する。

| 分類 | 条件 | 日報に書く到達手段 |
|---|---|---|
| LIVE | roster に `sessionId` がある | claude-queue picker（`C-q q`） |
| RESUMABLE | roster に無いが cwd が実在 | `claude --resume <uuid>` |
| CWD_GONE | cwd が消滅 | 到達不可。記録のみ |

実測（2026-09-08 の cli 30 session）: LIVE 10 / RESUMABLE 17 / CWD_GONE 3。

**resume コマンドは transcript の実在を確認してから書く。** `claude --resume <存在しない uuid>`
はエラーにならず、**その id で空の新規 session を立ててしまう**。日報は transcript を読んで
uuid を得ているので実在は構造的に保証されるが、この性質のせいで「間違った resume 行」は
静かに壊れる（起動して、しかし何も残っていない）ため、経路として明示しておく。
`claude attach` は background 専用で、interactive に投げると `No job matching` で落ちる
（`worktree-scope.md` §6 / §8）。

ラベルは `ai-title` entry（`{"type":"ai-title","aiTitle":"..."}`）の最後の値。実測で 30 session
中 28 で取れる。取れないものは最初の人間プロンプトの先頭 60 文字で代用する。

## 出力の構造と優先度

session をキーにした 1 本のリスト。優先度順に並べ、「残り」が無い session は末尾へ沈める。

```markdown
# 2026-09-08

## 確認すべき session（優先度順）

### f13a218f  mukoyama_kuki ncs-gateway RTSP停止        [LIVE]
着地  eversteel-backend-api #6885 fix(ncs-gateway): 上流カメラからの RTCP BYE を検知して… (commit 5)
      eversteel-backend-api #6844 ci(ncs-gateway): bare 名 ECR に multi-arch イメージを push… (13)
残り  eversteel-backend-api agent/fix/ncs-gateway-rtcp-bye-adr-playbook が ahead=4 で未統合
      委譲先が「ADR は follow-up に分離」と報告、未着手

### f2a48cfd  remote assessment access control          [RESUMABLE]
着地  なし
残り  eversteel-backend-api agent/feature/hide-remote-assessment が ahead=7 で未統合
→ claude --resume f2a48cfd-…  (cwd: …/.worktrees/hide-remote-assessment)

## 紐付かなかった着地
## 片付け（git-reap-gone 対象）
## 到達不可（記録のみ）
```

優先度の材料は 4 つ。**上 2 つは決定論的に取り、LLM に判断させない。**

| 材料 | 加点 | 誰が決めるか |
|---|---|---|
| roster の `state` が `blocked`（承認待ちで凍結） | +4 | スクリプト |
| OPEN ブランチを残している | +2 | スクリプト |
| session が質問で終わっている | +1 | 段1 の LLM |
| 委譲先が未完了・不足を報告した | +1 | 段1 の LLM |

上 2 つを LLM に渡さないのは、**存在しないブランチ名を書かれるくらいなら triage が無いほうが
まし**だから。段1 の LLM は `ends_with_question` / `delegate_incomplete` の 2 つの真偽値だけを
返し、スクリプトがそれを読んで並べる。段2 の LLM は事実ブロックの表記をそのまま使うよう
指示され、並び順を入れ替えないよう明示される。

## claude-queue に寄せなかった理由

`src/claude-queue/` は同じ session を追跡しており、日報の材料になりそうに見える。しかし
**履歴の権威にはならない**。DB（`~/.claude/session-queue.db`）には現時点で 37 session・
2026-08-28 以降しか無い（設計時の測定では 192 session・2026-06-17 以降だった）。`reset` で
消えるので、測定の 2 週間後に見たら中身が入れ替わっている、というのがまさに観測された。

一方 transcript は追記専用で消えない。だから履歴の出所は transcript に一本化し、
claude-queue は使わない。roster（`claude agents --json`）だけは「今生きているか」という
現在時刻の情報なので、そちらから取る。

## スケジュール — 「前夜に生成」と「5 時境界」は両立しない

日の境界を 05:00 JST に置いた以上、その日が閉じるのは翌朝 05:00 である。前夜（たとえば 23:00）に
生成すると、境界の定義上まだ 6 時間ぶん残っている日を締めることになる。深夜作業を前日側へ
落とすために境界を 5 時にしたのだから、その作業ぶんを取りこぼしては本末転倒である。

したがって生成は朝側に置く。`OnCalendar=*-*-* 05:10:00` — 境界の直後だが 10 分の余裕を
持たせ、04:00 台の作業が書き終わるのを待つ。

`Persistent=true` を付けるので、マシンが止まっていて逃した回は次回起動時に backfill される。
冪等設計（中間サマリの再利用、任意の過去日を再構成できること）がそのまま効く。

`loginctl enable-linger "$USER"` が要る（ログアウト中も user manager を走らせるため）。
`bin/deploy.sh` はこれを実行しない — 有効化は人間の操作として残す。

```
loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable --now claude-digest.timer
```

### unit の配置 — `dot/systemd-user/` を `MergeLinkMap` で展開する

unit は `dot/systemd-user/` に平置きし、`bin/deploy.sh` が

```bash
MergeLinkMap["systemd-user"]="${HOME}/.config/systemd/user"
```

で `~/.config/systemd/user/` へ 1 ファイルずつ link する。`MergeLinkMap` は配下の各ファイルを
個別に link し、リンク先を `mkdir -p` してから使うので、systemd 自身がそこに置く状態
ディレクトリ（`*.target.wants` 等）と共存できる。

ディレクトリ丸ごとを link する `CustomLocationMap` はここでは使えない。`~/.config/systemd` も
その下の `user/` も既に実ディレクトリとして存在するため、`ln -snvf <src> <既存ディレクトリ>` は
エラーにならずその中へ symlink を作る（`dot/claude/rules/dotrc-deploy.md` §4 と同じ罠）。
`~/.config/systemd/systemd -> <repo>/dot/systemd` ができるだけで、unit はどこにも現れない。

`dot/systemd-user` は新しいトップレベルエントリなので、展開には `bin/deploy.sh` の再実行が
要る（`dotrc-deploy.md` §4）。

### unit の PATH

systemd user unit は shell の PATH を継承しない。`~/.bashrc` は非対話 shell で早期 return
するため、dotrc が追記する bin ディレクトリはそこには載らない。よって unit 側で
`Environment=PATH=...` を明示する。実測で `bash -lc 'command -v claude-digest'` は空を返し、
`claude` / `jq` だけが見つかる（後者は `~/.profile` 経由）。

## 朝の読み方

```tmux
bind-key e display-popup -E -w 80% -h 80% "claude-digest"
```

prefix は `C-q`。`q` / `Q` は claude-queue picker、`d` は tmux 既定の `detach-client` に
割り当て済みなので `e` を使う。

**シェル起動時の自動表示はしない。** pane を開くたびに流れるため。日報は「読みに行くもの」で
あって「流れてくるもの」ではない。

## テスト

`test/claude-digest.test.sh`。フレームワーク非依存、`bash` で直接実行。fixture（transcript・
git リポジトリ・`claude` の stub）はすべてテスト内で `mktemp -d` に生成するので、合成データは
repo に残らない。実データも参照しない。

収集側の判定は `--generate --dry-run` の出力に対して書く。段2 に渡る事実ブロックそのものなので、
LLM を呼ばずに収集ロジック全体を観測できる。生成側（段1 / 段2 / 冪等性）は `-p` の呼び出しを
記録する stub で確かめる。

### 判別力の確認

`evidence-over-guesswork.md` §4 に従い、新しいコード側を 1 箇所ずつ変異させて、テストが
それを捕まえることを確認した（新規スクリプトの導入なので、修正前コードに当てても
command not found になるだけで判別にならない）。

| 変異 | 落ちたテスト |
|---|---|
| 日境界のシフト `+14400` → `+0` | JST 05:30 (20:30Z) starts the new day |
| 小数秒の `sub()` を外す | 17 件（transcript が全滅する） |
| `entrypoint` フィルタを外す | sdk-py sessions are excluded |
| uuid の重複排除を外す | one session uuid under two project directories is counted once |
| `git log --author` から `-F` を外す | -F keeps a regex-only author collision out of the landed list |
| ブランチ tip の author フィルタを外す | a branch whose tip is somebody else's is dropped |
| `author_pattern` から数値 ID 導出を外す | a noreply address yields the numeric-id author pattern |
| `blocked` の +4 を外す | a blocked session sorts to the top |
| 着地 ∩ 言及の交差をやめる | a landed PR nobody mentioned goes to the unlinked list, named with its repo |
| 段1 の中間サマリ再利用をやめる | re-running a day reuses the intermediates and only redoes the reduce || 素材ゼロ session の除外を外す | a session with no summarisable material is dropped from the facts block（対照の「…while a session of the same day that has material is still listed」と「a session with only assistant text, and no human prompt, is kept」は通り続ける） |

`-F` の判別には BRE 前提の fixture が要る。手元の git は `grep.patternType` 未設定で
`--author` が BRE 既定になるため、`+` はリテラルであり、ERE 前提の偽 author
（`650047033@example.com`）では `-F` の有無で結果が変わらない。BRE でも `.` はメタ文字なので、
`plain@example.com` にマッチしてしまう `plain@exampleXcom` を置いて初めて差が出る。

---

由来: 「今日なにをしたか」を人間が session 一覧から毎朝手で組み立てていたこと。設計は委譲元で
実データを測りながら確定し（本文中の実測値はその測定と、実装後の再測定）、実装を別 worktree へ
委譲した。
