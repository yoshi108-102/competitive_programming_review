# Phase 3 プレビュー教材: SQS

> プレビュー教材: デモ体験のために先行生成しました。正式な lesson / 振り返りクイズ / 採点は Phase 3 到達時に実施します。

---

## このサービスは何か

Amazon Simple Queue Service（SQS）は、フルマネージドのメッセージキューイングサービス。送信側（Producer）と受信側（Consumer）を疎結合にし、メッセージをキューに一時的に蓄える。

- **インフラ管理不要**: ブローカーの起動・スケーリング・冗長化は AWS が担う
- **2 種類のキュー**:

| 種別 | 順序 | 重複 | スループット |
|------|------|------|-------------|
| Standard Queue | ベストエフォート（順不同になり得る） | 少なくとも 1 回（重複あり） | ほぼ無制限 |
| FIFO Queue | 厳密な FIFO | 正確に 1 回（重複排除） | 最大 3,000 msg/s（バッチ時） |

---

## いつ使うか・使わないか

**使うケース**

- 急なスパイクを吸収するバッファが必要なとき（例: AtCoder の提出が一気に来ても Consumer を詰まらせない）
- Producer と Consumer の処理速度が異なり、互いに独立してスケールさせたいとき
- 処理失敗メッセージを後から検査・再処理したいとき（DLQ と組み合わせ）

**使わないケース**

- 1 ms 以下のリアルタイム応答が必要（→ ElastiCache / in-process queue を検討）
- ファンアウト（1 メッセージを複数 Consumer に届けたい）→ SNS → SQS のファンアウト構成か EventBridge を使う
- 購読モデル（Consumer がイベントをプッシュで受け取りたい）→ SNS または EventBridge

---

## コアコンセプト

### 1. メッセージライフサイクル

```
Producer → SendMessage → [Queue] → ReceiveMessage → In-flight
                                                        ↓
                                            DeleteMessage（処理成功）
                                                        ↓
                                    可視性タイムアウト満了（処理失敗/クラッシュ）
                                                        ↓
                                             Queue に戻る（再配信）
```

### 2. 可視性タイムアウト（Visibility Timeout）

`ReceiveMessage` を呼ぶと、そのメッセージは指定秒数だけ他の Consumer から「見えなくなる」。

- デフォルト 30 秒、最大 12 時間
- Consumer が処理を完了したら必ず `DeleteMessage` を呼ぶ
- 処理が長引く場合は `ChangeMessageVisibility` でタイムアウトを延長する
- タイムアウトが切れると Queue に戻り、`ApproximateReceiveCount` がインクリメントされる

### 3. 最低 1 回配信（at-least-once delivery）

Standard Queue は同一メッセージが複数回配信される可能性がある。Consumer の処理は **冪等（idempotent）** に設計する必要がある（例: 同じ提出 ID を 2 回処理しても結果が変わらないようにする）。

FIFO Queue は `MessageDeduplicationId` を使い正確に 1 回を保証する。

### 4. デッドレターキュー（DLQ）

`maxReceiveCount` を超えたメッセージを退避するキュー。

- 本 Queue と DLQ は **同じ種別**（Standard → Standard、FIFO → FIFO）でなければならない
- DLQ に流れたメッセージはアラームで検知し、根本原因を調査してから再処理する
- DLQ そのものは通常の SQS キューで、ポーリングして中身を確認できる

### 5. ポーリングモデル

SQS はプッシュではなくプル型。Consumer が定期的に `ReceiveMessage` を呼ぶ。

- **ショートポーリング**: 即時に応答（メッセージがなくても空応答）→ API コール数が増えコスト増
- **ロングポーリング**: 最大 20 秒待機してからメッセージ有無を返す → 推奨。`WaitTimeSeconds` で指定

---

## 主要な設定・API・パラメータ

### キュー属性（よく触る）

| 属性 | デフォルト | 説明 |
|------|-----------|------|
| `VisibilityTimeout` | 30 秒 | In-flight 中に隠す時間 |
| `MessageRetentionPeriod` | 4 日（最大 14 日） | Queue に保持する期間 |
| `ReceiveMessageWaitTimeSeconds` | 0（ショート） | ロングポーリングの待機秒数（1〜20） |
| `RedrivePolicy.maxReceiveCount` | — | DLQ 送りになるまでの受信回数 |
| `ContentBasedDeduplication` | false | FIFO 専用: ボディのハッシュで重複排除 |

### 主要 API

```python
import boto3
sqs = boto3.client("sqs", region_name="ap-northeast-1")

# 送信
sqs.send_message(
    QueueUrl=QUEUE_URL,
    MessageBody='{"submission_id": "abc123"}',
    MessageGroupId="group1",          # FIFO のみ必須
    MessageDeduplicationId="abc123",  # FIFO のみ（ContentBasedDeduplication=false 時）
)

# 受信（ロングポーリング）
resp = sqs.receive_message(
    QueueUrl=QUEUE_URL,
    MaxNumberOfMessages=10,           # 最大 10
    WaitTimeSeconds=20,               # ロングポーリング
    VisibilityTimeout=60,             # 受信時に上書き可
)

# 削除
sqs.delete_message(
    QueueUrl=QUEUE_URL,
    ReceiptHandle=msg["ReceiptHandle"],  # 受信時のハンドルが必要
)
```

---

## よくある落とし穴・誤解

### 1. DeleteMessage を忘れる
処理が終わっても `DeleteMessage` を呼ばないと、可視性タイムアウト後に再配信される。Consumer のエラーハンドリングで例外が発生した場合は削除しない（再試行させる）ことが正しい。

### 2. 可視性タイムアウトを短く設定しすぎる
Consumer の平均処理時間より短いと、処理中に他の Consumer が同じメッセージを取得し、二重処理が発生する。タイムアウトは処理時間の余裕を持った値にするか、処理中に定期的に `ChangeMessageVisibility` で延長する。

### 3. Standard / FIFO の混同
FIFO キューの URL は `.fifo` サフィックスを持ち、API 呼び出し時に `MessageGroupId` が必須。Standard と同じコードで動かすと `MissingParameter` エラーになる。

### 4. DLQ を設定しないと毒メッセージが Queue を詰まらせる
繰り返し失敗するメッセージが Queue に留まり続け、Consumer が正常なメッセージを処理できなくなる。本番では必ず DLQ を設定する。

### 5. ロングポーリングをデフォルト（0）のままにする
`WaitTimeSeconds=0` だとメッセージがなくても即座にレスポンスが返り、ポーリングループが高速で回転して不要な API コストが発生する。`WaitTimeSeconds=20` に設定するのが推奨。

---

## このプロジェクト（AtCoder 復習）での使いどころ

### 想定シナリオ: 提出履歴の非同期同期

```
API GW（Lambda: sync_trigger）
    │ SendMessage
    ▼
SQS: submission-sync-queue
    │ ReceiveMessage（ロングポーリング）
    ▼
Lambda: sync_submissions（atcoder_client → DynamoDB）
    │ 失敗（レート制限等）
    ▼
DLQ: submission-sync-dlq
```

- **AtCoder のレート制限**: AtCoder API が 429 を返した場合、Lambda はメッセージを削除せず終了 → 可視性タイムアウト後にリトライ
- **スパイク吸収**: ユーザーが一斉にページを開いても、Queue がリクエストをバッファし Lambda の同時実行数を抑制
- **DLQ 監視**: CloudWatch アラームで DLQ のメッセージ数 > 0 を検知 → SNS メール通知

### 現行実装（Phase 1）との接続点

Phase 1 では `sync_submissions` Lambda を API GW から同期呼び出ししている。これを SQS 経由の非同期に切り替えることで:
- フロントエンドはキューへの投入（即時 200）だけを行い、同期結果をポーリングまたは WebSocket で受け取る
- Lambda のタイムアウト 29 秒制限に縛られなくなる

---

## デモで体験したこと

`docs/learning/phase3/demo/index.html` のデモでは、Producer / Queue / In-flight / Consumer / DLQ の 5 レーンを横並びで視覚化している。

「メッセージ送信」ボタンを押すと Queue にカードが積まれ、「ポーリング」で 1 件が In-flight レーンに移動するとともに可視性タイムアウトのカウントバーが減り始める。「処理成功」を押せば `DeleteMessage` に相当してカードが消え、「処理失敗」のまま放置するとバーが 0 になった瞬間にカードが Queue へ戻り `receiveCount` が増加する。`receiveCount` が `maxReceiveCount` を超えると自動的に DLQ レーンへ移動し、本キューが詰まらない仕組みを目で確認できる。Standard / FIFO トグルを切り替えると、FIFO では投入順にカードが取り出される順序保証が働くことが分かる。

---

## 公式ドキュメント（出典）

- Amazon SQS デベロッパーガイド — ようこそ: <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html>（閲覧日 2026-05-31）
- 可視性タイムアウト: <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html>（閲覧日 2026-05-31）
- デッドレターキュー: <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html>（閲覧日 2026-05-31）
- FIFO キュー: <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/FIFO-queues.html>（閲覧日 2026-05-31）

---

## 🧭 関連・発展サービス

### SNS + SQS ファンアウトパターン

「1 つの SNS トピックを複数の SQS キューが購読する」構成がファンアウト。同じイベントをメール通知用・DB 書き込み用・分析用など複数の下流へ並列で届けられる。

```
SNS Topic
  ├── SQS Queue A → Lambda(メール送信)
  ├── SQS Queue B → Lambda(DynamoDB 書き込み)
  └── SQS Queue C → Kinesis Data Firehose → S3(分析)
```

**なぜ SNS から Lambda を直結しないのか**: SNS → Lambda の直接接続は再試行ポリシーが 3 回のみで、Lambda がスロットルすると SNS がメッセージを捨てる。SNS → SQS → Lambda にすれば SQS がバッファになり、スロットル中もメッセージは溜まり安全に再試行できる。これを「SQS で Lambda を保護する」と呼ぶ。

**Terraform での SNS → SQS サブスクリプション:**

```hcl
resource "aws_sns_topic_subscription" "to_sqs" {
  topic_arn            = aws_sns_topic.events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.main.arn
  raw_message_delivery = true   # SNS エンベロープを外す。false だと body が二重 JSON になる
}

# SQS キューポリシーにも SNS からの SendMessage を許可する必要がある
resource "aws_sqs_queue_policy" "allow_sns" {
  queue_url = aws_sqs_queue.main.id
  policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.main.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.events.arn } }
    }]
  })
}
```

つまずきポイント: `raw_message_delivery = false`(デフォルト)だと SQS の body が SNS エンベロープで包まれた二重 JSON になる。Lambda 側で `json.loads(json.loads(record["body"])["Message"])` という二重パースが必要になり混乱しやすい。ファンアウト構成では `raw_message_delivery = true` にしておくのが素直。

---

### EventBridge Pipes — ノーコードのキュー配線

2022 年 GA の「接続の糊」。SQS → Filter → Enrichment(Lambda/API GW) → Target(Step Functions / EventBridge Bus / Kinesis 等) をコードなしで繋ぐ。

```
SQS(Source)
  → [Filter] JSONPath でメッセージを絞り込み
  → [Enrichment] Lambda で内容補完(オプション)
  → Target(Step Functions StartExecution, など)
```

**いつ使うか:**
- SQS メッセージを直接 Step Functions に流したいとき(以前は中継 Lambda が必要だった)
- 特定フィールドを持つメッセージだけ下流に通したい(Filter)
- Lambda を書かずにルーティングを完結させたい

**つまずきポイント**: Enrichment Lambda の返り値フォーマットが合わないとサイレントに落ちる。CloudWatch Logs for Pipes を有効化していないとデバッグ不能になる。また 2024 時点で FIFO キューはソースに使えない制限がある。

---

### Lambda イベントソースマッピング — バッチとスケーリングの深掘り

```hcl
resource "aws_lambda_event_source_mapping" "sqs_to_consumer" {
  event_source_arn                   = aws_sqs_queue.main.arn
  function_name                      = aws_lambda_function.consumer.arn
  batch_size                         = 10       # 標準キュー: 1〜10000 / FIFO: 1〜10
  maximum_batching_window_in_seconds = 20       # 最大 300 秒。閑散期のコスト削減に有効
  function_response_types            = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = 10   # Lambda 同時実行上限。RDS 等の接続数爆発を防ぐ
  }
}
```

**スケーリングの仕組み**: Lambda は内部でポーラーを管理し、メッセージが積まれると最初 5 本から始まり 60 秒ごとに最大 300 本まで増える。`maximum_concurrency` を設定しないと一気にスケールアウトして下流 DB の接続数が爆発する。RDS 連携時は必ず設定する。

**バックプレッシャ**: Consumer が遅い場合 `ApproximateNumberOfMessagesVisible` が増加し続ける。これをアラームで検知し、Producer 側の送信レートを下げる制御がバックプレッシャ。SQS が自然なバッファになることでシステム全体を守る。

---

### FIFO キューと MessageGroupId の設計

```hcl
resource "aws_sqs_queue" "fifo_main" {
  name                        = "${var.prefix}-main.fifo"   # .fifo サフィックス必須
  fifo_queue                  = true
  content_based_deduplication = true   # MessageBody の SHA-256 で重複排除
  kms_master_key_id           = aws_kms_key.sqs.id
}
```

`MessageGroupId` を `user_id` にすると「同一ユーザーの処理は順序通り」が保証できる。GroupId が偏ると(全件が同一 GroupId)スループットが 300 TPS に制限される。分散させると並列処理できるが、GroupId の設計はドメイン分析が必要。

---

### Step Functions 委譲パターン

Consumer Lambda を「キューからメッセージを取り出して Step Functions を kick するだけ」のシンプルな役割にすると、Lambda の 15 分制限を超える長時間ワークフローを扱える。

```python
import boto3, json, os
sfn = boto3.client("stepfunctions")

def handler(event, context):
    for record in event["Records"]:
        sfn.start_execution(
            stateMachineArn=os.environ["STATE_MACHINE_ARN"],
            input=record["body"]
        )
```

---

## 🛡 セキュリティ課題と対策

### キューポリシーの2層構造と落とし穴

SQS にはリソースベースポリシー(キューポリシー)と IAM ロールの 2 層がある。クロスアカウントの場合は両方の Allow が必要。同一アカウントでも、キューポリシーが `Principal: "*"` だと IAM 制御をすり抜けて誰でもアクセスできる。

**絶対にやってはいけない例:**

```json
{
  "Effect": "Allow",
  "Principal": "*",
  "Action": "sqs:*",
  "Resource": "*"
}
```

これは全世界から全操作を許可するゾンビポリシー。スパム送信やコスト爆発の原因になる。`Principal` は必ず特定の ARN またはサービスに絞る。

**Condition を活用した制限(Confused Deputy 対策):**

```json
{
  "Effect": "Allow",
  "Principal": { "Service": "lambda.amazonaws.com" },
  "Action": "sqs:SendMessage",
  "Resource": "arn:aws:sqs:ap-northeast-1:123456789012:phase3-main",
  "Condition": {
    "ArnLike": { "aws:SourceArn": "arn:aws:lambda:...:function:phase3-producer" },
    "StringEquals": { "aws:SourceAccount": "123456789012" }
  }
}
```

`aws:SourceAccount` を付けることで ARN スプーフィング(Confused Deputy 問題)を緩和できる。

---

### SSE-SQS vs SSE-KMS(CMK) の選択

| | SSE-SQS | SSE-KMS(CMK) |
|---|---|---|
| 管理 | AWS が自動 | ユーザーが管理 |
| コスト | 無料 | KMS API コール料金($0.03/10000 回) |
| CloudTrail 記録 | なし | kms:Decrypt 等が記録される |
| クロスアカウント | 不可 | 可能(キーポリシー調整) |
| キーローテーション | AWS 管理 | 年次自動 or 手動 |

sandbox では CMK を使い「KMS コストと CloudTrail ログ」を実体験する。本番でも個人情報・決済情報は CMK 必須、内部通知程度なら SSE-SQS で十分。

**CMK コスト計算の勘所**: 送受信 1000 件/日なら `GenerateDataKey` 1000 + `Decrypt` 1000 = 2000 コール/日 → 月 60000 コール → $0.18/月。SQS 本体コスト($0.40/百万)より KMS が高くなるケースは稀だが、大量送信時は試算する。

**SSE-KMS を使う場合の IAM 忘れがち項目:**
- Producer ロール: `kms:GenerateDataKey`(書き込み暗号化) + `kms:Decrypt`
- Consumer ロール: `kms:Decrypt`(読み取り復号)
- どちらかを忘れると `KMS.KmsDisabledException` または `AccessDenied` が発生する

---

### 毒メッセージ(Poison Message)対策と DLQ 運用

Consumer が特定メッセージを永遠に処理できない場合、`maxReceiveCount` 回失敗後に DLQ へ退避される。DLQ のメッセージを分析して原因を修正してから redrive(再送)する運用が必要。

**DLQ のメッセージを本体キューに redrive:**

```bash
aws sqs start-message-move-task \
  --source-arn "arn:aws:sqs:ap-northeast-1:123456789012:phase3-dlq" \
  --destination-arn "arn:aws:sqs:ap-northeast-1:123456789012:phase3-main" \
  --max-number-of-messages-per-second 5   # 本体への負荷を制御
```

**注意**: redrive したメッセージは `ReceiveCount` がリセットされない。DLQ 調査中に receive されていると `maxReceiveCount` に達してすぐ再 DLQ される場合がある。修正が確実なときだけ redrive する。

**DLQ アラーム設定(実運用の最低ライン):**

```hcl
resource "aws_cloudwatch_metric_alarm" "dlq_visible" {
  alarm_name          = "${var.prefix}-dlq-messages"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  statistic           = "Maximum"
  alarm_description   = "DLQ にメッセージが入った = 処理失敗発生"
}
```

DLQ が無音のままメッセージで埋まるのは最悪のパターン。1 件でも入ったらアラームを上げる。

---

### 冪等処理の実装

Standard Queue は「少なくとも 1 回配信」なので同じメッセージが複数回届く可能性がある。Consumer は冪等でなければならない。

**DynamoDB 条件付き Put でアトミックな重複排除:**

```python
from botocore.exceptions import ClientError
import boto3, json, time

dynamodb = boto3.resource("dynamodb")
dedup = dynamodb.Table("phase3-dedup")

def handler(event, context):
    for record in event["Records"]:
        msg_id = record["messageId"]
        try:
            dedup.put_item(
                Item={"message_id": msg_id, "ttl": int(time.time()) + 86400},
                ConditionExpression="attribute_not_exists(message_id)"
            )
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                print(f"Duplicate {msg_id}, skipping")
                continue
            raise
        # メイン処理
        process(json.loads(record["body"]))
```

`ConditionExpression` で「insert か skip か」をアトミックに判定できる。複数 Lambda が同時に同じメッセージを処理しようとするレースコンディションに対応できる。TTL を設定してテーブルを肥大化させないことも重要。

---

### VPC エンドポイントによるパブリック通信の遮断

Lambda を VPC 内に置き、SQS VPC エンドポイント経由でアクセスするとトラフィックがパブリックインターネットに出ない。

```hcl
resource "aws_vpc_endpoint" "sqs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.sqs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.sqs_endpoint.id]
  private_dns_enabled = true
}
```

トレードオフ: Lambda の VPC 配置はコールドスタートが増える(ENI 割り当て時間)。セキュリティ要件が厳しい場合のみ採用し、SnapStart や Provisioned Concurrency と組み合わせて緩和する。

---

## 🏗 インフラ応用パターン

### 疎結合とバックプレッシャの実践

**密結合(悪い例):**

```
API Gateway → Lambda(同期) → 外部 API(遅い/不安定)
```

外部 API が遅いと Lambda がタイムアウト → API Gateway が 504 → ユーザーはエラー。

**疎結合(SQS で解決):**

```
API Gateway → Lambda(Producer, 即時 202 Accepted)
                    ↓ SendMessage
              SQS キュー
                    ↓ ReceiveMessage
              Lambda(Consumer, 非同期) → 外部 API をゆっくり叩く
```

ユーザーへの即時応答と実処理を分離。EC サイトの注文受付、画像処理、メール送信など「すぐ返事して後で処理」できるものはすべて候補になる。フロントエンドはステータスをポーリングまたは WebSocket で受け取る設計にする。

---

### DLQ + Redrive の運用自動化フロー

```
DLQ にメッセージが入る
→ CloudWatch Alarm (Visible >= 1, period=300)
→ SNS → Lambda(アラートハンドラ)
→ Slack 通知 + Jira チケット自動作成
→ オンコール担当が DLQ を調査(原因特定・修正)
→ aws sqs start-message-move-task で redrive
```

この一連の流れを自動化することで「DLQ が静かに埋まる」事故を防ぐ。SNS → Lambda のアラートハンドラは `boto3.client("sqs").receive_message` で DLQ の最初の数件を取得してサンプルをメッセージに含めると調査が速い。

---

### FIFO + MessageGroupId で注文状態遷移を順序保証

EC サイトの注文状態遷移:

```
注文作成 → 在庫引当 → 決済 → 配送手配
```

`order_id` を `MessageGroupId` にした FIFO キューで処理すると「同一注文の処理は必ず順序通り」が保証できる。異なる注文は別 GroupId なので並列処理できる。

**高スループットモード(3000 TPS 対応):**

```hcl
resource "aws_sqs_queue" "orders_fifo" {
  name                         = "${var.prefix}-orders.fifo"
  fifo_queue                   = true
  deduplication_scope          = "messageGroup"
  fifo_throughput_limit        = "perMessageGroupId"
  # この2つのセットで高スループットモード有効化
  content_based_deduplication  = true
  kms_master_key_id            = aws_kms_key.sqs.id
}
```

通常 FIFO の上限は 300 TPS。大規模 EC では高スループットモードで 3000 TPS まで引き上げる。GroupId の分散設計(ユーザー ID や注文 ID など)が前提条件。

---

### コスト最適化の勘所

| 最適化ポイント | 具体的な設定 | 効果 |
|---|---|---|
| Long Polling | `ReceiveMessageWaitTimeSeconds = 20` | 空 poll を削減、API コスト削減 |
| バッチ送信 | `send_message_batch`(最大 10 件 / API コール) | コスト最大 1/10 |
| バッチ受信 | `batch_size = 10` + バッチウィンドウ | Lambda 起動コスト削減 |
| SSE-SQS | 小規模なら CMK → SSE-SQS に変更 | KMS コスト節約 |
| メッセージサイズ削減 | 大ペイロードは S3 に置いて URL だけ SQS に流す | 256KB 制限の回避 |

**S3 Extended Client パターン(256KB を超えるペイロード):**

```python
import boto3, json, uuid

s3  = boto3.client("s3")
sqs = boto3.client("sqs")
BUCKET = "phase3-payloads"

def send_large_message(queue_url: str, payload: dict):
    key = f"payloads/{uuid.uuid4()}.json"
    s3.put_object(Bucket=BUCKET, Key=key, Body=json.dumps(payload))
    sqs.send_message(
        QueueUrl=queue_url,
        MessageBody=json.dumps({"s3_bucket": BUCKET, "s3_key": key})
    )

def receive_large_message(record: dict) -> dict:
    ref = json.loads(record["body"])
    obj = s3.get_object(Bucket=ref["s3_bucket"], Key=ref["s3_key"])
    return json.loads(obj["Body"].read())
```

注意点: S3 オブジェクトのライフサイクルポリシーを設定して、処理後に自動削除しないとストレージが肥大化する。

---

### Lambda 同時実行制御でダウンストリームを守る

Consumer Lambda がスケールアウトしすぎると RDS・Redis・外部 API への同時接続が爆発する。

```hcl
# イベントソースマッピングで同時実行を制限
resource "aws_lambda_event_source_mapping" "sqs_to_consumer" {
  event_source_arn = aws_sqs_queue.main.arn
  function_name    = aws_lambda_function.consumer.arn
  batch_size       = 10

  scaling_config {
    maximum_concurrency = 10   # 同時実行 Lambda 数の上限
  }

  function_response_types = ["ReportBatchItemFailures"]
}
```

`maximum_concurrency` を設定すると、Lambda はそれ以上スケールしない代わりに SQS にメッセージが溜まる。この溜まりを `ApproximateNumberOfMessagesVisible` で監視し、Consumer 処理の遅延や異常を検知する。SQS がバッファとして機能するため、メッセージはロストしない。

---

**公式ドキュメント(発展節)**

- SNS ファンアウト: <https://docs.aws.amazon.com/sns/latest/dg/sns-sqs-as-subscriber.html>
- EventBridge Pipes: <https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-pipes.html>
- Lambda × SQS イベントソースマッピング: <https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html>
- SQS FIFO 高スループットモード: <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/high-throughput-fifo.html>
- SQS セキュリティベストプラクティス: <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-security-best-practices.html>
- KMS + SQS: <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-server-side-encryption.html>
