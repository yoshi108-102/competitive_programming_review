# Phase 2 教材: イベント通知（S3 → Lambda / SQS / SNS / EventBridge）

---

## このトピックは何か

Amazon S3 のイベント通知（Event Notifications）は、バケット内で特定の操作が起きたとき、その情報を外部のサービスへ自動的に送り出す仕組みです。たとえば「新しいオブジェクトが PUT されたら Lambda を起動する」という連携を、ポーリングなしで実現できます。

この仕組みを使うと、S3 を起点にしたイベント駆動アーキテクチャを組めます。本 sandbox の AtCoder 復習ツールでは「提出 JSON が S3 に置かれたら Lambda で DynamoDB に書き込む」という ObjectCreated → Lambda 構成がそのまま当てはまります。

---

## コアコンセプト

### 通知の流れ

```
バケット内で操作（PUT / DELETE / Restore / Tag など）
       │
       ▼
  通知設定（Notification Configuration）を評価
       │  ← prefix / suffix フィルタでここで絞り込む
       ▼
  宛先へ非同期配信
  ├─ Lambda
  ├─ SQS Standard Queue
  ├─ SNS Standard Topic
  └─ EventBridge（全イベントを一括転送）
```

通知設定はバケットのサブリソース（`NotificationConfiguration`）として保存されます。設定の追加・変更は `PutBucketNotificationConfiguration` API（または Terraform）で行います。

### at-least-once 配信

S3 のイベント通知は **少なくとも 1 回（at-least-once）** 配信されます。通常は数秒以内に届きますが、稀に 1 分以上かかることがあります。また、S3 の再試行機構により **同じイベントが重複して届く可能性**があります。処理側を冪等（idempotent）に設計する必要があります。

### 順序保証なし

イベントが発生した順序どおりに通知が届く保証はありません。複数のオブジェクト操作が連続して起きた場合、通知の到達順は前後する可能性があります。

---

## 主要な設定・API・パラメータ

### サポートされるイベント種別（SQS / SNS / Lambda 向け）

| イベント種別 | 概要 |
|---|---|
| `s3:ObjectCreated:*` | PUT / POST / COPY / CompleteMultipartUpload のいずれかで作成 |
| `s3:ObjectCreated:Put` | PutObject による作成のみ |
| `s3:ObjectCreated:Post` | HTML フォームの POST による作成 |
| `s3:ObjectCreated:Copy` | CopyObject による作成 |
| `s3:ObjectCreated:CompleteMultipartUpload` | マルチパートアップロード完了時 |
| `s3:ObjectRemoved:*` | Delete / DeleteMarkerCreated のいずれか |
| `s3:ObjectRemoved:Delete` | 非バージョンオブジェクトの削除、またはバージョンの完全削除 |
| `s3:ObjectRemoved:DeleteMarkerCreated` | バージョン有効バケットで削除マーカーが作成された |
| `s3:ObjectRestore:Post` / `:Completed` / `:Delete` | Glacier リストア開始 / 完了 / 一時コピー期限切れ |
| `s3:LifecycleExpiration:Delete` | ライフサイクルルールによるオブジェクト削除 |
| `s3:LifecycleTransition` | ライフサイクルによるストレージクラス移行 |
| `s3:ObjectTagging:Put` / `:Delete` | タグの追加・更新 / タグの削除 |
| `s3:ObjectAcl:Put` | ACL の変更 |
| `s3:Replication:*` | レプリケーション監視イベント（失敗・遅延など） |
| `s3:IntelligentTiering` | Intelligent-Tiering の Archive 移行 |
| `s3:ReducedRedundancyLostObject` | RRS オブジェクトが失われた |

> ワイルドカード（`s3:ObjectCreated:*` など）を指定すると、そのカテゴリの全サブタイプを受け取れます。

### フィルタ（prefix / suffix）

通知設定にはキーのプレフィックスとサフィックスによるフィルタを付けられます。1 つの通知設定につきフィルタは 1 つだけ有効です。

```hcl
# Terraform での例
resource "aws_s3_bucket_notification" "example" {
  bucket = aws_s3_bucket.main.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "submissions/"   # このプレフィックスのキーだけ
    filter_suffix       = ".json"          # このサフィックスのキーだけ
  }
}
```

### 4 つの宛先と制約

| 宛先 | 特徴 | 制約 |
|---|---|---|
| **Lambda** | 最速。S3 が直接 Lambda を非同期呼び出し | 同一リージョン必須。Lambda へのリソースポリシー付与が必要 |
| **SQS Standard** | バッファ機能あり。Lambda の DLQ と組み合わせ可能 | 同一リージョン必須。FIFO キューは不可 |
| **SNS Standard** | ファンアウト（1 通知 → 複数サブスクライバー） | 同一リージョン必須。FIFO トピックは不可 |
| **EventBridge** | ルール/フィルタ/アーカイブ/リプレイが使える。全イベントを一括転送 | 有効/無効の二択（イベント種別の選択不可） |

SQS FIFO キューや SNS FIFO トピックへ直接通知することはできません。FIFO が必要な場合は EventBridge 経由で転送します。

### Lambda を宛先にするときのリソースポリシー

S3 が Lambda を呼び出すには、Lambda 側のリソースポリシーで `s3.amazonaws.com` からの呼び出しを許可する必要があります。

```hcl
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invocation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.main.arn
}
```

`source_arn` を省略すると、任意のバケットから呼び出せる状態になるため必ず指定します。

### Lambda が受け取るイベント構造

```json
{
  "Records": [
    {
      "eventVersion": "2.1",
      "eventSource": "aws:s3",
      "awsRegion": "ap-northeast-1",
      "eventTime": "2026-05-31T12:00:00.000Z",
      "eventName": "ObjectCreated:Put",
      "s3": {
        "s3SchemaVersion": "1.0",
        "bucket": {
          "name": "atcoder-review-artifacts",
          "arn": "arn:aws:s3:::atcoder-review-artifacts"
        },
        "object": {
          "key": "submissions%2F2026%2Fabc.json",
          "size": 1024,
          "eTag": "d41d8cd98f00b204e9800998ecf8427e",
          "sequencer": "0A1B2C3D4E5F678901"
        }
      }
    }
  ]
}
```

`object.key` は URL エンコードされています。Python で取り出すときは `urllib.parse.unquote_plus(record["s3"]["object"]["key"])` を使います。

### EventBridge を有効にする

EventBridge への通知はバケット単位で有効/無効を切り替えます。有効にすると、そのバケットで発生するすべてのイベントが EventBridge に転送されます。イベント種別の選択はできません（ルール側でフィルタします）。

```bash
aws s3api put-bucket-notification-configuration \
  --bucket my-bucket \
  --notification-configuration '{"EventBridgeConfiguration": {}}'
```

Terraform では `aws_s3_bucket_notification` の `eventbridge` 引数で設定します。

```hcl
resource "aws_s3_bucket_notification" "eventbridge" {
  bucket      = aws_s3_bucket.main.id
  eventbridge = true
}
```

有効化後、変更が反映されるまで約 5 分かかります。

### EventBridge が送るイベント種別

EventBridge 向けのイベントは SQS/SNS/Lambda 向けとはイベント名の形式が異なります。

| EventBridge のイベント種別 | 対応する操作 |
|---|---|
| `Object Created` | PutObject / POST / CopyObject / CompleteMultipartUpload |
| `Object Deleted (DeleteObject)` | DeleteObject API |
| `Object Deleted (Lifecycle expiration)` | ライフサイクルルールによる削除 |
| `Object Restore Initiated` | Glacier リストア開始 |
| `Object Restore Completed` | Glacier リストア完了 |
| `Object Restore Expired` | リストア一時コピーの期限切れ |
| `Object Storage Class Changed` | ストレージクラス変更 |
| `Object Access Tier Changed` | Intelligent-Tiering の Archive 移行 |
| `Object ACL Updated` | ACL 変更 |
| `Object Tags Added` | タグ追加 |
| `Object Tags Deleted` | タグ削除 |

---

## よくある落とし穴・誤解

### 1. Lambda が失敗しても S3 は気にしない

S3 から Lambda への通知は非同期呼び出しです。Lambda 関数がエラーを返しても、S3 はそれを検知せず通知を「成功」として扱います。処理失敗に備えるには Lambda 側で DLQ（Dead-Letter Queue）または非同期呼び出しの宛先設定（`EventInvokeConfig`）を設定します。

```hcl
resource "aws_lambda_function_event_invoke_config" "processor" {
  function_name = aws_lambda_function.processor.function_name

  destination_config {
    on_failure {
      destination = aws_sqs_queue.dlq.arn
    }
  }
}
```

### 2. 大量 PUT 時のスロットリング

短時間に大量のオブジェクトが PUT されると、Lambda の同時実行数が枯渇することがあります。その場合、S3 はイベントをリトライしますが、**最大 6 時間後** に再試行する可能性があります。スループットが高いユースケースでは SQS を間に挟み、Lambda の `EventSourceMapping` で並列度を制御するのが堅牢な設計です。

```
S3 → SQS → Lambda（BatchSize / MaximumConcurrency で流量制御）
```

### 3. 同一バケットへの書き戻しによる無限ループ

Lambda がイベントを受け取って処理した結果を、同じバケットの通知対象プレフィックスに書き戻すと、再度通知が飛んで無限ループになります。書き戻し先のキーは通知のフィルタ範囲外のプレフィックスに設定するか、別バケットを使います。

### 4. オブジェクトキーの URL エンコード

イベントペイロード内の `object.key` はパーセントエンコードされています。スペースや日本語が含まれるキーを扱う場合は必ずデコードしてから利用します。

```python
import urllib.parse

def handler(event, context):
    for record in event["Records"]:
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        # key = "submissions/2026/abc.json"
```

### 5. SQS FIFO は直接指定できない

SQS FIFO キューは S3 イベント通知の宛先として直接指定できません。FIFO の順序保証が必要な場合は、S3 → SQS Standard → Lambda で受けるか、S3 → EventBridge → SQS FIFO のルートを取ります。

### 6. 宛先とバケットは同一リージョンが必要

Lambda / SQS / SNS の宛先は、バケットと同じ AWS リージョンに存在する必要があります。EventBridge はデフォルトでバケットと同一リージョンのイベントバスへ送られます。

---

## このプロジェクト（AtCoder 復習）での使いどころ

本 sandbox では `atcoder-review-artifacts` バケットへの ObjectCreated が Lambda をトリガーします。

| 構成要素 | 役割 |
|---|---|
| S3 バケット | 提出データの着地点（`submissions/` プレフィックス） |
| `s3:ObjectCreated:*` 通知 | PUT 完了を検知して Lambda を起動 |
| prefix フィルタ `submissions/` | Lambda 処理対象を提出 JSON に限定 |
| suffix フィルタ `.json` | JSON 以外（画像等）を誤ってトリガーしない |
| Lambda（`sync_submissions`） | S3 から JSON を読み込み DynamoDB に書き込む |

将来的にファンアウトが必要になった場合（例: 通知メール送信 + DB 書き込みを並列実行）は SNS をハブにして Lambda と SQS を複数サブスクライバーとして接続できます。より複雑なルーティング（例: コンテストIDでターゲットを分岐）が必要になったら EventBridge ルールへの移行を検討します。

## 公式ドキュメント（出典）

- [Amazon S3 イベント通知 — 概要](https://docs.aws.amazon.com/AmazonS3/latest/userguide/NotificationHowTo.html)（閲覧日 2026-05-31）
- [イベント通知タイプと宛先](https://docs.aws.amazon.com/AmazonS3/latest/userguide/notification-how-to-event-types-and-destinations.html)（閲覧日 2026-05-31）
- [Amazon EventBridge を使用する](https://docs.aws.amazon.com/AmazonS3/latest/userguide/EventBridge.html)（閲覧日 2026-05-31）
- [Amazon EventBridge の有効化](https://docs.aws.amazon.com/AmazonS3/latest/userguide/enable-event-notifications-eventbridge.html)（閲覧日 2026-05-31）
- [通知先へのアクセス許可の付与](https://docs.aws.amazon.com/AmazonS3/latest/userguide/grant-destinations-permissions-to-s3.html)（閲覧日 2026-05-31）
- [AWS Lambda で Amazon S3 を使用する（Lambda デベロッパーガイド）](https://docs.aws.amazon.com/lambda/latest/dg/with-s3.html)（閲覧日 2026-05-31）
