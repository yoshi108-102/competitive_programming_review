# Phase 7 プレビュー教材: EventBridge — スケジュール & イベントバス

> プレビュー教材: デモ体験のために先行生成しました。正式な lesson / 振り返りクイズ / 採点は Phase 7 到達時に実施します。

---

## このサービスは何か

Amazon EventBridge は、**イベント駆動アーキテクチャ**を実現するサーバーレスのイベントバスサービスです。大きく 2 つの機能を持ちます。

| 機能 | 概要 |
|------|------|
| **EventBridge (イベントバス)** | AWS サービス・独自アプリ・SaaS が発行するイベントをルールでフィルタし、複数ターゲットへ配信する疎結合ハブ |
| **EventBridge Scheduler** | cron/rate 式や 1 回限り(one-time)のスケジュールで Lambda・SQS 等を呼び出す専用スケジューラ |

2 つは独立したサービスですが、どちらも「**ポーリング不要**」「**Lambda や Step Functions を直接ターゲットに指定できる**」という共通思想を持ちます。

---

## いつ使うか・使わないか

### 使う場面

- **定期バッチ処理**: 毎朝 9 時に AtCoder 提出データを同期する Lambda を起動したい
- **AWS サービス間連携**: S3 にファイルがアップロードされたら Lambda を呼ぶ
- **マイクロサービス間の疎結合通知**: 提出ステータス変化を他サービスへブロードキャストしたい
- **SaaS イベント連携**: GitHub / Datadog 等の外部 SaaS からのイベントを受信して処理したい

### 使わない場面

- リクエスト/レスポンスが必要な**同期 API 呼び出し** → API Gateway + Lambda
- メッセージの**順序保証・FIFO**が必要 → SQS FIFO
- 大量ストリームの**連続処理** → Kinesis Data Streams

---

## コアコンセプト

### イベントバス側

```
発行者 (Producer)
  └─ PutEvents API → イベントバス → ルール (EventPattern 評価)
                                        ├─ 一致 → ターゲット A (Lambda)
                                        ├─ 一致 → ターゲット B (SQS)
                                        └─ 不一致 → ドロップ (デフォルト)
```

- **イベントバス**: デフォルトバス(AWS サービス用)と、自前の**カスタムバス**を作れる
- **ルール**: イベントパターンまたはスケジュール式を持つ。1 バスに複数ルールを設定可
- **ターゲット**: 1 ルールにつき最大 5 ターゲット(Lambda, SQS, Step Functions, SNS 等)

### Scheduler 側

```
スケジュール (cron/rate/one-time)
  └─ 発火時刻 → フレキシブルタイムウィンドウ → ターゲット呼び出し
```

- **EventBridge ルールのスケジュール**とは別サービス。タイムゾーン指定・フレキシブルウィンドウ・1 回限り実行が可能
- **フレキシブルタイムウィンドウ**: 指定分の幅でランダムに分散発火させ、同時実行スパイクを平滑化

---

## 主要な設定・API・パラメータ

### スケジュール式

```
# rate 式
rate(5 minutes)     # 5分ごと
rate(1 hour)        # 1時間ごと

# cron 式 (EventBridge は 6 フィールド、タイムゾーンは UTC)
cron(分 時 日 月 曜日 年)
cron(0 9 * * ? *)   # 毎日 09:00 UTC
cron(0 0 1 * ? *)   # 毎月1日 00:00 UTC
```

> **注意**: EventBridge の cron は Unix cron と異なり **6 フィールド**（末尾に年フィールドあり）。曜日と日を同時に `*` にはできない — どちらか一方を `?` にする。

### イベントパターン

```json
{
  "source": ["atcoder"],
  "detail-type": ["submission"],
  "detail": {
    "result": ["AC"]
  }
}
```

- トップレベルフィールド: `source` / `detail-type` / `detail` / `account` / `region` 等
- 配列の値は **OR 条件**。複数フィールドは **AND 条件**
- `detail` 内はネスト可能。`prefix`, `numeric`, `exists` 等の**コンテンツフィルタリング**が使える

### PutEvents (SDK 例)

```python
import boto3

client = boto3.client("events")
client.put_events(
    Entries=[
        {
            "Source": "atcoder",
            "DetailType": "submission",
            "Detail": '{"problem_id": "abc001_a", "result": "AC"}',
            "EventBusName": "my-custom-bus",
        }
    ]
)
```

### Terraform リソース (主要)

```hcl
resource "aws_cloudwatch_event_rule" "daily_sync" {
  name                = "daily-sync"
  schedule_expression = "cron(0 9 * * ? *)"
}

resource "aws_cloudwatch_event_target" "sync_lambda" {
  rule = aws_cloudwatch_event_rule.daily_sync.name
  arn  = aws_lambda_function.sync.arn
}
```

> EventBridge の Terraform リソース名は `aws_cloudwatch_event_*` (旧 CloudWatch Events の名残)。Scheduler は `aws_scheduler_schedule`。

---

## よくある落とし穴・誤解

| 落とし穴 | 正しい理解 |
|----------|-----------|
| cron の曜日フィールドに `*` を使う | 日フィールドが `*` のとき曜日は `?` にしなければならない (逆も然り) |
| デフォルトバスに PutEvents を送ればルールが動く | カスタムバスを使う場合はルールの `event_bus_name` を明示しないとデフォルトバスにルーティングされない |
| イベントパターン不一致はエラーになる | 静かにドロップされるだけ。CloudWatch Metrics の `FailedInvocations` / `MatchedEvents` で確認する |
| EventBridge = CloudWatch Events | 旧称。現在の正式名は EventBridge だが Terraform リソース名は旧名のまま |
| Scheduler と EventBridge ルールのスケジュールは同じ | Scheduler は別サービス。タイムゾーン・1 回限り・フレキシブルウィンドウ対応という優位点がある |
| Lambda ターゲットへの権限は自動付与 | EventBridge がLambdaを呼ぶには `aws_lambda_permission` (resource-based policy) の明示的な付与が必要 |

---

## このプロジェクト(AtCoder復習)での使いどころ

### 1. 定期同期ジョブ (Scheduler)

毎朝 9 時 JST (= 0 時 UTC) に `sync_submissions` Lambda を起動して AtCoder の提出を取得する。

```
EventBridge Scheduler
  cron(0 0 * * ? *)  [UTC]
    └─ sync_submissions Lambda
```

Scheduler を選ぶ理由: タイムゾーンを Asia/Tokyo で直接指定できるため、UTC 変換ミスを防げる。

### 2. 提出完了イベントの疎結合配信 (イベントバス)

将来的にリアルタイム解析や Slack 通知を加えたい場合、Lambda が直接 Slack を叩くのではなく、カスタムバスへ `submission.completed` イベントを発行する設計にしておくと、ターゲットの追加・削除がルール変更だけで済む。

```
sync_submissions Lambda
  PutEvents → custom-bus
    └─ ルール (source=atcoder, detail-type=submission.completed)
         ├─ notify_slack Lambda
         └─ update_stats Lambda  ← 後から追加しやすい
```

---

## デモで体験したこと

`docs/learning/phase7/demo/index.html` の 2 カードデモでは以下を確認できます。

**(1) スケジューラカード**: `rate(5 minutes)` や `cron(0 9 * * ? *)` を入力欄に打ち込むと、仮想時計がティックして式を評価し、一致タイミングで Lambda アイコンが点灯・`.log` に発火記録が追記されます。次回発火予定 5 件が常に表示されるため、cron の曜日/日フィールドの `?` の扱いや UTC 換算を目で追って確認できます。

**(2) イベントバスカード**: JSON でイベントパターン（`{"source":["atcoder"],"detail-type":["submission"]}`）を設定し、`source` / `detail-type` / `detail` を持つサンプルイベントを「発行」すると、パターン一致なら `.flow-node.ok` が光ってターゲットへルーティング、不一致なら `.badge.warn` が表示されてドロップされる様子が視覚的に分かります。フィールドの書き間違い一つで静かにドロップされる動作を体感することが、本番での `MatchedEvents` メトリクス監視の重要性を直感させます。

---

## 公式ドキュメント（出典）

- https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-what-is.html （閲覧日 2026-05-31）
- https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html （閲覧日 2026-05-31）
- https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-create-rule-schedule.html （閲覧日 2026-05-31）
- https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-event-patterns.html （閲覧日 2026-05-31）
