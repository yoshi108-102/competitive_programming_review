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
