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

---

## 🧭 関連・発展サービス

### EventBridge Pipes — ポーリング型ソースとルールを繋ぐ隠れた名機

2022年末 GA の Pipes は「Source → (Filter) → (Enrichment) → Target」をマネージドに繋ぐサービス。最大の特徴は **SQS・DynamoDB Streams・Kinesis・Kafka MSK などのポーリング型ソース** を EventBridge のルール/ターゲット機構と組み合わせられる点にある。

**なぜ必要か**: 従来、SQS キューを Lambda で処理するには Event Source Mapping か、Lambda 内でポーリングループを自前実装するかしかなかった。Pipes を使うと、SQS からメッセージを取り出し → コンテンツベースフィルタリングで不要なメッセージを除去 → Step Functions や Lambda へ渡す、という流れをコードなしで繋げる。

**いつ使うか**: SQS 内のメッセージを「金額 > 5000 のものだけ Lambda で処理したい」「DynamoDB Streams の INSERT イベントだけ下流に流したい」といった条件フィルタが必要な場面。

**つまずきポイント**: Pipe の `filter_criteria` で弾かれたメッセージは **そのままソースから消える**。SQS なら visibility timeout 後に再表示されるので再処理できるが、DynamoDB Streams は一方通行なので取り返しがつかない。まずフィルタなしで動作確認し、段階的に条件を絞る手順が必須。

```bash
# SQS に送る → Pipe でフィルタ → Lambda が起動することを確認
aws sqs send-message \
  --queue-url https://sqs.ap-northeast-1.amazonaws.com/123456789012/phase7-pipe-source \
  --message-body '{"amount": 9999}'   # フィルタ通過

aws sqs send-message \
  --queue-url https://sqs.ap-northeast-1.amazonaws.com/123456789012/phase7-pipe-source \
  --message-body '{"amount": 100}'    # フィルタで落ちる → Lambda 起動なし
```

---

### EventBridge Scheduler — cron の完全置換候補

従来の EventBridge `cron()` ルールはデフォルトバス限定・UTC 固定・1回限り発火不可。Scheduler はこれらをすべて解消した専用サービス。

**主な優位点**:
- **タイムゾーン指定**: `schedule_expression_timezone = "Asia/Tokyo"` で UTC 変換ミスを根絶
- **1 回限り発火**: `at(2024-12-31T23:59:00)` — 過去日付は即無効化されるので安全
- **Flexible Time Window**: `mode = "FLEXIBLE", maximum_window_in_minutes = 15` で発火を±15分に分散させ、同時実行スパイクを平滑化
- **Schedule Group**: グループ単位でライフサイクル管理。不要になったスケジュール群をまとめて削除できる
- **Fargate タスクを直接ターゲット指定可能**: Lambda タイムアウト上限 15 分を超えるバッチジョブは ECS Fargate をターゲットにする

**実務ユースケース**: 月次レポート生成 Lambda、試用期限 n 日前通知、セール開始フック、バッチ ETL。「cron を Lambda で再実装するな、Scheduler に任せろ」が 2023年以降の定石。

**必須セット**: DLQ + retry_policy を必ず一緒に設定すること。発火失敗時の通知経路がないと障害に気づけない。

```hcl
# Confused Deputy 対策: Scheduler ロールに aws:SourceAccount 条件を付ける
assume_role_policy = jsonencode({
  Statement = [{
    Principal = { Service = "scheduler.amazonaws.com" }
    Action    = "sts:AssumeRole"
    Condition = {
      StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.me.account_id }
    }
  }]
})
```

---

### Schema Registry — イベント契約の可視化と型安全な SDK 生成

EventBridge のカスタムバスに流れるイベントのスキーマを自動検出・登録する機能。有効化すると AWS が OpenAPI 3 / JSONSchema Draft 4 形式で自動生成し、Python/Java/TypeScript/Go の型付き SDK バインディングをダウンロードできる。

**なぜ重要か**: イベント駆動アーキテクチャでチームが増えると「どのサービスがどんな形のイベントを流しているか」の把握が困難になる。Schema Registry はこの「イベント契約」をコードとして管理する場所になる。

```bash
# スキーマを確認
aws schemas describe-schema \
  --registry-name phase7-registry \
  --schema-name "com.example.orders@order.created"

# SDK バインディング(Python)をダウンロード
aws schemas get-code-binding-source \
  --registry-name phase7-registry \
  --schema-name "com.example.orders@order.created" \
  --language Python36 \
  --output text > order_created_schema.zip
```

**つまずき**: Schema Discovery は **別途有効化が必要** (`aws events put-discovery-configuration`)。有効中は1イベントスキーマ更新ごとに課金が発生する。本番では Discovery を常時 ON にせず、開発バスで学習 → 本番バスにスキーマを手動登録する運用が多い。

---

### Archive & Replay — タイムマシン機能

アーカイブされたイベントを任意の過去時刻から再流し(リプレイ)できる。**本番障害後に Lambda のバグを修正 → 失われたイベントを再処理** というユースケースで真価を発揮する。

```bash
# リプレイ実行例
aws events start-replay \
  --replay-name "fix-bug-20260531" \
  --source-arn arn:aws:events:ap-northeast-1:123456789012:archive/phase7-archive \
  --event-start-time "2026-05-31T00:00:00Z" \
  --event-end-time   "2026-05-31T12:00:00Z" \
  --destination '{"Arn": "arn:aws:events:ap-northeast-1:123456789012:event-bus/phase7-bus"}'
```

**注意点**:
- リプレイ中のイベントには `replay-name` フィールドが付与される。Lambda 内でこれを検出してべき等性チェックに使える
- リプレイ速度はコントロール不可(最速)なので、下流の DynamoDB/RDS がスロットリングしないか事前確認が必要
- アーカイブはカスタムバスのみ。デフォルトバスは Archive 非対応

---

### SaaS パートナーイベント — Webhook サーバー不要の外部 SaaS 連携

Salesforce / GitHub / Zendesk / Datadog / Auth0 などが EventBridge パートナーとして SaaS イベントを直接プッシュする仕組み。SaaS 側でパートナーイベントソースを有効化すると、AWS コンソールに `aws.partner/salesforce.com/xxx` のようなイベントソースが出現し、カスタムバスに関連付けて通常のルールでフィルタできる。

**つまずき**: パートナーイベントソースの **削除は SaaS 側からしか行えない**。Terraform で `aws_cloudwatch_event_bus` を destroy しても SaaS 側の接続が残る場合があり、再 apply でコンフリクトが起きることがある。

---

### API Destinations — Lambda を挟まず外部 HTTP を直接呼ぶ

Lambda を挟まず HTTP エンドポイントに POST できる機能。認証方式は BASIC / OAuth / API Key に対応し、接続情報は `aws_cloudwatch_event_connection` で管理される(接続情報は Secrets Manager に自動保存)。

**実務**: Slack Webhook / PagerDuty / Jira への通知を Lambda なしで繋ぐ。Input Transformer でペイロードを変換してから送信できるので、Lambda で変換ロジックを書く必要もない。スループット上限はデフォルト **300 TPS / Destination**。

---

## 🛡 セキュリティ課題と対策

### イベントバスのリソースポリシー — 最も見落とされる設定

デフォルトのカスタムバスはリソースポリシーなし = **同一アカウント内の全 Principal が PutEvents 可能**。意図せぬイベント送信を許してしまう。

**対策**: `aws_cloudwatch_event_bus_policy` で送信元を明示的に制限する。

```json
{
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:aws:iam::123456789012:role/order-service-role"
    },
    "Action": "events:PutEvents",
    "Resource": "arn:aws:events:ap-northeast-1:123456789012:event-bus/phase7-bus",
    "Condition": {
      "StringEquals": {
        "aws:SourceVpc": "vpc-0123456789abcdef0"
      }
    }
  }]
}
```

ロール単位に絞り、さらに `aws:SourceVpc` 条件でオンプレ VPC からのみ許可するパターンが本番では多い。

---

### クロスアカウントイベント配信 — 落とし穴と対策

Account A のバスから Account B のバスへイベントを送る手順:
1. Account B のバスにリソースポリシーで Account A を `Allow`
2. Account A の送信ロールに `events:PutEvents` 権限を付与

**落とし穴 1: Archive はクロスアカウントに追従しない**。Account A で Archive を設定しても、Account B に届いたイベントはアーカイブされない。リプレイが必要な場合は各アカウントでアーカイブを設定する。

**落とし穴 2: KMS クロスアカウント**。KMS 暗号化をクロスアカウントで使う場合は送信元アカウントの KMS キーポリシーに宛先アカウントの Principal を追加する必要がある。これを忘れると `AccessDeniedException` で詰まる。

```json
{
  "Sid": "AllowCrossAccountEB",
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::ACCOUNT-B:root" },
  "Action": ["kms:GenerateDataKey", "kms:Decrypt"],
  "Resource": "*"
}
```

---

### Lambda ターゲットの最小権限 IAM — source_arn 条件の必要性

EventBridge が Lambda を呼ぶ際は IAM ロールではなく **Lambda のリソースポリシー** (`aws_lambda_permission`) を使う。`source_arn` 条件を付けないと、同じバス内の別のルールからも同じ Lambda を呼べてしまう。

```hcl
resource "aws_lambda_permission" "allow_eb_processor" {
  statement_id  = "AllowEventBridgeInvokeProcessor"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.processor.arn  # ← 必須
}
```

Step Functions / SQS / SNS をターゲットにする場合は Lambda と異なり **IAM ロール** が必要になる。そのロールの Trust Policy に `events.amazonaws.com` を Principal として設定し、さらに `aws:SourceAccount` 条件で Confused Deputy を防ぐ。

---

### KMS 暗号化の注意点

カスタムバスの KMS 暗号化は 2023年後半に GA。以下の点が引っかかりやすい。

| 注意点 | 詳細 |
|---|---|
| デフォルトバスは KMS 不可 | AWS サービスイベント(`aws.events` ソース)はデフォルトバス経由なので KMS 暗号化できない。暗号化したい場合はカスタムバスへルーティングを挟む必要がある |
| KMS キーポリシー必須 | `events.amazonaws.com` に `kms:GenerateDataKey` と `kms:Decrypt` を付与しないと PutEvents が `KMSInvalidKeyUsage` で失敗する |
| Archive も同じ KMS で暗号化 | アーカイブされたイベントも同じキーで暗号化される。キーを rotate/削除すると古いアーカイブのリプレイが失敗する |
| 削除保留 7 日 | `terraform destroy` 後もキーは 7 日間保留状態。同名で再作成するとコンフリクト |

---

### Confused Deputy 問題 — Scheduler の IAM ロール設計

EventBridge Scheduler の IAM ロールに `aws:SourceAccount` 条件を付けることで、他アカウントが同じ Lambda ARN を使って Scheduler の IAM ロールを悪用する攻撃（Confused Deputy）を防ぐ。

```hcl
# iam.tf 内の Scheduler ロール Trust Policy
Condition = {
  StringEquals = {
    "aws:SourceAccount" = data.aws_caller_identity.me.account_id
  }
}
```

これはサンドボックスの `main.tf` に実装済み。実務では `aws:SourceArn` まで絞るとより厳密になる。

---

### DLQ メッセージの内容分析

DLQ に届いたメッセージには EventBridge が付与するメタデータが含まれる。`requestContext.condition` が `RedrivePolicy` であれば最終リトライ失敗、`ErrorCode` と `ErrorMessage` でエラー種別を特定できる。

```bash
# DLQ のメッセージを受信して確認
aws sqs receive-message \
  --queue-url $(terraform -chdir=terraform/sandboxes/phase7 output -raw dlq_url) \
  --attribute-names All \
  --message-attribute-names All \
  --query 'Messages[0].Body' \
  --output text | python3 -m json.tool
```

CloudWatch Logs Insights で Lambda のログとクロス照合すれば根本原因を特定できる。

---

## 🏗 インフラ応用パターン

### コレオグラフィ vs オーケストレーション — EventBridge と Step Functions の使い分け

EventBridge はコレオグラフィ(各サービスがイベントを聞いて自律的に動く)の基盤として最適。対してオーケストレーション(中央指揮者がフローを制御)は Step Functions の領域。

**コレオグラフィが向く場面**: `order.created` を在庫サービス・通知サービス・分析サービスが独立して購読する場合。イベント発行側を変更せずに購読者を追加できる。デメリットは全体フローが追いにくく、トラブルシュートが難しいこと。

**オーケストレーションが向く場面**: 決済フロー(与信 → 決済 → 在庫確保 → 配送依頼)のように順序保証・補償トランザクション(Saga パターン)が必要な場合。

**実務でよくある 2 層構造**:
```
EventBridge (非同期ファンアウト)
  ├─► Step Functions A (注文オーケストレーション)
  ├─► Step Functions B (在庫オーケストレーション)
  └─► Lambda (通知・分析)
```

---

### ファンアウトパターン — SNS vs EventBridge

```
order.created
  ├─► Rule A → Lambda (在庫更新)
  ├─► Rule B → Lambda (メール送信)
  ├─► Rule C → SQS (非同期集計キュー)
  └─► Rule D → Step Functions (配送フロー)
```

**SNS ファンアウトとの最大の違い**: EventBridge はコンテンツベースフィルタリング(`detail.amount > 10000` など)ができる。SNS はメッセージ属性フィルタのみ。複雑な条件分岐は EventBridge が圧倒的に有利。

```json
// EventBridge ルールのコンテンツフィルタリング例
{
  "source": ["com.example.orders"],
  "detail": {
    "amount": [{ "numeric": [">", 10000] }],
    "region": [{ "prefix": "JP-" }]
  }
}
```

---

### cron 置換パターン — Jenkins/EC2 cron からの移行

EC2 上の Jenkins や cron ジョブを Scheduler + Lambda に移行する際の標準設計:

```
Scheduler (JST 指定)
  └─► Lambda (ETL ジョブ、最大 15 分)
       ├─► S3 (処理済みファイル)
       └─► EventBridge custom bus
            └─► Rule → SNS (完了通知)
                       └─► 運用チーム
```

**15 分を超えるジョブ**: ECS Fargate を Scheduler のターゲットに直接指定できる。コンテナタスクに任意の処理時間を割り当てられる。

```hcl
target {
  arn      = "arn:aws:ecs:ap-northeast-1:123456789012:cluster/batch-cluster"
  role_arn = aws_iam_role.scheduler.arn

  ecs_parameters {
    task_definition_arn = aws_ecs_task_definition.etl.arn
    launch_type         = "FARGATE"
    network_configuration {
      subnets          = var.private_subnet_ids
      security_groups  = [aws_security_group.batch.id]
      assign_public_ip = false
    }
  }
}
```

---

### DLQ パターンの完全形 — 運用まで含めた設計

```
put-events
  └─► EventBridge Rule
       ├─► Lambda (成功)
       └─► (失敗) retry × 2
            └─► DLQ (SQS)
                 └─► CloudWatch Alarm (ApproximateNumberOfMessages > 0)
                      └─► SNS トピック → PagerDuty / Slack
                           └─► 運用者が原因調査 → 手動 or 自動リドライブ
```

DLQ メッセージを確認して Lambda バグを修正したら、**Archive & Replay** で元のカスタムバスに再流しするか、DLQ の `StartMessageMoveTask` API でリドライブする。どちらの方法を使うかはイベントの形式とターゲットのべき等性設計による。

---

### EventBridge + API Gateway — サーバーレス Webhook 受信

外部 SaaS の Webhook を受けるパターン:

```
外部 SaaS
  └─► API Gateway (署名検証 / 認証)
       └─► EventBridge PutEvents (API Gateway 直接統合)
            └─► Lambda / Step Functions
```

API Gateway の直接統合 (Integration Type: AWS) で `events:PutEvents` を呼べる。Lambda を経由しないのでコールドスタートレイテンシがゼロになり、コストも削減できる。ただし API Gateway の Integration Request で EventBridge の入力形式にマッピングする必要がある(Mapping Template または VTL)。

```
# API Gateway → EventBridge の Integration Request (VTL 例)
#set($context.requestOverride.header.X-Amz-Target = "AmazonEventBridge.PutEvents")
{
  "Entries": [{
    "EventBusName": "phase7-bus",
    "Source": "external.webhook",
    "DetailType": "WebhookReceived",
    "Detail": $input.json('$')
  }]
}
```

---

### マルチリージョン冗長 — 現時点の制約と回避策

EventBridge はクロスリージョンの直接ルーティングに **2025年時点では非対応**。間に Lambda または API Destinations を挟む必要がある。

```
us-east-1 bus
  └─► Rule → Lambda (リージョン転送用)
       └─► boto3 client("events", region_name="ap-northeast-1")
            └─► ap-northeast-1 bus
```

または API Destinations で宛先リージョンの EventBridge エンドポイントを HTTP で直接呼ぶ方法もある。AWS がネイティブのクロスリージョン転送を開発中との情報があり、GA されれば Lambda を挟む必要がなくなる。

---

### このプロジェクト(AtCoder復習)での応用イメージ

```
sync_submissions Lambda (Scheduler 毎日 JST 9:00 起動)
  └─► PutEvents → custom-bus
       ├─► Rule: submission.completed, result=AC
       │    └─► Rule A → update_stats Lambda (解法カテゴリ集計)
       │    └─► Rule B → notify Lambda → Slack (AC 通知)
       └─► Rule: submission.completed, result!=AC
            └─► Rule C → weak_point Lambda (苦手問題記録)

Archive (30日保持)
  └─► バグ修正後に過去 AC データを再処理 → 統計再計算
```

サービス追加は EventBridge ルールを1行追加するだけで済み、`sync_submissions` 本体を変更する必要がない。疎結合の恩恵を直感できる構造。
