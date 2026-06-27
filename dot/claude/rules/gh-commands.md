## gh コマンド利用ルール

GitHub CLI (`gh`) を使うときの方針。permission rule との整合性のため、コマンド形を予測可能に保つ。

### 1. 高位サブコマンド優先、`gh api` は最後の手段

`gh` には PR / Issue / Run など領域別の高位サブコマンドがある。これらで賄える操作は `gh api` を直接叩かない。

| やりたいこと | 使うべきコマンド | `gh api` を避ける理由 |
|---|---|---|
| PR の概要・本文を読む | `gh pr view <N>` | 高位コマンドの方が安全・読みやすい |
| PR のコメント一覧を読む | `gh pr view <N> --comments` | 同上 |
| PR の diff を読む | `gh pr diff <N>` | 同上 |
| PR の CI 状態を見る | `gh pr checks <N>` | 同上 |
| PR にコメントを投げる | `gh pr comment <N> -b "..."` | 後述の reply ポリシーを守りつつ簡潔 |
| PR に review を提出する | `gh pr review <N> [--approve\|--request-changes\|--comment] -b "..."` | 高位コマンドが review object を正しく扱う |
| Issue 操作 | `gh issue *` | 同上 |
| Run（GH Actions）を見る | `gh run view *` | 同上 |
| Repo 情報を見る | `gh repo view *` | 同上 |

`gh api` を使うのは、高位コマンドに該当機能が無い場合に限る（例：特定エンドポイントの未対応フィールド取得、bulk 操作など）。

### 2. `gh api` を使うときは引数順を固定

permission pattern が予測できるよう、`gh api` の引数順は以下に統一する。

```
gh api [-X METHOD] <endpoint> [-f key=val ...] [--paginate] [--jq '...']
```

- HTTP method を指定するときは `-X METHOD` を **endpoint の前** に置く（`--method` ではなく短形 `-X` を使う）
- データは `-f key=val` / `-F key=val` 形式で endpoint の **後**
- pagination・jq フィルタは末尾

これにより `Bash(gh api -X POST *)` のような単純パターンで permission rule を書ける。

### 3. PR コメントへの reply ポリシー

PR review・コメント確認を依頼されたとき、**reply コメントの投稿は明示的に指示されない限り行わない**。
デフォルトは「指摘の整理・要約・対応案の提示」までで止め、reply 投稿は別アクションとして扱う。

#### 投稿前ルール（コメント送信元別）

| コメント送信元 | reply 投稿 | 補足 |
|---|---|---|
| Bot（`@claude`, `@Copilot`, `@coderabbitai` 等） | **不要**。明示指示があっても reply の必要性をまず確認する | bot 同士の応酬を防ぐため、指摘内容の取り込み（コード修正）だけで済ませることが多い |
| チームメンバー（人間） | 必要だが、**agent が直接投稿してはいけない** | 必ずユーザーの手で文面を組み直して投稿する |

#### チームメンバー宛の reply 草案を求められた場合

ユーザーから明示的に「reply 案を出して」「返信文を考えて」と言われたときのみ、文面を**ドラフトとして提示**する。

- 提示先はチャット出力のみ。`gh pr comment` 等で直接投稿しない
- ドラフトであることを明示する（例: 「以下は reply 案です。確認のうえご自身の言葉に直して投稿してください」）
- ユーザーがそのまま投げるのではなく、ユーザーの文体で書き直す前提で短めに

#### やってよいこと

- 指摘内容の要約と分類（must-fix / nice-to-have / 質問 / 無視可など）
- 指摘に対応するコード修正の実施（PR comment への reply 投稿はせず、code change のみ）
- 「この指摘は不要だと思うがどう扱うか」の確認質問

#### やってはいけないこと

- ユーザー確認なしに `gh pr comment` 等で reply コメントを投稿する
- bot コメントに対して bot 風の反論や同意 reply を agent 名義で投げる
- ドラフト提示を「投稿しました」と誤認させる表現にする

#### スコープ外（このルールでは扱わない）

- `gh pr review`（`--approve` / `--request-changes` / `--comment`）は review **提出**であって reply コメントではない。timeline 上も別オブジェクト。本ルールでは触れないが、review 提出も通常はユーザー判断なので明示指示なしには実行しない。
- `gh pr merge` 等のマージ操作も別ルール扱い。

### 4. settings.json での担保

上記方針により、`settings.json` では以下の最小ポリシーで足りる：

- **allow:** read 系の高位コマンド（`gh pr view *`, `gh pr diff *`, `gh pr checks *`, `gh run view *`, `gh repo view *`）と PR 作成（`gh pr create *`）
- **allow しない:** `gh api *`, `gh pr comment *`, `gh pr review *`, `gh pr merge *` 等の書き込み・低レイヤ
  - allow に無いので呼び出し時に prompt が出る → ユーザー確認経由で実行可
- **deny:** 不要（hard-block は明示指示時の運用を阻害する）
- ※ `gh pr merge --auto` と `gh api graphql` は §5 の自律レビューループ例外として allow 済み（上の「allow しない」の例外）。

### 5. merge と review thread resolve（自律レビューループ用）

`pr-review-merge` skill による自律的な review→merge ループでの扱い。

- **merge は `gh pr merge --auto` 形に限り許可**する。`--auto` は required status checks が
  green になってから GitHub 側が merge する予約であり、skill 側でも事前に `gh pr checks` で
  required checks の green を確認してから打つ（二重化）。merge method は `--merge`
  （merge commit）で、logical commits を潰さない。`--auto` 以外の即時 merge 形は allow しない。
- **review thread の `resolve` は可**（`gh api graphql` の `resolveReviewThread`）。これは
  reply コメント投稿とは別物で、対応済みの指摘を次のレビューイテレーションが再浮上させない
  ための操作。高位コマンドに該当機能が無いため `gh api graphql` の使用が正当化される
  数少ないケース。
- **reply コメント投稿は従来どおり不可**（§3 のポリシーを維持）。人間の議論待ち thread は
  resolve せず残し、サマリで報告する。
