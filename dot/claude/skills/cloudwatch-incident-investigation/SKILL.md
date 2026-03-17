---
name: cloudwatch-incident-investigation
description: >
  CloudWatch Alarm 発火や Sentry エラーを起点とした本番障害調査を自律的に進めるスキル。
  AWS CLI を使って CloudWatch Logs Insights クエリの実行・結果解釈・根本原因特定を行う。
  ユーザーが本番障害・アラート・Sentry エラーの調査を依頼したとき、
  または CloudWatch Logs / Metrics の調査・ログ取得が必要なときにこのスキルを使う。
  「ログ調べて」「エラー調査して」「アラーム見て」「障害調査」のような依頼にも反応すること。
allowed-tools: Bash(aws *), Bash(date *), Bash(jq *), Read, Grep, Glob
argument-hint: <alarm-name | sentry-error-url | free-text description>
---

# CloudWatch Incident Investigation

本番障害調査の専門スキル。
CloudWatch Alarm 発火または Sentry エラーを起点に、AWS CLI を直接実行しながら
根本原因の特定まで自律的に調査を進める。

このスキルは対象サービスの git プロジェクト内で呼ばれることを前提としている。
ログ調査だけでなく、ソースコードを読んでビジネスロジックを理解し、
より正確な影響範囲の評価と復旧判断を行う。

---

## 1. 設定ファイル

調査の最初に `.claude/cloudwatch-config.local.json`（プロジェクトルート）を探す。
設定があれば動的発見をスキップして即座にクエリ実行に入れる。なくても調査は進められる。

### スキーマ

```jsonc
{
  "aws": {
    "profile": "my-profile",
    "region": "ap-northeast-1"
  },
  "services": {
    "api": {
      "logGroupName": "/ecs/my-app-api-production",
      "filterIndexFields": ["requestId", "responseInfo.statusCode"]
    },
    "worker": {
      "logGroupName": "/ecs/my-app-worker-production",
      "filterIndexFields": ["requestId"]
    }
  },
  "defaultService": "api"
}
```

### 適用ルール

- **設定あり**: `aws.profile` → `--profile`、`aws.region` → `--region` に付与。ロググループ名・filterIndex を取得し、**ステップ2・3をスキップ**して即座にクエリ実行へ
- **設定なし**: ユーザーに AWS プロファイル・リージョンを確認し、動的発見（ステップ2・3）で調査を進める
- **部分的**: 設定されている項目はそのまま使い、欠落項目のみ動的に発見
- 設定ファイルは `.gitignore` に追加することをユーザーに推奨する

---

## 2. ソースコードの参照

ログ調査と並行して、対象サービスのソースコードを読んでビジネスロジックを理解する。
これにより、ログだけでは判断できない影響範囲や復旧状態をより正確に評価できる。

### いつコードを読むか

- **アラーム名やエラーの context からジョブプロセッサ・ハンドラを特定できたとき**
  - Glob や Grep でクラス名・キューワード名を検索し、該当する実装を読む
- **復旧判断が必要なとき**（→ セクション5「復旧判断」参照）
- **エラーハンドリングやリトライの挙動を理解したいとき**

### 何を読むか

- **ジョブプロセッサ / ハンドラの実装**: エラーが発生した処理の全体像を把握する
- **リトライロジック**: リトライ回数、バックオフ戦略、リトライ条件
- **セッション / バッチのライフサイクル**: 処理が一時的なセッション内で行われるのか、継続的なのか
- **アラーム定義**: IaC（Terraform 等）からアラームの閾値・条件を確認
- **外部サービス呼び出し**: どの外部サービスに依存しているか、エラー時のフォールバック

```
# エラーログの context 値でソースコードを検索する例
# context = "LayeredSnapshotCapturingJobProcessor" の場合:
```

ソースコードを読むことで「このエラーは一時的なセッション中にのみ発生するのか、恒常的に発生しうるのか」
「アラームが OK に戻っても根本原因は解消されていないのか」といった判断ができるようになる。

---

## 3. 調査の起点

ユーザーからの入力: `$ARGUMENTS`

### 起点A: CloudWatch Alarm

1. アラームの詳細を取得
   ```
   aws cloudwatch describe-alarms --alarm-names "<alarm-name>"
   ```
2. 対象メトリクスと閾値を確認
3. **アラーム履歴から実際の発火時刻を特定する**（ユーザー申告の時刻が不正確なことがある）
   ```
   aws cloudwatch describe-alarm-history \
     --alarm-name "<alarm-name>" \
     --history-item-type StateUpdate \
     --start-date "<start>" --end-date "<end>"
   ```
4. 必要に応じてメトリクスの推移を確認
   ```
   aws cloudwatch get-metric-statistics \
     --namespace <namespace> --metric-name <metric> \
     --start-time <start> --end-time <end> \
     --period 60 --statistics Average Sum Maximum \
     --dimensions <dimensions>
   ```
5. 特定した時間帯のログ調査に進む（→ セクション4）

### 起点B: Sentry エラー

1. ユーザーから提供されたエラー情報を確認
2. 以下を抽出:
   - エラーメッセージ / Exception クラス
   - 発生時刻
   - requestId、traceId（タグに含まれる場合）
   - リクエスト URL / HTTP メソッド
3. 抽出した情報をもとにログ調査に進む（→ セクション4）

---

## 4. ログ調査

### ステップ1: ロググループの特定

優先順位:
1. 設定ファイルの `services.<service>.logGroupName`
2. ユーザーの入力から特定
3. 不明な場合はユーザーに確認、または一覧から探す:
   ```
   aws logs describe-log-groups --log-group-name-prefix "<prefix>" --query 'logGroups[].logGroupName'
   ```

### ステップ2: ログ構造の動的発見（設定ファイルがない場合）

設定ファイルに `filterIndexFields` がある場合、このステップと次のステップ3はスキップしてステップ4に進む。

ログのフィールド構造はサービスごとに異なる可能性がある。
まず実際のログを数件サンプリングして構造を把握する。

```
aws logs start-query \
  --log-group-name "<log-group>" \
  --start-time $(date -d '10 minutes ago' +%s) \
  --end-time $(date +%s) \
  --query-string 'fields @timestamp, @message | sort @timestamp desc | limit 5'
```

サンプルから以下を確認する:
- JSON 構造化ログかどうか
- 利用可能なフィールド名（リクエストID、トレースID、エラーレベル等）
- エラーレベルのフィールド名と値

### ステップ3: filterIndex の確認（設定ファイルがない場合）

```
aws logs describe-field-indexes --log-group-identifiers "<log-group-arn>"
```

filterIndex が ACTIVE なフィールドは `filter` 句で高速検索できる。
それ以外のフィールドは `parse` + `filter` または `like` を使う。

### ステップ4: Logs Insights クエリの実行

CloudWatch Logs Insights クエリは非同期実行。以下のフローを守ること。

#### クエリの開始

```
aws logs start-query \
  --log-group-name "<log-group>" \
  --start-time <epoch-start> \
  --end-time <epoch-end> \
  --query-string '<query>'
```

時刻の変換: `date -d '2026-03-12T08:00:00+09:00' +%s`

#### ポーリング

`start-query` が返す `queryId` で結果を取得する。
`Complete` になるまでポーリング:

```
aws logs get-query-results --query-id "<query-id>"
```

- `Running` / `Scheduled` → 2〜3秒待って再実行
- `Complete` → 結果を解析
- 最大10回まで。超えた場合はタイムアウトとして報告

#### JSON 出力の加工

AWS CLI の出力やログの JSON パースには `jq` を使う。Python スクリプトは書かないこと。

```bash
# クエリ結果から特定フィールドを抽出
aws logs get-query-results --query-id "<id>" | jq -r '.results[] | [.[0].value, .[1].value] | @tsv'

# @message フィールドの JSON をパース
aws logs get-query-results --query-id "<id>" | jq -r '.results[] | .[] | select(.field == "@message") | .value' | jq '.requestInfo'
```

#### 初回クエリの戦略

初回クエリではエラーレベルを決め打ちしない。
ログのレベル体系はサービスごとに異なり、障害に関連するログが `error` ではなく `warn` や `info` に記録されることがある。

**良い初回クエリ**: アラームやエラーのキーワードで広く検索する
```
filter @message like /エラーに関連するキーワード/
| fields @timestamp, level, context, message, requestId
| sort @timestamp desc
| limit 30
```

**避けるべき初回クエリ**: `filter level = "error"` で始めると該当レベルのログがない場合に空振りして時間を無駄にする。

#### クエリ構文の注意点

**Logs Insights クエリ構文**を使う。filter-log-events のフィルターパターン構文 (`{ $.field = "value" }`) とは異なるので注意。

```
# フィルターパターン構文 → Logs Insights 構文への変換
{ $.field = "value" && $.other = "x" }  →  filter field = "value" and other = "x"
```

- filterIndex があるフィールドは `filter field = "value"` を使う（高速）
- ないフィールドは `filter field like /pattern/` や `parse` を使う
- ドットを含むフィールド名はバッククォートで囲む: `` `es.field_name` ``
- `stats` クエリでは集計対象イベント数に `limit` が影響しうる。正確な集計には大きい `limit` を指定する
- `bin(1d)` は UTC 基準。JST で正確な期間比較が必要な場合は期間を分けて個別にクエリを実行する

### ステップ5: 深掘り調査

初回クエリで障害の輪郭が見えたら、以下のパターンで根本原因まで掘り下げる。
各パターンは独立して実行でき、`run_in_background` で並行実行すると高速。

#### パターン1: リクエスト単位の追跡
エラーログから requestId を取得し、そのリクエストの全ログを時系列で確認する。
1つのリクエスト内で何が起きたか（リトライ、外部サービス呼び出し、例外の詳細）を把握する。
```
filter requestId = "<id>"
| fields @timestamp, level, context, message
| sort @timestamp asc
```
`context` フィールドが異なるログエントリを見ることで、リクエストがどのコンポーネントを通過したかがわかる。

#### パターン2: エラーの集約分析と影響範囲の定量化
エラーの全体像を把握する。時間帯ごとの件数だけでなく、正常処理との比率を算出して影響の深刻度を定量化する。
```
filter @message like /エラーキーワード/
| stats count(*) as cnt by bin(5m)
```
```
filter @message like /エラーキーワード/
| stats count_distinct(requestId) as affected_requests by <影響範囲のフィールド>
```

正常時との比較も行う。同じ時間帯の成功・失敗を集計してエラー率を算出すると、影響の深刻度がより明確になる。
```
filter <対象処理の条件>
| stats count(*) as total,
        sum(level = "error" or level = "warn") as errors
        by bin(5m)
```

#### パターン3: 関連コンポーネントの調査
`context` フィールド（ログを出力したクラス名やモジュール名）で関連ログを探す。
エラーログの `context` 値を手がかりに、同じコンポーネントの正常時のログと比較して異常を特定する。

#### パターン4: 分散トレーシング
traceId で複数サービス・ロググループを横断して追跡する。
外部サービス呼び出しの失敗や、サービス間の連鎖的な障害を発見できる。

---

## 5. 復旧判断

復旧判断はログ調査の結果だけでなく、ソースコードから得たビジネスロジックの理解に基づいて行う。

### アラーム OK ≠ 復旧

アラームが OK に戻っても、根本原因が解消されたとは限らない。
例えば、一時的なセッションやバッチ処理の中でのみエラーが可視化される場合、
セッション終了とともにアラームは OK に戻るが、次のセッションで同じエラーが再発する可能性がある。

### 復旧判断の手順

1. **ソースコードからエラーの発生条件を理解する**
   - エラーが発生した処理は一時的（セッション・バッチ）か継続的か
   - アラームのメトリクスはどの条件で加算されるか
2. **根本原因が解消されたかを確認する**
   - 直接原因（外部サービスのエラー、リソース枯渇等）が現在も継続しているか
   - 同じ条件の処理が成功しているログがあるか（同一エンティティ・同一操作）
3. **復旧ステータスを正確に記述する**
   - 「アラームが OK に戻った」と「根本原因が解消された」を区別する
   - 根本原因が解消されたか不明な場合は、その旨を明記する

---

## 6. 調査結果の出力

調査が完了したら、以下のフォーマットでサマリを出力する。
時刻は JST で記載する。

```markdown
## 障害調査サマリ

### 概要
- **調査起点**: (アラーム名 / Sentry エラー)
- **発生時刻**: (JST)
- **影響範囲**: (影響を受けた API・エンティティ・ユーザー数の推定)
- **現在のステータス**: (継続中 / 復旧済み / アラームは OK だが根本原因は未解消の可能性)

### 根本原因
(特定した根本原因を簡潔に記述)

### 根拠
1. (根拠1: ログやメトリクスのエビデンス)
2. (根拠2: ...)
3. (根拠3: ソースコードから得た知見がある場合)

### 時系列
| 時刻 (JST) | イベント |
|---|---|
| HH:MM:SS | ... |

### 推奨アクション
1. **即時対応**: (必要な場合)
2. **恒久対応**: (根本的な修正策)
3. **再発防止**: (監視強化・テスト追加等)
```

---

## 注意事項

- **時刻は JST で出力する**。クエリ実行時は epoch に変換して使用
- **クエリの時間範囲は狭く始める**。まず ±15分、必要に応じて広げる
- **大量のログを一度に取得しない**。`limit` を適切に設定（初回は 20〜50 件）
- **filterIndex を活用する**。確認済みの filterIndex フィールドには `filter field = "value"` を使う
- **フィールド名を仮定しない**。サンプリングまたは設定ファイルで確認した実際のフィールド名を使う
- **ソースコードを活用する**。ログだけで判断が難しい場合は、プロジェクト内の実装を読んで理解を深める
