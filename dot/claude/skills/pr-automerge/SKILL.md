---
name: pr-automerge
description: pr-review-loop が収束した PR を、merge してよいと判断したときに使う。merge を見送る理由（grant 変更を含む PR 等）があるときは使わない。review を経ていない PR には使わない（先に pr-review-loop）。
allowed-tools: Read, Grep, Glob
---

# pr-automerge

`pr-review-loop` が収束させた PR について、CI に fail が無いこと・PR 本文が HEAD と整合している
ことを確かめ、auto-merge を有効化する。review はしない（review は `pr-review-loop` の担当）。

## 入力

`$ARGUMENTS` に PR 番号と、`pr-review-loop` が収束時に出した `head_sha` / `last_seen` が入る
（例: `/pr-automerge 42 head_sha=<sha> last_seen=<timestamp>`）。以降 `<PR>` / `<HEAD_SHA>` /
`<LAST_SEEN>` と表記する。同じ session で `pr-review-loop` から続けて呼ぶときは、その収束
メッセージの `収束: head_sha=... last_seen=...` 行から読んでよい。

## 不変条件（厳守）

- **この skill の終端状態は「auto-merge を有効化したこと（clean な PR では `gh-automerge` の fallback による直接 merge）」であって「PR が merge されたこと」ではない。** 実際に merge されるかは repo の branch protection（required checks / required approvals）が決める。**merge されていないことを異常とみなして調査してはならない。** 裏返しに、**既に merge が成立している状態も等しく正常な終端**である（required check の無い repo では `--auto` がその場で merge を成立させ、clean 拒否のときは手順 2 の fallback が直接 merge する）。終端は「有効化されて待っている」か「もう merge された」かのどちらかで、後者も異常とみなさない（手順 3）。
- **review を経ていない HEAD を merge しない。** 手順 0 のゲートを通らなければ、それ以降の手順へ進まない。
- auto-merge の有効化は **`gh-automerge <PR>`** ラッパーのみ（内部で `gh pr merge --auto --merge`）。同じラッパーの `--disable` 形（無効化）はこの skill では使わない（既存 PR へ修正を積む間の一時停止として `implement-and-review` が使う）。`mergeStateStatus` が `CLEAN` な PR は GitHub が auto-merge の有効化自体を拒否する（待つものが無いため）ので、そのときだけラッパーが `gh pr merge --merge` へ fallback する — branch protection は fallback 後も GitHub 側でそのまま効く。事前に CI に **fail が無いこと**を **`gh-pr-checks <PR>`** ラッパーで確認する（pending は可 — auto-merge が待つ）。raw `gh pr merge` は使わない。`gh pr checks` も使わない（fine-grained PAT では check runs を読む権限が存在せず必ず失敗する）。
- 結果は **PR に投稿しない**。**session の最終メッセージとして出力するだけ**にする。raw `gh pr comment` は使わない。

## 手順

0. **review 済みかのゲート**: 次のいずれかに当たったら merge せず手順 5（停止・報告）へ抜け、
   停止理由を「review を経ていない。先に `pr-review-loop` を回す」と書く。
   - `<HEAD_SHA>` が渡されていない
   - `gh pr view <PR> --json headRefOid --jq .headRefOid` が `<HEAD_SHA>` と一致しない
     （収束後に commit が積まれた）
   - `last_seen=` キー自体が渡されていない（未受領）
   - `gh-await-reviews <PR>` が返す `last_activity_at` が `<LAST_SEEN>` より新しい（収束後に
     review が届いた）。`last_seen=null` は収束時点で HEAD 宛の activity が無かったことを示す
     正当な値で、現在の `last_activity_at` も null なら一致とみなしてゲートを通す。現在の値が
     非 null なら収束後に review が届いたものとして止める

   review を経ない merge を手順側で塞ぐためのゲートである。呼び出し側が `pr-review-loop` を
   飛ばしても、ここで止まる。
1. **CI 確認**: `gh-pr-checks <PR>` を実行する（raw `gh pr checks` は使わない。fine-grained PAT では
   必ず失敗する）。返る JSON の **`has_failure` が `true` なら auto-merge を有効化しない** → 手順 5 へ
   （`checks[]` の fail した項目を報告に使う）。**チェックの確定は待たない**（`pending_count` が
   非 0 のまま先へ進んでよい。auto-merge が待つ）。このラッパーは required かどうかを判定しない
   ので、required check の充足判定は auto-merge（branch protection）に委ねる。
   **fail の内訳が cancelled のみのときは、そう切り分けて報告する。** `checks[]` は `source`
   によって fail の効き方が違う（`bin/gh-pr-checks` の `is_failure` 参照。このラッパー自体は
   編集しない）。
   - `source == "actions"`: `conclusion` が `cancelled` かつ `superseded` が `false`（(2)）、
     または `conclusion` が `failure` / `timed_out` / `startup_failure`（(1) 実質的な
     failure。`error` は Actions run の conclusion には現れないので対象外）。
   - `source == "status"`: `conclusion` が `failure` / `error`（(1) 実質的な failure。
     commit status に cancelled の概念は無い）。
   (1) が 0 件で (2) だけなら実質的な failure は無く、GitHub 側の一過性事象の可能性が高い
   （実測: paths-filter ジョブの全ステップが success なのに job conclusion だけ cancelled になり、
   `contains(needs.*.result, 'cancelled')` を見る result ジョブが exit 1 した。再実行 1 回で
   success）。
   **ただしこの skill は再実行を自分では撃たない。** 許可されたラッパー（`gh-await-reviews` /
   `gh-pr-checks` / `gh-pr-edit-body` / `gh-automerge`）に
   run の再実行に当たるものが無く、raw な `gh run rerun` は allowlist に無いので撃てば承認
   プロンプトで止まる。この skill は人間不在の委譲先で走ることがあり、そこでは誰も承認できず
   凍結する。したがって cancelled のみでも auto-merge は有効化せず手順 5 へ抜けるが、報告は
   `pending_count` で 2 通りに切り分ける（判定材料は `checks[]` の `name` / `workflow_id` /
   `run_number` と `status` / `pending_count`）。`bin/gh-pr-checks` の `newest_completed` は
   *completed* な run しか見ないため、`concurrency: cancel-in-progress` で置換 run が
   in_progress の間は cancelled 側の `superseded` が `false` のまま残り、必要なのは再実行では
   なく置換 run の完了待ちになる。
   - `pending_count` が非 0 で同一 workflow により新しい pending run があるなら、
     **「置換 run の完了待ち、再実行は不要」**と明記する。
   - `pending_count` が 0（置換 run が無い）なら、現行どおり**「実質的な failure は 0 件、
     内訳は cancelled のみ」「再実行 1 回で解消する見込み」**と明記し、人間が再実行 1 回で
     復帰できる形にする。
   再実行の手段を将来足す場合も **上限 1 回**に切る。無制限に撃ち直すと、本当に落ちている check を
   「いつか通る」まで再実行して押し通す方向へ倒れる。1 回で直らないなら一過性ではないので、
   そこで人間へ返すのが正しい。
2. **auto-merge 有効化**: `has_failure` が `false` なら `gh-automerge <PR>` を実行する（内部で `gh pr merge --auto --merge`。
   clean 拒否のときだけ `gh pr merge --merge` へ fallback する）。
   **撃つ前に、PR 本文が現在の HEAD と整合しているかを確かめる。** 本文は PR 作成時点の状態を
   記述しており、`pr-review-loop` の修正役は diff だけを直して本文には触れない。修正 commit が入っていなくても、
   base 側の PR が merge される等で本文の前提は動く。`gh-automerge` は即時 merge が成立しうる
   （手順 3 の 2 経路）ので、ここが本文を直せる最後の地点であり、通り過ぎると古い記述がそのまま
   正典になる。`gh pr view <PR> --json body,baseRefName` と `gh pr diff <PR>` を突き合わせ、
   次を確かめる。
   - 実測値（削減量・ベンチ結果・カバレッジ等）: 現在の HEAD で測り直した値と一致するか
   - 構造・命名への言及（節見出し名・シンボル名・ファイル名）: レビュー対応で改称・削除した
     ものを旧名のまま指していないか
   - base やブランチ運用への言及: 現在の base と、参照している PR の状態（merge 済みか）に
     合っているか
   - 設計判断の説明: レビューで判断が変わったなら、変わった後の判断を述べているか

   食い違いがあれば、`gh pr view <PR> --json body --jq .body` で現本文をファイルへ書き出し、
   該当箇所だけを直して `gh-pr-edit-body <PR> <body-file>` で置き換える（追記のモードは無い）。
   raw `gh pr edit` は使わない（未許可で、撃てば人間不在の session は承認プロンプトで凍結
   する）。直した箇所は 手順 4 の最終サマリに載せる。
3. **終端判定**: 次を実行し、**終端種別を機械的に判定できる文字列**（`MERGED` / `AUTO_MERGE_PENDING` /
   `NOT_TERMINAL`）を得る（散文での判定ではなく、コマンド自体が判定値を返す形にする）。

   ```
   gh pr view <PR> --json autoMergeRequest,state --jq 'if .state == "MERGED" then "MERGED" elif .autoMergeRequest != null then "AUTO_MERGE_PENDING" else "NOT_TERMINAL" end'
   ```

   `MERGED`（その場で merge が成立した）または `AUTO_MERGE_PENDING`（auto-merge が有効化されて
   required check を待っている）なら終端に達している（手順 4 はこの値で書き分ける）。
   `NOT_TERMINAL` なら auto-merge が有効化できていないので、手順 5（停止・報告）へ抜ける。
   3 分岐にするのは、`MERGED` に達する経路が 2 つあり（required check の無い repo で `--auto` が
   即時 merge を成立させた場合と、手順 2 の fallback が直接 merge した場合）、どちらも成立した時点で
   `autoMergeRequest` が null に戻るため。`autoMergeRequest` の非 null だけを終端条件にすると、
   **最も順当に終わった happy path を失敗と判定してしまう**。実測（review→merge のループ自身が
   merge した PR）:

   ```
   $ gh pr view 70 --json autoMergeRequest,state,mergedAt
   {"autoMergeRequest":null,"mergedAt":"2026-09-03T07:57:46Z","state":"MERGED"}
   ```

   `state` を引くのは終端判定のためで、`state` が `OPEN`（`AUTO_MERGE_PENDING`）でも異常ではない。
   merge されていないという結果を異常視しないのであって、merge 状態を観測しないのではない。
4. **最終サマリ出力**: 手順 0 で照合した `head_sha`、手順 1 の CI 状態、手順 2 で PR 本文を直したならその箇所、
   最終結果を **session の最終メッセージとして出力**する。PR には投稿しない。最終結果は手順 3 の**終端種別**で書き分ける —
   **auto-merge を有効化して待機中**（`AUTO_MERGE_PENDING`）か、**その場で merge が成立した**
   （`MERGED`。`--auto` の即時成立でも手順 2 の fallback でも同じ値になる）か。「有効化済み」と
   決め打ちで書くと、後者に達した場合に報告文が実際の結果を表せない。
5. **停止・報告**（auto-merge を有効化しなかった場合）: 停止理由（手順 0 のゲート、手順 1 の CI の
   fail とその cancelled のみ切り分け、手順 3 の `NOT_TERMINAL`）と残課題を箇条書きで要約し、
   **session の最終メッセージとして出力**する。PR は開いたまま、PR への投稿はしない（人間が引き取る）。
