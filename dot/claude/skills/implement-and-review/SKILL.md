---
name: implement-and-review
description: worktree に委譲されたタスクを実装→merge で完遂する。HOW は委譲元で確定済みなので brainstorm せず、必要に応じて難度別の実装 subagent へ dispatch しつつ実装し、verification を経て pr-review-automerge で自律 merge する。最後に（委譲プロンプトが内省スキップを明示しない限り）harness-from-retrospective で自己内省し、恒久ハーネスの候補を方針として提示する。delegate-to-worktree から渡されたプロンプト先頭の明示命令で起動される。
---

# implement-and-review

別 workspace（detached tmux session, acceptEdits）に委譲されたタスクを、
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
   進めないときに限り、質問を出して REPL で待機する（この session は detached なので
   ユーザーが `gts <session>` / `tmux attach -t <session>` で attach して答える）。
   解釈の幅が結果を大きく変えないなら、前提を明示して進める。
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
4. **review→merge**: **PR は `my-create-pr` skill で作る**（生の `gh pr create` を直接叩かない）。
   base の決定（`gh repo view` で既定ブランチを取得し、ブランチ名を決め打ちにしない）・
   diff の基準（ローカル追跡ブランチでなく remote ref を 3 点表記で使う）・`--base` の常時明示
   といった非自明な作法が `my-create-pr` 側に集約されており、生の `gh pr create` はそれを
   丸ごと迂回するため。由来: 上と同じ委譲ランで、repo に `my-create-pr` があり settings.json で
   allow までされているのに素通りし、生の `gh pr create` を使っていた。

   PR を出したら `pr-review-automerge` を呼び、author とは独立した立場での
   レビュー・required CI 確認を経て自律 merge する。
5. **自己内省（末尾ハーネス）**: `pr-review-automerge` から戻ったら（auto-merge 有効化に至らず
   5 イテレーション未収束や CI fail で停止・報告して終わった場合も含む）、委譲プロンプトに
   自己内省をスキップする明示（例: 「harness-from-retrospective はスキップ」）が**無い限り**、
   `harness-from-retrospective` を呼ぶ。自分の作業を振り返り、恒久ハーネスに値する改善点を
   方針として提示する（**提案のみ・無ければ no-op**）。承認・実装はしない — 人間が承認した
   項目だけ後で `harness-from-feedback` が実装する。

## 不変条件

- WHAT を勝手に広げない。委譲されたタスクの範囲で完遂する。
- HOW を勝手に作り直さない。確定済みの設計に従う。
- worktree ディレクトリ外への書き込みはしない（read-only 参照は可）。
- 末尾の自己内省は**提案まで**。承認・実装・grant 記述はしない（実装は人間承認後の harness-from-feedback）。
