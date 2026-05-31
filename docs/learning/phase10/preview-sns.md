# Phase 10 プレビュー教材: SNS — Pub/Sub ファンアウト通知

> プレビュー教材: デモ体験のために先行生成しました。正式な lesson / 振り返りクイズ / 採点は Phase 10 到達時に実施します。

---

## このサービスは何か

Amazon Simple Notification Service (SNS) は **フルマネージドな Pub/Sub メッセージングサービス**。メッセージを送る側（Publisher）はトピックに 1 回 Publish するだけで、そのトピックを購読しているすべての Subscriber に同時配信（ファンアウト）される。

| 項目 | 内容 |
|---|---|
| 配信モデル | Push 型（SNS がエンドポイントへ能動的に送る） |
| 対応プロトコル | Email / SMS / HTTP(S) / SQS / Lambda / Kinesis Data Firehose / Mobile Push |
| トピック種別 | Standard（高スループット、ベストエフォート順序） / FIFO（厳密な順序・重複排除） |
| メッセージサイズ上限 | 256 KB |

SQS との根本的な違いは配信の方向性にある。SNS は Publisher → 複数 Subscriber への **扇形一方通行**。SQS はキューにためて Consumer が **取り出しに来る** 。

---

## いつ使うか・使わないか

**使う場面**

- 1 つのイベントを複数のシステムへ同時に伝えたい（例: 注文完了 → メール通知 & 在庫更新 & ログ記録）
- アプリケーション間を疎結合にしたい（Pub/Sub でインタフェースを統一）
- モバイルプッシュ通知を大量配信したい（APNs / FCM を束ねられる）
- SQS と組み合わせたファンアウトで各サービスに独立したキューを持たせたい

**使わない場面**

- メッセージを一定期間保持して後から処理したい → **SQS** を使う
- ストリーム的に大量データを処理したい → **Kinesis** を使う
- 特定の 1 対 1 通信で十分な場合（SNS は 1 対多が前提）
- 応答（Response）が必要な RPC 的な処理 → SNS は Fire-and-Forget

---

## コアコンセプト

### Topic

Publisher がメッセージを送り込む論理チャネル。ARN で識別される。

```
arn:aws:sns:ap-northeast-1:123456789012:MyTopic
```

Standard Topic と FIFO Topic の 2 種類がある。FIFO は `.fifo` サフィックスが必須。

### Subscription

Topic と配信先エンドポイントを結びつける設定。1 つの Topic に複数の Subscription を持てる。

| プロトコル | 用途例 |
|---|---|
| `email` | 運用アラートを担当者メールへ |
| `sqs` | 非同期バッファ経由でマイクロサービスへ |
| `lambda` | イベント駆動でサーバーレス処理 |
| `https` | 外部 Webhook エンドポイントへ |
| `sms` | 緊急通知を SMS で |

Subscription 作成後、`email` / `http` / `https` プロトコルは **確認（confirm）** が必要。SQS / Lambda は自動で確認される。

### メッセージ構造

```json
{
  "Message": "本文テキスト",
  "MessageAttributes": {
    "type": {
      "DataType": "String",
      "StringValue": "order"
    },
    "priority": {
      "DataType": "Number",
      "StringValue": "1"
    }
  }
}
```

`MessageAttributes` はフィルタリングに使用する。

### ファンアウトパターン

```
          ┌─────────────┐
          │  SNS Topic  │
          └──────┬──────┘
     ┌───────────┼───────────┐
     ▼           ▼           ▼
  SQS Queue  SQS Queue   Lambda
 (在庫更新)  (メール配信) (監査ログ)
```

Publisher は Topic に Publish するだけ。各サービスが独立したキューを持つことで、一方の障害が他方に影響しない疎結合アーキテクチャを実現する。

---

## 主要な設定・API・パラメータ

### Publish API

```python
import boto3

sns = boto3.client("sns", region_name="ap-northeast-1")

response = sns.publish(
    TopicArn="arn:aws:sns:ap-northeast-1:123456789012:MyTopic",
    Message="新しい提出が追加されました",
    Subject="AtCoder 提出通知",          # Email の件名（任意）
    MessageAttributes={
        "type": {
            "DataType": "String",
            "StringValue": "submission"
        }
    }
)
# response["MessageId"] で配信 ID を確認
```

### CreateTopic

```python
sns.create_topic(
    Name="AtCoderSubmissions",           # FIFO の場合は "AtCoderSubmissions.fifo"
    Attributes={
        "FifoTopic": "false",            # FIFO にする場合は "true"
        "ContentBasedDeduplication": "false"
    }
)
```

### Subscribe

```python
sns.subscribe(
    TopicArn="arn:aws:sns:...",
    Protocol="sqs",
    Endpoint="arn:aws:sqs:ap-northeast-1:123456789012:MyQueue",
    Attributes={
        "FilterPolicy": '{"type": ["submission", "order"]}'
    }
)
```

### フィルタポリシー (FilterPolicy)

Subscription 属性として JSON 文字列で設定する。

```json
{
  "type": ["order"],
  "priority": [{"numeric": [">=", 1]}]
}
```

- 配列値はいずれかに一致すれば OK（OR 条件）
- 複数キーはすべてが一致する必要がある（AND 条件）
- フィルタにマッチしないメッセージはその Subscription には配信されない（課金もされない）

### FIFO トピック固有パラメータ

| パラメータ | 説明 |
|---|---|
| `MessageGroupId` | 同じグループ内の順序を保証するキー |
| `MessageDeduplicationId` | 重複排除 ID（ContentBasedDeduplication が false の場合必須） |

FIFO Topic に Subscribe できるのは **FIFO SQS キューのみ**。Email / SMS / Lambda などは FIFO Topic には使えない。

---

## よくある落とし穴・誤解

**1. SNS で「メッセージを保持できる」と思い込む**
SNS はメッセージを保持しない。配信失敗時のリトライはあるが、永続化は SQS の役割。確実に処理させたい場合は SNS → SQS → Consumer の構成にする。

**2. Email / HTTP Subscription の確認を忘れる**
Subscribe 直後は `PendingConfirmation` 状態。確認メールのリンクをクリックしないと配信されない。IaC で自動化しにくい点に注意。

**3. フィルタポリシーが "Message" 本文に効かないと気づかない**
FilterPolicy は `MessageAttributes` に対して機能する。メッセージ本文（JSON でも）のフィールドに対してはデフォルトではフィルタできない。`FilterPolicyScope: "MessageBody"` を設定すれば本文ベースにできる（2023年〜）。

**4. FIFO Topic + Lambda の組み合わせは不可**
FIFO Topic は SQS FIFO キューのみ Subscription 可能。Lambda を使いたい場合は SNS(Standard) → SQS FIFO → Lambda のチェーンにする必要がある。

**5. クロスアカウント配信時のポリシー漏れ**
別アカウントの SQS に配信する場合、SQS 側のアクセスポリシーで SNS からの `SendMessage` を明示的に許可しないと失敗する。

**6. メッセージサイズの 256 KB 制限**
大きなペイロードを送りたい場合は S3 に保存して S3 オブジェクトの参照（URL/ARN）だけを SNS で配信するパターン（SNS Extended Client Library）を使う。

---

## このプロジェクト（AtCoder 復習）での使いどころ

現在の Phase 1 MVP は Lambda が直接処理を完結させているが、Phase 10 では非同期通知とファンアウトを導入する場面として SNS が活きる。

| ユースケース | 構成案 |
|---|---|
| 提出データ取得完了の通知 | `sync_submissions` Lambda が SNS Publish → Email で管理者通知 & SQS で後続処理 |
| 学習達成アラート | 正解率閾値を超えたら SNS → Email / SMS でユーザーへ通知 |
| バックエンド間ファンアウト | 採点完了イベントを SNS → SQS(分析用) + SQS(ランキング更新用) に同時配信 |

具体的には `sync_submissions/handler.py` の完了後に `sns.publish()` を 1 行追加するだけで、Email 通知と SQS バッファへの同時配信が実現できる。Publisher 側のコードは 1 箇所のまま、Subscriber を増やすだけでスケールする点が SNS の最大の利点。

---

## デモで体験したこと

`docs/learning/phase10/demo/index.html` では、中央の SNS Topic から Email / SMS / SQS / Lambda / HTTP の各 Subscription ノードへメッセージがファンアウトするアニメーションを確認した。「発行 (Publish)」を押すと `.flow-node.active → ok` の状態遷移で全 Subscriber への配信が可視化され、Pub/Sub が Push 型であることが直感的に理解できる。

各 Subscription に付属するフィルタポリシーエディタで `{"type": ["order"]}` のように属性条件を設定すると、属性が一致する Subscriber にのみ配信アニメーションが流れる。これにより「Publisher 側は何も変えなくても Subscriber 側のフィルタ設定で受信を制御できる」という非対称な責務分担が体験できた。SNS → 複数 SQS のファンアウト構成では各キューノードが独立して `.ok` になる様子から、一方のキューが詰まっても他方に影響しない疎結合の実感が得られた。

---

## 公式ドキュメント（出典）

- Amazon SNS とは何ですか — <https://docs.aws.amazon.com/sns/latest/dg/welcome.html>（閲覧日 2026-05-31）
- Amazon SNS の一般的なシナリオ — <https://docs.aws.amazon.com/sns/latest/dg/sns-common-scenarios.html>（閲覧日 2026-05-31）
- Amazon SNS メッセージフィルタリング — <https://docs.aws.amazon.com/sns/latest/dg/sns-message-filtering.html>（閲覧日 2026-05-31）
- Amazon SNS FIFO トピック — <https://docs.aws.amazon.com/sns/latest/dg/sns-fifo-topics.html>（閲覧日 2026-05-31）

---

## 関連・発展サービス

### SNS → SQS ファンアウトの本質

SNS の最大価値は「1 回の `Publish` で N 個のエンドポイントに同時配信できる」点にある。SQS 単体ではコンシューマが 1 本のポーリングを占有するため、同じメッセージを複数サービスが並列処理できない。SNS をハブにすることでキュー数を増やし、コンシューマを独立してスケールさせられる。

```
                ┌── SQS(fulfillment) ── Lambda/EC2 Worker
SNS Topic ──── ┼── SQS(analytics)   ── Kinesis Firehose Consumer
                ├── SQS(wholesale)   ── B2B 連携 Worker
                └── Lambda(express)  ── 即時通知(Push)
```

**設計の勘所**:
- SQS の `visibility_timeout` は Lambda の `timeout` の **6 倍以上**に設定するのが AWS 推奨。Lambda が処理中にタイムアウトするとメッセージが再表示され二重処理になる。
- 各キューが独立しているため、analytics キューが詰まっても fulfillment キューには影響しない。障害が局所化されることが疎結合の最大のメリット。

### SNS → Kinesis Data Firehose

`protocol = "firehose"` で購読できる(2022 年 GA)。大量イベントを S3 に直送しつつ Athena で分析するパターン。Lambda 変換を噛ませなくてよいため運用コストが低い。

```
SNS Topic
  └── Firehose Delivery Stream
        ├── S3 (Parquet 変換 / Glue Data Catalog 統合)
        └── (オプション) OpenSearch / Redshift Serverless
```

Terraform では `protocol = "firehose"` + `subscription_role_arn` を指定する。SNS が Firehose へ書き込む際のプリンシパルは `sns.amazonaws.com` になるので、Firehose の信頼ポリシーに `sns.amazonaws.com` を追加し忘れると `InvalidParameter: Invalid parameter: RoleArn` が出て詰まる。

```hcl
resource "aws_sns_topic_subscription" "to_firehose" {
  topic_arn            = aws_sns_topic.orders.arn
  protocol             = "firehose"
  endpoint             = aws_kinesis_firehose_delivery_stream.s3.arn
  subscription_role_arn = aws_iam_role.sns_to_firehose.arn
}
```

### FIFO トピック ― いつ使うか・何が変わるか

**いつ使うか**: 「在庫引き当て → 出荷指示」のように、後続の処理順序が業務的に意味を持つ場合。標準トピックは順序を保証しない。

**制約と注意**:

| 項目 | 標準トピック | FIFO トピック |
|---|---|---|
| スループット | 実質無制限 | 300 msg/sec(バッチで 3,000 msg/sec) |
| 購読可能プロトコル | 全プロトコル | FIFO SQS / Lambda のみ |
| 重複排除 | なし | コンテンツベース or `MessageDeduplicationId` |
| 順序保証 | なし | `MessageGroupId` 単位で保証 |

FIFO + SSE-KMS を組み合わせると KMS API 呼び出しがスループット制限に影響するため、KMS のリクエストレートクォータ(`GenerateDataKey` / `Decrypt`)をあらかじめ Service Quotas で確認しておくこと。

### EventBridge との使い分け

SNS と EventBridge はどちらも Pub/Sub 的に使えるが、適切な使い所が異なる。

| 観点 | SNS | EventBridge |
|---|---|---|
| ルーティング粒度 | MessageAttributes ベース | JSON 全フィールド(ネスト可) |
| ターゲット上限 | 購読数に比例(実質無制限) | ルールごとに最大 5 ターゲット |
| スキーマレジストリ | なし | あり(コード生成も可) |
| クロスアカウント | トピックポリシーで可 | バス間フォワード |
| SaaS 統合 | なし | Shopify / Zendesk 等の Partner Event Source |
| 遅延 | 低(ミリ秒) | 低〜中(ミリ秒〜数百 ms) |

**実務の判断基準**: アプリ内部の単純なファンアウト(SQS/Lambda へ配信)なら SNS が軽量で最適。SaaS イベントの取り込み・CloudWatch/Config/CodePipeline のイベント処理・複雑なルーティングなら EventBridge。両者を組み合わせた「EventBridge → SNS → SQS」の multi-hop も実在する。

### モバイルプッシュ / SMS / Email の落とし穴

SNS はモバイル通知(APNs/FCM)・SMS・Email も購読プロトコルとして持つ。本格利用前に知っておくべき落とし穴:

- **SMS sandbox**: デフォルトでは sandbox モードで、事前登録した電話番号へしか送れない。本番昇格(Production Access リクエスト)が必要。
- **SMS コスト爆発リスク**: 東京リージョン向け SMS は $0.07〜/通。ループバグで数万通送ると数十万円の請求が来る。`SMSMonthToDateSpentUSD` に月次アラームを必ず設定する。
- **Email の IaC 問題**: `protocol = "email"` は確認メールのリンクをクリックしないと有効にならないため、完全自動化が崩れる。本番では Email を Lambda 経由の Slack Webhook に置き換えるのがベストプラクティス。

---

## セキュリティ課題と対策

### トピックポリシーの設計 ― デフォルトは過剰権限

SNS トピックのデフォルトポリシーは `Principal: "*"` + `Condition: {AWS:SourceOwner: "<account_id>"}` で同一アカウント内の全 IAM エンティティに Publish/Subscribe を許可する。これは過剰。推奨設定は Publish 許可プリンシパルを明示列挙し、それ以外はデフォルト拒否。

```json
{
  "Statement": [
    {
      "Sid": "DenyPublicPublish",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "sns:Publish",
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:PrincipalArn": [
            "arn:aws:iam::123456789012:role/phase10-publisher"
          ]
        }
      }
    }
  ]
}
```

Terraform では `aws_iam_policy_document` + `data.json` を `aws_sns_topic` の `policy` に渡す。

### SSE-KMS の二重壁 ― つまずきポイント

SNS の SSE-KMS は「SNS インフラ内に静止している間」のみ暗号化する。SNS → SQS の転送時は SQS 側のキーで再暗号化される。このとき **SNS サービスプリンシパル** が SQS キーに対して `GenerateDataKey` を呼ぶため、KMS キーポリシーには `sns.amazonaws.com` と `sqs.amazonaws.com` の両方を許可しなければならない。片方だけだと `KMS.KMSDisabledException` で購読が無音に失敗する。

```hcl
# キーポリシーに両プリンシパルを列挙する(phase10/main.tf の実装例)
{
  Sid    = "SNSEncrypt"
  Effect = "Allow"
  Principal = { Service = "sns.amazonaws.com" }
  Action   = ["kms:GenerateDataKey*", "kms:Decrypt"]
  Resource = "*"
},
{
  Sid    = "SQSEncrypt"
  Effect = "Allow"
  Principal = { Service = "sqs.amazonaws.com" }
  Action   = ["kms:GenerateDataKey*", "kms:Decrypt"]
  Resource = "*"
}
```

症状が `NumberOfNotificationsFailed` の増加として現れるため、このメトリクスの監視は必須。

### フィルタポリシーはアクセス制御ではない

よくある誤解: 「フィルタにかからないメッセージはあのキューに届かないから安全」。

フィルタポリシーは **配信最適化** の機能であり、アクセス制御ではない。本当にアクセスを制限したいなら、SQS キューポリシーの `Condition` で `aws:SourceArn` を特定の SNS トピックに限定する。

```json
{
  "Condition": {
    "ArnEquals": {
      "aws:SourceArn": "arn:aws:sns:ap-northeast-1:123456789012:phase10-orders"
    }
  }
}
```

### 購読 DLQ ― 「無音の失敗」問題

SNS が SQS/Lambda への配信を 3 回リトライして失敗すると、デフォルトではメッセージが**完全に消える**。これを「無音の失敗(silent failure)」と呼ぶ。

DLQ は購読(サブスクリプション)ごとに独立して設定する(トピックレベルではなく)。Terraform では `redrive_policy` を `aws_sns_topic_subscription` に付ける。

```hcl
resource "aws_sns_topic_subscription" "fulfillment" {
  ...
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq["fulfillment"].arn
  })
}
```

本番では `ApproximateNumberOfMessagesVisible > 0` で DLQ アラームを仕掛け、PagerDuty/Slack に通知する運用が必須。

### クロスアカウント購読のリスク

別アカウントの SNS トピックを購読する場合、トピックポリシーに他アカウントの ARN を追加する必要がある。ソースアカウントを `Condition` で固定しないと、そのアカウントの任意ロールが Publish できてしまう。

```json
"Condition": {
  "StringEquals": { "aws:SourceAccount": "999999999999" },
  "ArnLike":      { "aws:SourceArn": "arn:aws:sns:*:999999999999:trusted-topic" }
}
```

必ずアカウント ID と ARN パターンの両方を指定して二重に縛ること。

### VPC エンドポイントでプライベート通信

VPC 内の Lambda/EC2 から SNS に Publish するとき、デフォルトではインターネット経由(NAT Gateway)が必要になる。VPC エンドポイント(Interface 型)を使えば AWS バックボーンネットワーク内に閉じた通信になり、NAT Gateway コストを削減しつつセキュリティも向上する。

```hcl
resource "aws_vpc_endpoint" "sns" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.sns"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
}
```

VPC エンドポイントポリシーで `sns:Publish` の対象トピック ARN を絞ることで、エンドポイントを経由できるアクションをさらに限定できる。

---

## インフラ応用パターン

### パターン A: 通知基盤(Operational Alerting)

CloudWatch Alarm → SNS → 複数出口のパターンは AWS 監視の定番構成。

```
CloudWatch Alarm
  └── SNS Topic (alert-hub)
        ├── Email 購読    ─ on-call エンジニア
        ├── SQS 購読      ─ ITSM チケット自動起票 Lambda
        └── Lambda 購読   ─ Slack Webhook 通知
```

**実装の勘所**:
- CloudWatch Alarm が SNS に Publish するには `cloudwatch.amazonaws.com` を Publish 許可するトピックポリシーが必要。IaC で書く際に忘れやすい。
- Slack 通知に使う Webhook URL は Lambda 環境変数に直書きせず、SSM Parameter Store(SecureString)から起動時に取得する設計にする。

```python
import boto3
ssm = boto3.client("ssm")
WEBHOOK_URL = ssm.get_parameter(
    Name="/phase10/slack_webhook", WithDecryption=True
)["Parameter"]["Value"]
```

### パターン B: イベントドリブン マイクロサービス

```
Order Service → SNS (orders) → SQS(per-service) → Inventory / Billing / Shipping
```

各サービスは自分のキューだけをポーリングする。サービス間の直接呼び出しを排除することで、Billing が落ちても Order Service に影響しない。

**スケール設計の注意点**:
- SQS + Lambda のオートスケーリングは `ReservedConcurrentExecutions` で上限を設け、バースト時のコスト爆発と下流 DB への過負荷を防ぐ。
- Lambda Event Source Mapping の `MaximumConcurrency` をキューのポーリング concurrency に合わせること。

### パターン C: マルチリージョン DR

SNS はリージョナルサービスのため、リージョン障害に備えて冗長化するにはアプリ側のフェイルオーバーロジックが必要になる。実践的なアプローチは EventBridge Global Endpoints(2022 GA)と組み合わせて CloudWatch がリージョン間フェイルオーバーを自動化する形。SNS 単独でマルチリージョン HA を組む場合は Publisher 側で複数リージョンへ二重送信するのが現実的。

### パターン D: SNS Message Archiving (2024 GA)

`archive_policy` を設定すると、過去最大 365 日間のメッセージを再送(replay)できる。Kinesis Data Streams の「シャード巻き戻し」と同様の概念。障害後に SQS コンシューマを再起動したとき、すでに削除された SQS メッセージを SNS 側から再配信して補完できる。

```hcl
resource "aws_sns_topic" "orders_archived" {
  name              = "phase10-orders-archived"
  kms_master_key_id = aws_kms_key.phase10.arn
  archive_policy    = jsonencode({ MessageRetentionPeriod = 30 })
  # sandbox では 1 日に短縮して試すと destroy 前の課金を最小化できる
}
```

### パターン E: Large Message Payloads(Extended Client Library)

SNS のメッセージサイズ上限は **256 KB**。超える場合は本体を S3 に格納し、メッセージには S3 ポインタだけを入れる透過的な回避策がある。

```bash
pip install amazon-sns-extended-client
```

```python
import boto3
from sns_extended_client import SNSExtendedClientSession

session = SNSExtendedClientSession()
sns = session.client("sns", region_name="ap-northeast-1")
sns.meta.config = {
    "large_payload_support": "my-bucket",
    "always_through_s3": False,   # 256 KB 超えた場合のみ S3 に退避
}
sns.publish(TopicArn="...", Message=large_json_string)
```

**注意**: 購読側(SQS コンシューマ)も同ライブラリでポーリングしないと、S3 ポインタが含まれる JSON をそのまま処理してしまう。Publisher と Subscriber でライブラリのバージョンを揃えること。

### パターン F: E2E 死活監視(CloudWatch Synthetics Canary)

Canary を定期実行して「SNS Publish → SQS Receive → メッセージ一致」をエンドツーエンドで検証する高度な監視パターン。

```
Canary (rate: 5 min)
  1. SNS に test メッセージを Publish
  2. SQS をポーリングして受信確認
  3. 到達遅延を CloudWatch カスタムメトリクスに記録
  4. タイムアウトなら ALARM → PagerDuty
```

単なるメトリクス監視では「SNS が Publish を受け付けた」は分かっても「エンドポイントまで届いた」は確認できない。Canary で確認することで購読経路の断線を能動的に検出できる。
