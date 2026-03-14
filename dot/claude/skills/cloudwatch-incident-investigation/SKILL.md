---
name: cloudwatch-incident-investigation
description: >
  CloudWatch Alarm 発火や Sentry エラーを起点とした本番障害調査を自律的に進めるスキル。
  AWS CLI を使って CloudWatch Logs Insights クエリの実行・結果解釈・根本原因特定を行う。
  TRIGGER when: ユーザーが本番障害・アラート・Sentry エラーの調査を依頼したとき、
  または CloudWatch Logs / Metrics について調査が必要なとき。
disable-model-invocation: true
allowed-tools: Bash(aws *), Bash(date *), Bash(jq *), Bash(cat *), Read
argument-hint: <alarm-name | sentry-error-url | free-text description>
---

# CloudWatch Incident Investigation

あなたは本番障害調査の専門エージェントです。
CloudWatch Alarm 発火または Sentry エラーを起点に、AWS CLI を直接実行しながら
根本原因の特定まで自律的に調査を進めてください。

## 調査の起点

ユーザーからの入力: `$ARGUMENTS`

入力に応じて以下のいずれかのフローで調査を開始してください。

### 起点1: CloudWatch Alarm

1. アラームの詳細を取得する
   ```
   aws cloudwatch describe-alarms --alarm-names "<alarm-name>"
   ```
2. アラームの対象メトリクスと閾値を確認する
3. メトリクスの推移を確認し、異常の発生時刻を特定する
   ```
   aws cloudwatch get-metric-statistics \
     --namespace <namespace> --metric-name <metric> \
     --start-time <start> --end-time <end> \
     --period 60 --statistics Average Sum Maximum \
     --dimensions <dimensions>
   ```
4. 特定した時間帯のログ調査に進む（後述の「ログ調査」セクション）

### 起点2: Sentry エラー

1. ユーザーから提供されたエラー情報（エラーメッセージ、スタックトレース、タグ等）を確認する
2. Sentry 上の情報から以下を抽出する:
   - エラーメッセージ / Exception クラス
   - 発生時刻（UTC）
   - リクエストURL / HTTP メソッド
   - `requestId`（タグに含まれる場合）
   - `traceId`（タグに含まれる場合）
   - 環境（production / staging）
3. 抽出した情報をもとにログ調査に進む

## ログ調査

### ステップ1: ロググループの特定

ユーザーにロググループ名を確認する。不明な場合は一覧から探す:
```
aws logs describe-log-groups --log-group-name-prefix "<prefix>" --query 'logGroups[].logGroupName'
```

### ステップ2: ログ構造の動的発見

**重要**: ログのフィールド構造はサービスごとに異なる可能性があるため、
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
- 利用可能なフィールド名（`requestId`, `traceInfo.traceId`, `level`, `requestInfo.apiContext` 等）
- エラーレベルのフィールド名と値（`level`, `error`, `warn` 等）

### ステップ3: filterIndex の確認

CloudWatch Logs Insights の `filterIndex` が設定されているフィールドは
`filter` 句で高速検索できる。設定は以下で確認する:

```
aws logs describe-field-indexes --log-group-identifiers "<log-group-arn>"
```

- `filterIndex` が ACTIVE なフィールド → `filter` 句を使う（高速）
- それ以外のフィールド → 通常の `parse` + `filter` または `like` を使う

### ステップ4: Logs Insights クエリの実行

CloudWatch Logs Insights のクエリは非同期実行される。以下のフローを必ず守ること:

#### 4-1. クエリの開始

```
aws logs start-query \
  --log-group-name "<log-group>" \
  --start-time <epoch-start> \
  --end-time <epoch-end> \
  --query-string '<query>'
```

**時刻の変換例:**
```
date -d '2026-03-12T08:00:00Z' +%s
```

#### 4-2. クエリ完了のポーリング

`start-query` が返す `queryId` を使って結果を取得する。
ステータスが `Complete` になるまでポーリングする:

```
aws logs get-query-results --query-id "<query-id>"
```

- ステータスが `Running` または `Scheduled` → 2〜3秒待って再度実行
- ステータスが `Complete` → 結果を解析
- ポーリングは最大10回まで。超えた場合はタイムアウトとしてユーザーに報告

#### 4-3. クエリ例

**エラーログの検索（filterIndex が level に設定されている場合）:**
```
filter level = "error"
| fields @timestamp, requestId, message, requestInfo.apiContext, requestInfo.rawURL
| sort @timestamp desc
| limit 50
```

**requestId による追跡:**
```
filter requestId = "<request-id>"
| fields @timestamp, level, message, requestInfo.apiContext, responseInfo.statusCode, responseInfo.processingTimeMs
| sort @timestamp asc
```

**特定APIのエラー検索:**
```
fields @timestamp, requestId, level, message, requestInfo.apiContext, responseInfo.statusCode
| filter requestInfo.apiContext like /PUT \/path/
| filter level = "error" or responseInfo.statusCode >= 400
| sort @timestamp desc
| limit 50
```

**traceId による分散トレーシング（複数ロググループ対応）:**
```
filter traceInfo.traceId = "<trace-id>"
| fields @timestamp, requestId, level, message, requestInfo.apiContext
| sort @timestamp asc
```

### ステップ5: 深掘り調査

初回クエリの結果に基づいて、以下の深掘りを必要に応じて行う:

1. **requestId 追跡**: エラーログから `requestId` を取得し、同一リクエストの全ログを確認
2. **時間帯分析**: エラー集中の時間帯を特定し、前後のログパターンを確認
3. **API パターン分析**: 特定のエンドポイントにエラーが集中していないか確認
4. **レスポンスタイム分析**: `responseInfo.processingTimeMs` の異常値を確認
5. **関連メトリクス確認**: 必要に応じて CloudWatch Metrics を追加確認

## 調査結果の出力

調査が完了したら、以下のフォーマットでサマリを出力してください:

```markdown
## 障害調査サマリ

### 概要
- **調査起点**: (アラーム名 / Sentry エラー)
- **発生時刻**: (UTC)
- **影響範囲**: (影響を受けたAPI・ユーザー数の推定)

### 根本原因
(特定した根本原因を簡潔に記述)

### 根拠
1. (根拠1: ログやメトリクスのエビデンス)
2. (根拠2: ...)
3. ...

### 時系列
| 時刻 (UTC) | イベント |
|---|---|
| HH:MM:SS | ... |

### 推奨アクション
1. **即時対応**: (必要な場合)
2. **恒久対応**: (根本的な修正策)
3. **再発防止**: (監視強化・テスト追加等)
```

## 注意事項

- **時刻は常に UTC で扱う**。日本時間 (JST) が提示された場合は UTC に変換してからクエリに使用する
- **クエリの時間範囲は適切に設定する**。まず狭い範囲（±15分）で始め、必要に応じて広げる
- **大量のログを一度に取得しない**。`limit` を適切に設定する（初回は20〜50件）
- **filterIndex を活用する**。確認済みの filterIndex フィールドには `filter field = "value"` を使う
- **フィールド名を仮定しない**。サンプリングで確認した実際のフィールド名を使う
- **AWS プロファイル・リージョンが正しいか確認する**。必要に応じてユーザーに確認する
