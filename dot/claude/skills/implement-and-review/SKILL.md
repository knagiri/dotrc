---
name: implement-and-review
description: worktree に委譲されたタスクを実装→merge で完遂する。HOW は委譲元で確定済みなので brainstorm せず、必要に応じて難度別の実装 subagent へ dispatch しつつ実装し、verification を経て pr-review-automerge で自律 merge する。最後に（委譲プロンプトが内省スキップを明示しない限り）harness-from-retrospective で自己内省し、恒久ハーネスの候補を方針として提示する。delegate-to-worktree から渡されたプロンプト先頭の明示命令で起動される。
---

# implement-and-review

別 workspace（background agent, permission mode auto）に委譲されたタスクを、
実装 → verification → merge まで完遂する。`delegate-to-worktree` が渡した
プロンプト先頭の明示命令でこの skill に入る。

作業スコープは起動された worktree ディレクトリ内に閉じる
（`dot/claude/rules/worktree-scope.md` §2 参照）。

## 入力

プロンプトの `## やること（WHAT）` に目的・背景・制約・期待成果物が、`## 設計（HOW）` に
確定済みの設計が自己完結で渡される（非自明なタスクでは HOW は `--seed` された spec /
実装計画への相対パス参照になる）。会話履歴は無い。このプロンプトと seed 済みファイルが
唯一の出所。**HOW は委譲元で確定済み**であり、ここで設計をやり直す役ではない。

## 手順

1. **設計は確定済み**: 渡された HOW（本文 or seed 済み spec / 実装計画）を読み、そのまま
   実行に入る。**brainstorm はしない。** 仕様に本質的な欠落・矛盾があり、どう解釈しても
   進めないときに限り、プロンプト末尾の `## 委譲元` が示す name 宛に SendMessage で質問を送り、
   そのまま待機する（この session は background なので、返信で起きて続きを実行する）。
   `## 委譲元` が無いのは委譲元 claude を解決できなかったとき（人間が素の shell から
   `claude-worktree` を叩いた等）。この場合でも tmux session の中で走っていて人間が
   `gts <session>` / `tmux attach` で入れるなら、質問を出して REPL で待機してよい。そうでなければ
   届ける相手がいないので、前提を明示して進める。
   解釈の幅が結果を大きく変えないなら、同じく前提を明示して進める。

   **参照実装を読む前に base の追随を済ませる**: 委譲プロンプトが repo 内のファイルを参照実装
   として名指ししているなら（「`X` の先行実装に合わせる」「`Y` と同じ形にする」等）、それを
   読む前に `git fetch origin` して base を追随させる。追随先は `bin/claude-worktree` の
   新規ブランチ base 解決と同じ ladder で決める（素の
   `git rev-parse --abbrev-ref origin/HEAD` は、`origin/HEAD` 未設定の checkout では失敗する
   か、git のバージョンによっては literal 文字列 `origin/HEAD` を返して exit 0 になるため、
   単純なコマンド置換では `origin/main` へフォールバックできない）。

   ```sh
   git fetch origin
   if b="$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null)" && [ "$b" != "origin/HEAD" ]; then
     git merge --no-edit "$b"
   elif git rev-parse --verify --quiet origin/main >/dev/null; then
     git merge --no-edit origin/main
   fi
   ```

   `--ff-only` ではなく素の merge なのは、ローカル commit の有無で分けたいことを git 自身が
   既にやっているからである。commit が無ければ fast-forward し、あればマージコミットを作る。
   同じ条件を散文とスニペットの両方に持たせると、片方だけ直したときに黙って食い違う。実際
   `--ff-only` だったときのここは「ローカル commit がまだ無ければ」という条件を散文しか持たず、
   スニペットは無条件に撃っていた。既存ブランチの worktree へ再委譲するとローカル commit が
   ある状態で始まるので、手順どおり実行した委譲先が必ず非 0 で詰まる形だった。素の merge は
   この repo が push 済みブランチの base 追随に rebase ではなく merge を使う方針とも揃う。

   `--no-edit` は、git が v1.7.10 以降 **fast-forward でない merge でエディタを開く**ため
   （`git-merge(1)` が "Older scripts ... will see an editor opened when they run git merge" と
   名指しで警告している）。TTY が無ければ開かないので委譲先の Bash tool 経由では実害が無い
   （実測で確認）が、この手順は人間が端末で実行することもあるので isatty 頼みにしない。

   conflict したらそこで止まり、解消してから先へ進む。これは手順 3 が PR を出す前にどのみち
   強制する作業を、まだ何も書いていないこの時点へ前倒ししているだけである。

   既定ブランチを `origin/main` に決め打ちしないのは、手順 3・手順 4 と同じ理由（既定
   ブランチが `master`/`trunk` の repo でも成り立たせるため）で、`bin/claude-worktree` の
   新規ブランチ base 解決（origin/HEAD → origin/main の ladder）とも揃える。

   手順 3 の base 確認とは役割が違うので、両方置く。あちらは PR を出す前の conflict 回避で、
   参照実装を読むのはその遥か前である。参照先が古ければ、気づいた時には既に書き写した後で
   手遅れになる。しかも生成物を持つ repo（生成系のドキュメント等）では、古い base で生成しても
   「再生成して差分が出ない」冪等性チェックは通ってしまうので、検証の側でも捕まらない
   — その生成物は他 PR の変更を巻き戻す。

   `bin/claude-worktree` は新規ブランチの base を origin/HEAD にするので、委譲がその経路で
   起きたならここは追随済みのはずである。この二重化が拾うのは、委譲元が既存ブランチの再利用を
   指定した場合（base の付け替えが起きないので古いままになり得る）。
2. **実装**: 実装計画があれば `superpowers:executing-plans` に従い、タスク単位で進める。
   実装作業を subagent へ dispatch するときは、難度に応じて agent を選ぶ（モデルは各 agent
   定義の `model:` frontmatter で固定されている）。
   - `impl-light` — 機械的・低リスク（定型編集、リネーム、単純な追記）
   - `impl-standard` — 既定。一定のロジック・複数ファイルにまたがる変更
   - `impl-heavy` — 最難。複雑ロジック・非自明な設計判断を含む変更

   `superpowers:test-driven-development` 等、repo の規約に従う。コミットは論理単位で小さく。

   **plan 内の事実主張は書き写す前に裏を取る**: どの artifact を選ぶか・どこに置くか等の
   設計判断には従う。一方 plan 本文が repo 内の実装・ツール挙動に言及していたら（「`bin/X`
   はこう動く」「既存 skill Y はこう書いてある」等）、書き写す前に該当ファイルを Read して
   確かめる。事実の誤りを黙って commit するほうが、確認してから書くより後戻りが大きいため。
   設計をやり直すのとは別物なので、不変条件「HOW を勝手に作り直さない」と矛盾しない。
   常時ロードの `dot/claude/rules/evidence-over-guesswork.md` §1（一次情報を確認しきる前に
   着手しない）と同根で、plan 経由でそれが迂回されるのを塞ぐ位置づけ。
   由来: plan に埋め込まれた SKILL.md 全文の「headless 起動では claude-review が出力を
   ログ化する」を無検証で書き写し、レビューで差し戻された実例（実際の `bin/claude-review` は
   自身が起こす headless pane の stdout を tee するだけで、委譲先の interactive セッションから
   呼ばれた skill の出力は載らない）。

   **外部ツールの予約文字・エスケープ・quoting も同じ扱いにする**: 裏取りの対象は repo 内の
   実装に限らない。plan が外部ツールへ渡す文字列の仕様に踏み込んでいたら（「この文字を
   置換すればよい」「この形で quote する」等）、そのツールの一次情報（man / 公式リファレンス）を
   引いてから書く。

   ただし**範囲は限定する**。「外部ツールの挙動全般」まで広げると毎回 man を引くことになり、
   コストが釣り合わない。絞る先は**間違えると黙って壊れるクラス** — エラーにならず、別のものと
   して解釈されて通ってしまうものである。具体的には予約文字・エスケープ・quoting 規則・format
   展開がこれに当たる。存在しない flag を渡すような誤りは即座にエラーで返ってくるので、この
   裏取りの対象ではない（実行すれば分かる）。黙って別解釈されるものだけが、テストも gate も
   すり抜けて後から発覚するため、書く前の確認に見合う。

   由来: PR #67 のレビューで発覚した tmux window 名の実バグ。委譲プロンプトが置換対象として
   挙げていた `.` `:` `~` をそのまま書き写し、tmux の FORMATS を一次情報で確認しなかった。
   実際には `#` も予約されていて、`rename-window` / `new-window -n` に渡した名前は format 展開
   される。結果 `#S` `#T` `#D` `#W` が session / pane / window に置換され、閉じない `#{` は
   以降を丸ごと飲み込む。表示崩れに留まらず、`new-window -S` の dedupe が名前の不一致で破れ、
   automatic-rename が永久に off になった。どれもエラーは出ず、名前が「通って」しまうのが
   このクラスの怖さである。

   **委譲の上限**: Opus 5 は放っておくと過剰に委譲する（促進する指示が要ったのは 4.8 までで、
   5 では逆に上限が要る。出典: Anthropic 公式 Prompting Claude Opus 5「Controlling subagent
   spawning」節 <https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5#controlling-subagent-spawning>）。
   委譲には毎回コンテキスト再構築・報告作成・報告の読み直しのコストが乗るので、次を目安に
   上限を置く。

   - 数回の tool call で自分が終えられる仕事は dispatch せず自分で書く（ハイブリッド）。
     上記のコストが仕事本体を上回るため。
   - **検証・ダブルチェック目的では dispatch しない。** verification は手順 3 で自分のループ内に
     置き、独立文脈でのレビューは手順 4 のパイプラインが担う。この 2 つで足りている。
   - 1 つのタスクを細切れにして並列 dispatch しない。分割と統合のコストが本体を上回るため。
     並列は独立した大きめのトラック（無関係なモジュール、広い多ファイル調査）に使う。1 つで
     済むなら 1 つにする。
   - 一度委譲したら委譲を通す。返ってきた結果をやり直したり、同じ調査を自分で再導出したり
     しない。委譲コストを二重払いするため。
3. **verification**: PR を出す前に、テスト・ビルド・lint が通ることだけを確認する
   （`superpowers:verification-before-completion`）。**重い self-review はしない** —
   レビュー本体は独立した文脈を持つ次の手順に委ねる。自分が書いたコードを同じ文脈で
   レビューしても、実装時の思い込みごと追認するだけになるため。

   **base の進行も確認する**: テストが通ることは、走行中に base 側が進んでいないことを
   意味しない。PR を出す前に base の現在地を見る。

   ```
   git fetch origin
   git log --oneline HEAD..origin/<base>      # base がどれだけ進んだか
   git diff --name-only HEAD...origin/<base>  # base 側で変わったファイル
   ```

   自分が触ったファイルが base 側でも変更されていれば、PR を出す前に取り込む（merge
   / rebase）。base が進んでいなければ追加コストはこの 2〜3 コマンドだけで済むので、
   毎回確認して構わない。

   複数の委譲が並行して merge される運用では、base が走行中に進むのは例外ではなく常態。
   conflict したまま PR を出すと GitHub 側は `mergeStateStatus: DIRTY` になり、手順 4 の
   レビュー段で判定役が発見 → 修正役が直す、で 1 イテレーションをまるごと消費する。
   さらに修正役は他人の変更を conflict 解決越しに扱うことになり、内容欠落のリスクが乗る。
   自分の文脈が生きているここで取り込むほうが安く確実。
   由来: knagiri/dotrc#26（Opus 5 の委譲上限を追記した PR）で、実装中に base が 40 コミット
   以上進み、そのうち 1 つが自分と同一ファイルの同一段落を変更していたのに気づかず conflict
   したまま PR を出し、レビュー段の判定役が発見して 1 イテレーションを消費した実例。
4. **review→merge**: PR は既定では `my-create-pr` skill で作り、生の `gh pr create` は直接
   叩かない。base の決定（`gh repo view` で既定ブランチを取得し、ブランチ名を決め打ちに
   しない）・diff の基準（ローカル追跡ブランチでなく remote ref を 3 点表記で使う）・
   `--base` の常時明示といった非自明な作法が `my-create-pr` 側に集約されており、生の
   `gh pr create` はそれを丸ごと迂回するため。由来: 上と同じ委譲ランで、repo に
   `my-create-pr` があり settings.json で allow までされているのに素通りし、生の
   `gh pr create` を使っていた。

   **ただし実行先 repo が PR 作成のレーンを定めているなら、そちらが優先される。** repo の
   doc（`docs/pr-creation-lanes.md` 等）や CLAUDE.md がブランチ名で PR 作成の経路を分けて
   いれば、その規約に従う。レーンを混ぜると同一 head に対して open PR が重複し、片方が
   失敗してブランチに赤バツが付くため。実例: eversteel のモノレポは `agent/**` で始まる
   ブランチへ push すると GitHub App 名義で PR を作る仕組みが起動し、同 repo の
   `docs/pr-creation-lanes.md` が「es-create-pr はこのレーンを扱わない」と明記している。
   この skill の指示だけを見て `my-create-pr` / `es-create-pr` を撃つと衝突するので、PR を
   出す前に実行先 repo の規約を確認する。由来: 2 つの委譲先がこれに遭遇した。片方は自力で
   repo doc を読んで回避し、もう片方は委譲元がプロンプトで明示したので回避できた
   — どちらも skill の指示を上書きする何かがあったから助かっただけで、skill 自身は
   無条件の指示のままだった。

   PR を出したら `pr-review-automerge` を呼び、author とは独立した立場での
   レビュー・required CI 確認を経て自律 merge する。
5. **自己内省（末尾ハーネス）**: `pr-review-automerge` から戻ったら（auto-merge 有効化に至らず
   5 イテレーション未収束や CI fail で停止・報告して終わった場合も含む）、委譲プロンプトに
   自己内省をスキップする明示（例: 「harness-from-retrospective はスキップ」）が**無い限り**、
   `harness-from-retrospective` を呼ぶ。自分の作業を振り返り、恒久ハーネスに値する改善点を
   方針として提示する（**提案のみ・無ければ no-op**）。承認・実装はしない — 人間が承認した
   項目だけ後で `harness-from-feedback` が実装する。
6. **委譲元への報告**: プロンプト末尾に `## 委譲元` 節（`報告先 name: <name>`）があるときは、
   次の 3 つの事象で SendMessage を送る。**送信に失敗しても無視して自分の終了処理を続ける**
   （委譲元の session が既に消えていることがある）。

   - **完了**: PR URL と auto-merge を有効化できたかを 1〜3 行で。手順 5 の自己内省に提案が
     あればその要点も添える（既定の background 委譲先は人間不在で走り、最終メッセージは
     誰にも読まれないまま委譲元に閉じられるため、この報告が唯一の到達経路）。
   - **不足**: 手順 1 のとおり。質問を送って待機する。
   - **中断**: `pr-review-automerge` が 5 イテレーション未収束・CI fail で停止したとき、その理由。

   **permission 承認はこの経路に乗らない。** 承認が要る tool call はブロックしたまま待てばよく、
   人間が `claude attach` で入って承認する。委譲元に承認を代行させようとしない
   （cross-session permission laundering）。

## 不変条件

- WHAT を勝手に広げない。委譲されたタスクの範囲で完遂する。
- HOW を勝手に作り直さない。確定済みの設計に従う。
- worktree ディレクトリ外への書き込みはしない（read-only 参照は可）。
- 末尾の自己内省は**提案まで**。承認・実装・grant 記述はしない（実装は人間承認後の harness-from-feedback）。
- 承認の代行を委譲元に求めない。ブロックしたまま待つのが正しい振る舞い。
