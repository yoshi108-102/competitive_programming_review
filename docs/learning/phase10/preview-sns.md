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
