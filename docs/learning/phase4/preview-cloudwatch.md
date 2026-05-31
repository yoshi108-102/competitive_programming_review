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
