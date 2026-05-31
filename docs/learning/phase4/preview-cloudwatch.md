# Phase 4 プレビュー教材: CloudWatch — メトリクス・ログ・アラーム

> プレビュー教材: デモ体験のために先行生成しました。正式な lesson / 振り返りクイズ / 採点は Phase 4 到達時に実施します。

---

## このサービスは何か

Amazon CloudWatch は AWS の統合モニタリングサービスで、次の 3 本柱で構成される。

| 柱 | 役割 |
|---|---|
| **Metrics** | AWS サービスやアプリが発行する数値時系列データ |
| **Logs** | Lambda・EC2 などが出力するテキストログの収集・検索 |
| **Alarms** | メトリクスの状態変化を検知し SNS / Auto Scaling などに通知 |

CloudWatch はリージョン単位のサービス。各 AWS サービスが自動的にメトリクスを発行するため、追加エージェント不要で即座に可視化できる。

---

## いつ使うか・使わないか

### 使う場面

- Lambda の実行エラー率・Duration が急増したとき即座に検知したい
- 本番ログを集中管理して後から障害原因を調査したい
- メトリクスがしきい値を超えたら自動でスケールアウトしたい

### 使わない場面 / 代替を検討する場面

| 状況 | 代替候補 |
|---|---|
| フルテキスト検索・全文インデックスが必要 | Amazon OpenSearch Service |
| 複数アカウント横断の大規模ログ分析 | Amazon Athena + S3 Export |
| APM (分散トレーシング) が主目的 | AWS X-Ray |

---

## コアコンセプト

### Metrics（メトリクス）

```
Namespace / MetricName / Dimensions → 一意な時系列
```

- **Namespace**: メトリクスの論理グループ（例: `AWS/Lambda`、`MyApp/API`）
- **Dimensions**: メトリクスを絞り込む属性の Key-Value ペア（例: `FunctionName=sync_submissions`）
- **Period**: 統計を計算する集計ウィンドウ（秒単位、最小 1 秒、通常 60 秒）
- **Statistics**: `Average` / `Sum` / `Maximum` / `Minimum` / パーセンタイル（`p99` 等）
- **Resolution**: 標準（60 秒以上）と高解像度（1 秒）の 2 種類

メトリクスのデータポイントは発行から **15 ヶ月** 保持される（解像度による粒度はフェードアウトあり）。

### Alarms（アラーム）

アラームは 3 状態を遷移する。

```
OK ←──────────────→ ALARM
       ↑      ↑
  INSUFFICIENT_DATA（データ不足）
```

しきい値評価の設定例:

```
評価期間(Evaluation Periods) = 5
しきい値超えに必要な期間数(Datapoints to Alarm) = 3
→「直近 5 期間中 3 期間がしきい値超え」でALARM遷移
```

アクションとして SNS トピック・EC2 アクション・Auto Scaling ポリシーを紐付けられる。

### Logs（ログ）

```
Log Group
  └─ Log Stream（例: Lambda 関数の実行インスタンス単位）
       └─ Log Event（タイムスタンプ + メッセージ）
```

- **Log Group** にはリテンション期間（1 日〜10 年 or 無期限）を設定できる
- Lambda は自動で `/aws/lambda/<FunctionName>` ロググループを作成する
- **Metric Filter**: ログイベントのパターンにマッチした件数をカスタムメトリクスとして発行できる

### CloudWatch Logs Insights

Log Group に対してクエリ言語でリアルタイム集計を行う機能。

```sql
fields @timestamp, @message, level
| filter level = "ERROR"
| sort @timestamp desc
| limit 50
```

主なコマンド: `fields` / `filter` / `stats` / `sort` / `limit` / `parse`

---

## 主要な設定・API・パラメータ

### カスタムメトリクスの発行（AWS SDK / CLI）

```python
import boto3
cloudwatch = boto3.client("cloudwatch", region_name="ap-northeast-1")

cloudwatch.put_metric_data(
    Namespace="AtCoderReview/API",
    MetricData=[
        {
            "MetricName": "SubmissionSyncErrors",
            "Dimensions": [{"Name": "Stage", "Value": "prod"}],
            "Value": 1,
            "Unit": "Count",
        }
    ],
)
```

### アラームの作成

```python
cloudwatch.put_metric_alarm(
    AlarmName="LambdaErrorRate-High",
    Namespace="AWS/Lambda",
    MetricName="Errors",
    Dimensions=[{"Name": "FunctionName", "Value": "sync_submissions"}],
    Statistic="Sum",
    Period=300,           # 5 分
    EvaluationPeriods=3,
    DatapointsToAlarm=2,  # 3 期間中 2 期間超えで ALARM
    Threshold=5.0,
    ComparisonOperator="GreaterThanOrEqualToThreshold",
    AlarmActions=["arn:aws:sns:ap-northeast-1:xxxx:alert-topic"],
    TreatMissingData="notBreaching",
)
```

### 主要パラメータ早見表

| パラメータ | 説明 | 典型値 |
|---|---|---|
| `Period` | 統計集計ウィンドウ（秒） | 60 / 300 |
| `EvaluationPeriods` | 評価する期間数 | 3〜5 |
| `DatapointsToAlarm` | ALARM 遷移に必要な超過期間数 | EvaluationPeriods 以下 |
| `TreatMissingData` | データ欠損時の扱い | `notBreaching` / `breaching` / `ignore` / `missing` |
| `ComparisonOperator` | しきい値比較方向 | `GreaterThanOrEqualToThreshold` 等 |

---

## よくある落とし穴・誤解

### 1. Logs と Metrics は別物

ログはテキストの羅列、メトリクスは数値時系列。ログから「エラー件数」のメトリクスを取るには **Metric Filter** を設定するか、アプリ側で `put_metric_data` を呼ぶ必要がある。「ログを見るだけ」ではアラームを張れない。

### 2. Period と統計の選択ミス

`Average` は単純平均のため、短時間のスパイクを見逃しやすい。エラー件数は `Sum`、レイテンシのテール遅延は `p99` を使う。

### 3. INSUFFICIENT_DATA でアラームが鳴らない

Lambda が一定時間呼ばれないとメトリクスデータポイントが欠損し、`INSUFFICIENT_DATA` 状態に留まる。`TreatMissingData=breaching` にするとデータ欠損もエラーとみなせるが、意図しない誤報になることもある。用途に合わせて設定する。

### 4. ログの構造化を怠る

`print("error occurred")` のような非構造化ログでは Logs Insights の `filter` やメトリクスフィルタが使いにくい。`{"level": "ERROR", "message": "...", "request_id": "..."}` の JSON フォーマットを Lambda から出力すると、Logs Insights での集計効率が大幅に上がる。

### 5. コスト見落とし

カスタムメトリクス数・API コール数・Logs Insights クエリはすべて課金対象。高解像度メトリクスや大量ログは予想外のコストになることがある。

---

## このプロジェクト（AtCoder 復習）での使いどころ

| 監視対象 | メトリクス / ログ | アラーム例 |
|---|---|---|
| `sync_submissions` Lambda | `AWS/Lambda: Errors`, `Duration` | エラー数 > 5 / 5 分 |
| `get_submissions` Lambda | カスタム: DynamoDB スキャン件数 | スキャン件数急増 |
| API Gateway | `4XXError`, `5XXError`, `Latency` | 5XX > 10 / 分 |
| DynamoDB | `ConsumedWriteCapacityUnits` | WCU 使用率 > 80% |

Lambda が出力する JSON ログを `/aws/lambda/sync_submissions` ロググループに収集し、Logs Insights で `filter level = "ERROR"` とクエリするだけで障害調査の起点になる。Metric Filter を使えばエラーログ件数を自動的にメトリクスに変換し、アラームで Slack 通知（SNS → Lambda → Slack Webhook）まで繋げられる。

---

## デモで体験したこと

デモページ（`docs/learning/phase4/demo/index.html`）では Lambda Errors / Duration を模したメトリクスが `setInterval` で時系列にプロットされる折れ線グラフを操作した。スライダーでしきい値と評価期間 N を動かすと、メトリクスが N 期間連続でしきい値を超えた瞬間に状態バッジが `OK` → `ALARM` に切り替わり、シミュレートされた SNS 通知行がログパネルに流れることで「DatapointsToAlarm の仕組み」が視覚的に掴めた。下の CloudWatch Logs パネルではレベル / キーワードフィルタで行を絞り込み、`avg` / `p99` 切替により統計の選択が結果に与える影響を体感した。

---

## 公式ドキュメント（出典）

- https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/WhatIsCloudWatch.html（閲覧日 2026-05-31）
- https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch_concepts.html（閲覧日 2026-05-31）
- https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/AlarmThatSendsEmail.html（閲覧日 2026-05-31）
- https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/AnalyzingLogData.html（閲覧日 2026-05-31）

---

## 関連・発展サービス

### CloudWatch Logs Insights — SQL ライクなログ分析

`filter` / `stats` / `sort` / `limit` / `parse` の 5 コマンドで大半の分析が完結する。よく使うパターンを覚えておくと障害調査が劇的に速くなる。

```
# p99 Duration を関数ごとに計算
fields @requestId, @duration, @functionName
| stats pct(@duration, 99) as p99 by @functionName
| sort p99 desc

# Cold Start だけ抽出して平均・最大を計測
filter @message like /Init Duration/
| parse @message "Init Duration: * ms" as initMs
| stats avg(initMs), max(initMs) by bin(5m)

# エラーメッセージの種類をランキング
filter @message like /ERROR/
| parse @message "[ERROR] *" as errMsg
| stats count(*) as cnt by errMsg
| sort cnt desc
| limit 10
```

**つまずきポイント**: `bin()` の引数は `1m` や `5m` のような duration 文字列。`bin(60)` のように数値だけを渡すと構文エラーになる。コンソールのクエリエディタは補完が効くので最初はコンソールで試してから CLI に移すと良い。

### EMF(Embedded Metric Format) の真価

EMF は「ログ出力だけでカスタムメトリクスを生成する」手法。`PutMetricData` API を直接叩く必要がなく、Lambda / ECS / EC2 問わず同じコードパスで使える。JSON ログに `_aws.CloudWatchMetrics` キーが含まれると、CloudWatch Logs 側が自動的にメトリクスとして抽出する仕組み。

```python
# EMF 形式の最小例(producer.py より)
import json, time

emf = {
    "_aws": {
        "Timestamp": int(time.time() * 1000),
        "CloudWatchMetrics": [{
            "Namespace": "Phase4/Lambda",
            "Dimensions": [["FunctionName"]],
            "Metrics": [
                {"Name": "ItemsWritten", "Unit": "Count"},
                {"Name": "ErrorCount",   "Unit": "Count"},
            ]
        }]
    },
    "FunctionName": context.function_name,
    "ItemsWritten": items_written,
    "ErrorCount": errors,
}
print(json.dumps(emf))  # これだけ。API 呼び出し不要
```

重要な制約:
- 1 ログイベントあたりディメンション 9 個まで
- `StorageResolution: 1` にすると高解像度メトリクス(1 秒粒度)になり **追加課金**が発生する(標準の 3 倍)
- EMF ドキュメント自体は CloudWatch Logs に残るためログ保持期間の課金にも影響する

### Contributor Insights — ホットパーティション特定

「どの pk が DynamoDB を最も叩いているか」をリアルタイムランキングする機能。ルール 1 本で有効化でき、ホットパーティション起因のスロットリングの原因特定が劇的に速くなる。

DynamoDB 側の設定から有効化する(CloudWatch コンソールではなく DynamoDB コンソールの「Contributor Insights」タブ)。ルール例:

```json
{
  "Schema": { "Name": "DynamoDB-schema", "Version": 1 },
  "AggregateOn": "Count",
  "Contribution": { "Keys": ["$.dynamodb.keys.pk.S"] },
  "LogFormat": "JSON",
  "LogGroupARNs": [
    "arn:aws:logs:ap-northeast-1:ACCOUNT:log-group:/aws/dynamodb/tables/phase4-events/data-plane:*"
  ]
}
```

### Synthetics Canary — 外形監視

外部 bot が定期的にエンドポイントを叩き、成功率・レイテンシ・スクリーンショットを CloudWatch に保存する。API Gateway + Lambda を Phase 5 以降で作ったら即 Canary を追加すると本番品質の可観測性になる。

```hcl
resource "aws_synthetics_canary" "api_health" {
  name                 = "phase5-api-health"
  artifact_s3_location = "s3://${aws_s3_bucket.canary.id}/canary/"
  execution_role_arn   = aws_iam_role.canary.arn
  runtime_version      = "syn-nodejs-puppeteer-6.2"
  handler              = "apiCanary.handler"
  zip_file             = data.archive_file.canary.output_path
  schedule { expression = "rate(5 minutes)" }
  start_canary = true
}
```

**つまずきポイント**: S3 バケットに Block Public Access を有効化した上で、Canary IAM ロールに `s3:PutObject` と `cloudwatch:PutMetricData` を付与する必要がある。ここが抜けると Canary が "Error" 状態で起動し、スクリーンショットも保存されない。

### RUM(Real User Monitoring) — 実ユーザーのブラウザ計測

Synthetics が合成(bot)モニタリングであるのに対し、RUM は実ユーザーのブラウザ/アプリのメトリクスを収集する。JavaScript スニペット 1 行を HTML に埋め込むだけで Core Web Vitals(LCP / FID / CLS)が CloudWatch に流れ込む。Phase 7 以降で CloudFront + S3 の静的サイトを作る際に追加すると観測レイヤーが一気に厚くなる。

### CloudWatch Application Signals — SLO 管理統合(2024 GA)

Lambda や ECS の分散トレースを SLO/SLI と紐付けて管理する APM 機能。`aws-distro-for-opentelemetry`(ADOT)レイヤーを Lambda に追加するだけで自動計装される。X-Ray との統合が前提で、サービスマップ上で依存関係ごとのエラー率・レイテンシを可視化できる。まだコストが高めなので Sandbox では短時間の確認に留めるのが無難。

---

## セキュリティ課題と対策

### CloudWatch Logs の PII マスキング — Data Protection Policy

2022 年末 GA。ロググループにデータ保護ポリシーを付けると、クレカ番号・メールアドレス・日本のマイナンバー等を自動で `****` にマスキングする。Lambda が意図せず個人情報をログに出力してしまうシナリオを検知・隠蔽できる。

```hcl
resource "aws_cloudwatch_log_data_protection_policy" "pii_mask" {
  log_group_name = aws_cloudwatch_log_group.producer_logs.name
  policy_document = jsonencode({
    Name    = "phase4-pii-mask"
    Version = "2021-06-01"
    Statement = [
      {
        Sid = "audit-policy"
        DataIdentifier = [
          "arn:aws:dataprotection::aws:data-identifier/EmailAddress",
          "arn:aws:dataprotection::aws:data-identifier/CreditCardNumber",
          "arn:aws:dataprotection::aws:data-identifier/JapaneseMyNumber",
        ]
        Operation = {
          Audit = {
            FindingsDestination = {
              CloudWatchLogs = { LogGroup = aws_cloudwatch_log_group.producer_logs.name }
            }
          }
        }
      },
      {
        Sid = "redact-policy"
        DataIdentifier = [
          "arn:aws:dataprotection::aws:data-identifier/EmailAddress",
          "arn:aws:dataprotection::aws:data-identifier/CreditCardNumber",
        ]
        Operation = { Deidentify = { MaskConfig = {} } }
      }
    ]
  })
}
```

**つまずきポイント**: マスキングされたログは `GetLogEvents` でもマスク済みの文字列が返る。元データを見るには `logs:Unmask` 権限が必要で、意図的に分離した IAM ロール(セキュリティ調査専用)にのみ付与する設計が鉄則。開発者ロールに `logs:Unmask` を付けてしまうと運用上の意味が薄れる。

### ログ暗号化(KMS)の落とし穴

KMS で CloudWatch Logs を暗号化する際、KMS キーポリシーに `logs.{region}.amazonaws.com` サービスプリンシパルを許可しないと Lambda がログを書き込めなくなる。よくある失敗の連鎖:

1. KMS キーを作成し、ルートアカウントのみ許可するキーポリシーを設定した
2. CloudWatch Logs が `GenerateDataKey` を呼べずにログ書き込みが全滅した
3. Lambda のエラーログ自体も CloudWatch に書けないため、何が起きているか追跡できなくなった

対策は KMS キーポリシーで `EncryptionContext` を `kms:EncryptionContext:aws:logs:arn` で絞り込んだ上で CloudWatch Logs サービスプリンシパルを許可すること(Sandbox の `main.tf` に実装済み)。

```json
{
  "Sid": "AllowCWLogs",
  "Effect": "Allow",
  "Principal": { "Service": "logs.ap-northeast-1.amazonaws.com" },
  "Action": ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"],
  "Resource": "*",
  "Condition": {
    "ArnLike": {
      "kms:EncryptionContext:aws:logs:arn":
        "arn:aws:logs:ap-northeast-1:ACCOUNT_ID:*"
    }
  }
}
```

`EncryptionContext` の条件を付けないと、同リージョンのすべての CloudWatch Logs(他サービスのロググループも含む)がこのキーを使えてしまう。最小権限原則に反する。

### IAM でログアクセスを絞り込む

CloudWatch Logs へのアクセスは `logs:GetLogEvents` / `logs:FilterLogEvents` / `logs:StartQuery` で制御する。よくある過剰設定:

- `logs:*` を全開発者ロールに付与
- `Resource: "*"` でロググループ横断アクセスを許可

最小権限設計では特定のロググループ ARN パターンのみ許可する:

```json
{
  "Effect": "Allow",
  "Action": ["logs:FilterLogEvents", "logs:GetLogEvents"],
  "Resource": "arn:aws:logs:ap-northeast-1:ACCOUNT_ID:log-group:/aws/lambda/phase4-*:*"
}
```

`/aws/lambda/phase4-*` のワイルドカードにより、phase4 専用の Lambda ログのみアクセス可。他 Phase・他サービスのログには届かない。

### CloudWatch Logs vs CloudTrail の使い分け

よく混同される 2 つのサービス:

| 比較軸 | CloudWatch Logs | CloudTrail |
|---|---|---|
| 対象 | アプリケーションログ・AWS サービスログ | AWS API コール(誰が何の API を叩いたか) |
| 主な用途 | デバッグ・メトリクス抽出・アラーム | 監査・セキュリティ調査・コンプライアンス |
| コスト | 保存 GB + クエリ GB | 証跡作成は無料 + S3 保存コスト |
| 保持設定 | `retention_in_days` | S3 ライフサイクルで管理 |

CloudTrail は Management Events(API コール)を自動記録するが、デフォルトでは CloudWatch Logs に転送されない。転送する場合は `aws_cloudtrail` リソースで `cloud_watch_logs_group_arn` を設定する。セキュリティインシデントの調査では「誰がいつどの API を叩いたか」は CloudTrail を、「その API が何を引き起こしたか」は CloudWatch Logs を見る、という役割分担が基本。

### SNS トピックへの CloudWatch アラームのアクセス制御

SNS + CloudWatch Alarms の構成でよく漏れるのが SNS トピックへのリソースポリシー。CloudWatch が `SNS:Publish` を呼べるようにするポリシーが必要で、かつ `aws:SourceArn` で条件を絞る:

```json
{
  "Effect": "Allow",
  "Principal": { "Service": "cloudwatch.amazonaws.com" },
  "Action": "SNS:Publish",
  "Resource": "arn:aws:sns:ap-northeast-1:ACCOUNT_ID:phase4-alerts",
  "Condition": {
    "ArnLike": {
      "aws:SourceArn": "arn:aws:cloudwatch:ap-northeast-1:ACCOUNT_ID:alarm:phase4-*"
    }
  }
}
```

`aws:SourceArn` の条件を省くと、同アカウントの任意の CloudWatch アラームがこのトピックに通知を送れてしまう。テナント分離が崩れるリスクがある。

---

## インフラ応用パターン

### SLO/SLI ダッシュボードの設計

本番では「Error Rate < 1% for 99.9% of the time in 30 days」のような SLO を定義して CloudWatch で計測する。Dashboard に Metric Math で直接書ける:

```hcl
# dashboard.tf に追加するウィジェット例
{
  type = "metric"
  properties = {
    title  = "Error Budget (30d rolling)"
    period = 60
    metrics = [
      ["AWS/Lambda", "Errors",      "FunctionName", "phase4-producer",
        {"id": "e1", "visible": false}],
      ["AWS/Lambda", "Invocations", "FunctionName", "phase4-producer",
        {"id": "i1", "visible": false}],
      [{"expression": "1-(e1/i1)", "label": "Availability", "id": "avail"}],
      [{"expression": "IF(avail > 0.999, 1, 0)", "label": "SLO Met (>99.9%)", "id": "slo"}],
    ]
  }
}
```

Metric Math では `FILL` / `IF` / `RATE` / `SEARCH` 等の関数が使える。エラーバジェット残量を可視化しておくと、「まだ余裕がある」「今月あと何件エラーが許されるか」が一目で分かり、リリース判断の材料になる。

### Anomaly Detection(異常検知アラーム)

過去の時系列パターンを機械学習で学習し、「いつもと違う」値で自動アラームを出す。固定閾値を決めにくいメトリクス(例: 曜日・時間帯で大きく変動する Invocations)に有効。

```hcl
resource "aws_cloudwatch_metric_alarm" "duration_anomaly" {
  alarm_name          = "phase4-duration-anomaly"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 2
  threshold_metric_id = "ad1"

  metric_query {
    id          = "m1"
    return_data = false
    metric {
      metric_name = "Duration"
      namespace   = "AWS/Lambda"
      period      = 60
      stat        = "p99"
      dimensions  = { FunctionName = "phase4-producer" }
    }
  }

  metric_query {
    id          = "ad1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 2)"
    return_data = true
    label       = "Duration (expected band)"
  }
}
```

`ANOMALY_DETECTION_BAND(m1, 2)` の `2` はバンド幅(標準偏差の倍数)。小さくすると敏感になり誤報が増える。

**つまずきポイント**: 学習データが 2 週間分以上ないとバンドが広すぎてアラームが鳴らない。新規 Sandbox では即座に有効活用できないため、まず固定閾値アラームで慣れてから導入すると良い。

### Composite Alarm による通知疲れ(Alarm Fatigue)防止

アラーム 30 本が全部 SNS に飛んでくると、オンコール担当が通知を無視するようになる「通知疲れ」が起きる。Composite Alarm で絞り込みと集約を行い、PagerDuty や OpsGenie へのブリッジは SNS Subscription で繋ぐのが定石。

```hcl
# AND/OR/NOT が使える
resource "aws_cloudwatch_composite_alarm" "critical_only" {
  alarm_name = "phase4-critical"
  # 「エラーが出ているかつ高負荷時のみ通知」
  # → 低負荷時の散発エラーは無視するという SLO 設計
  alarm_rule = "ALARM(\"phase4-producer-errors\") AND ALARM(\"phase4-producer-duration-high\")"
  alarm_actions = [aws_sns_topic.alerts.arn]
}
```

本番の設計指針:
1. 個別アラームは `alarm_actions` を空にしてサイレントにする
2. Composite Alarm だけが SNS に通知する
3. SNS → PagerDuty / OpsGenie でインシデント管理ツールに連携
4. 夜間のオンコールは Critical のみ、営業時間は Warning も含める、のような時間帯別設定は EventBridge Scheduler + Lambda で制御する

### 高解像度メトリクスのコスト試算

| 解像度 | StorageResolution | 費用(追加分) |
|--------|-------------------|----|
| 標準(60 秒) | 60 または省略 | 無料枠内 |
| 高解像度(1 秒) | 1 | 標準の約 3 倍(メトリクス保存・アラーム評価) |

1 つのカスタムメトリクスの月額は $0.30(最初の 10,000 メトリクス)。高解像度にすると約 $0.90。10 メトリクスを高解像度にすると月 $6 の差。マイクロサービスで 1,000 メトリクスを全て高解像度にすると月 $600 超の差になる。「1 秒粒度でないと困るか」を設計時に検証することが重要。

### Lambda Insights の深掘りと Power Tuning

Lambda Insights(`LambdaInsightsExtension` レイヤー)は CloudWatch エージェント相当の機能を Lambda に付加し、以下のメトリクスを `LambdaInsights` Namespace に自動投入する:

| メトリクス | 説明 |
|---|---|
| `memory_utilization` | 設定メモリに対する実使用率(%) |
| `used_memory_max` | 実行中の最大メモリ使用量(MB) |
| `init_duration` | Cold Start 時間(ms) |
| `cpu_total_time` | CPU 使用時間(ms) |
| `rx_bytes` / `tx_bytes` | ネットワーク I/O |

特に `memory_utilization` は Lambda の **Power Tuning** に欠かせない。メモリを増やすと CPU も増えて実行が速くなるため、コストと速度のスイートスポットが必ずしも最小メモリではない。[AWS Lambda Power Tuning](https://github.com/alexcasalboni/aws-lambda-power-tuning) ツール(Step Functions で動く OSS)を使って実測値ベースで判断するのが本番手順。

また、`architecture = "arm64"` にするだけで Graviton2 になり、同じメモリで約 20% コスト削減・10〜15% 高速化が期待できる。ただし依存ライブラリのアーキテクチャ互換性(特にネイティブ拡張)を確認してから切り替える。

### CloudWatch Logs → S3 → Athena のログアーカイブパターン

本番でよく見るアーキテクチャ:

```
Lambda ログ
  → CloudWatch Logs
    → Subscription Filter
      → Kinesis Data Firehose
        → S3(GZIP 圧縮)
          → Athena でアドホック SQL 分析
```

Terraform での実装:

```hcl
resource "aws_kinesis_firehose_delivery_stream" "log_archive" {
  name        = "phase4-log-archive"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn           = aws_iam_role.firehose.arn
    bucket_arn         = aws_s3_bucket.log_archive.arn
    buffering_size     = 5      # MB。5 MB 溜まったら S3 に書き出す
    buffering_interval = 300    # 秒。5 分経ったら溜まっていなくても書き出す
    compression_format = "GZIP"
  }
}

resource "aws_cloudwatch_log_subscription_filter" "to_firehose" {
  name            = "phase4-to-firehose"
  log_group_name  = aws_cloudwatch_log_group.producer_logs.name
  filter_pattern  = ""           # 空 = 全ログ転送
  destination_arn = aws_kinesis_firehose_delivery_stream.log_archive.arn
  distribution    = "Random"     # シャード間でランダム分散
}
```

CloudWatch Logs Insights は直近 30 日程度の高速クエリに向いており、それ以前のログやクロスアカウント分析は Athena が適している。保持期間 1 日で削除される前に S3 に退避しておけば、監査要件(例: 1 年保存)にも対応できる。

### ダッシュボード as Code のスケール問題と選択肢

Terraform で Dashboard JSON を管理すると、ウィジェット追加のたびに `terraform apply` が必要になる。規模が大きくなったときの選択肢:

1. **CDK(CloudWatch Dashboard Construct)** — TypeScript で型安全に記述。L2 Construct が充実しており、ウィジェットの追加が関数呼び出しで済む。Terraform との共存は `--hotswap` デプロイで速くなる。
2. **Amazon Managed Grafana** — CloudWatch を DataSource として接続し、ダッシュボードを GUI で編集・JSON Export できる。複数 AWS アカウント横断の統合ビューに向いている。Phase 8 以降の発展として検討価値あり。
3. **cw-dashboard-generator** — Python スクリプトで JSON テンプレートを生成するパターン。小規模チームでよく見かける折衷案。
