# Phase 3 ハンズオン — SQS sandbox

## 前提条件

### AWS 認証・権限

- `aws configure` または環境変数 (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`) で ap-northeast-1 にアクセスできること。
- 実行 IAM ユーザー/ロールに次の権限が必要:
  - `sqs:*`（キュー作成・ポリシー設定）
  - `kms:*`（CMK 作成・エイリアス）
  - `lambda:*`（関数作成・ESM 設定）
  - `iam:CreateRole / AttachRolePolicy / PutRolePolicy`
  - `cloudwatch:PutDashboard / GetDashboard`
  - `logs:CreateLogGroup / PutRetentionPolicy`

### ツール

| ツール | 最低バージョン |
|---|---|
| Terraform | 1.6+ |
| AWS CLI | v2 |
| Python | 3.10+（load.sh / watch.sh のコンソール deep link 生成で `python3 -c` を使用） |

### リージョン

全リソースは **ap-northeast-1（東京）** に作成される。

### 課金開始タイミング

`make sandbox-up-phase3` を実行した時点で以下が課金対象になる:

- KMS CMK: $1/月のキー保持料金（日割り換算で約 $0.033/日）
- CloudWatch ダッシュボード: $3/ダッシュボード/月（日割り換算で約 $0.10/日）
- SQS・Lambda: sandbox 規模のメッセージ数（〜60件）では無料枠内

**必ずハンズオン後に `make sandbox-down-phase3` を実行すること。**

---

## 全体の流れ

```
test（validate のみ・無料）→ up（apply・課金開始）→ load（メッセージ注入）→ 5分待機 → watch（メトリクス観測）→ down（destroy・課金停止）
```

| ステップ | コマンド | 所要時間 |
|---|---|---|
| 1. テスト・検証 | `make sandbox-test-phase3` | 30〜60秒 |
| 2. リソース作成 | `make sandbox-up-phase3` | 1〜2分 |
| 3. ロード生成 | `make sandbox-load-phase3` | 20〜30秒 |
| 4. 待機 | — | **5分** |
| 5. メトリクス観測 | `make sandbox-watch-phase3` | 30〜60秒 |
| 6. 後片付け | `make sandbox-down-phase3` | 1〜2分 |

---

## ステップ詳細

### ステップ 1: テスト・検証（`make sandbox-test-phase3`）

**何が起きるか**

`backend/tests/sandboxes/phase3/` が存在すれば moto を使った Python ユニットテストを実行し、続いて `terraform validate` を行う。実 AWS へのアクセスは発生せず、課金もゼロ。

**実行コマンド**

```bash
make sandbox-test-phase3
```

**期待される出力例**

```
==> phase3 に moto テストなし (validate のみ)
==> terraform validate phase3
Success! The configuration is valid.
```

または moto テストがある場合:

```
==> moto pytest phase3
collected 3 items

tests/sandboxes/phase3/test_producer.py::test_send_messages PASSED
...
==> terraform validate phase3
Success! The configuration is valid.
```

**所要時間**: 30〜60秒

---

### ステップ 2: リソース作成（`make sandbox-up-phase3`）

**何が起きるか**

`terraform apply -auto-approve` が走り、以下のリソースが ap-northeast-1 に作成される:

| リソース | 名前（prefix=phase3） |
|---|---|
| KMS CMK | `alias/phase3-sqs` |
| SQS メインキュー | `phase3-main` |
| SQS DLQ | `phase3-dlq` |
| IAM ロール（Producer） | `phase3-producer-role` |
| IAM ロール（Consumer） | `phase3-consumer-role` |
| Lambda（Producer） | `phase3-producer` |
| Lambda（Consumer） | `phase3-consumer` |
| Lambda ESM | SQS → phase3-consumer（batch_size=5） |
| CloudWatch ダッシュボード | `phase3-sqs-dashboard` |
| CloudWatch ロググループ | `/aws/lambda/phase3-producer`, `/aws/lambda/phase3-consumer` |

**実行コマンド**

```bash
make sandbox-up-phase3
```

**期待される出力例**

```
Initializing the backend...
...
Plan: 15 to add, 0 to change, 0 to destroy.
...
Apply complete! Resources: 15 added, 0 changed, 0 destroyed.

Outputs:

dashboard_name = "phase3-sqs-dashboard"
dashboard_url  = "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/..."
dlq_url        = "https://sqs.ap-northeast-1.amazonaws.com/123456789012/phase3-dlq"
main_queue_url = "https://sqs.ap-northeast-1.amazonaws.com/123456789012/phase3-main"
consumer_name  = "phase3-consumer"
producer_name  = "phase3-producer"
```

**所要時間**: 1〜2分

---

### ステップ 3: ロード生成（`make sandbox-load-phase3`）

**何が起きるか**

`load.sh` が 3 つのシナリオで合計 63件のメッセージを注入する:

- **シナリオ 1**: Producer Lambda を invoke し、50件を `phase3-main` へ一括 SendMessage
- **シナリオ 2**: AWS CLI から直接 10件をバースト送信（Producer Lambda を介さない経路の確認）
- **シナリオ 3**: `index=0,7,14` の "poison message" を 3件送信 → Consumer が `index % 7 == 0` で意図的に例外を投げ、maxReceiveCount=3 回失敗後に DLQ へ転送される

**実行コマンド**

```bash
make sandbox-load-phase3
```

**期待される出力例**

```
=== Phase 3 SQS Load Generator ===
Producer Lambda : phase3-producer
Main Queue URL  : https://sqs.ap-northeast-1.amazonaws.com/123456789012/phase3-main
DLQ URL         : https://sqs.ap-northeast-1.amazonaws.com/123456789012/phase3-dlq
Messages/invoke : 50

[Step 1] Invoking producer Lambda (count=50)...
{
    "StatusCode": 200,
    "ExecutedVersion": "$LATEST"
}
{"sent": 50}

[Step 2] Direct CLI send (10 messages burst)...
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
...（10行）

[Step 3] Sending poison messages (index=0,7,14) to trigger DLQ...
yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy

===========================================================
  !! SQS キュー系メトリクス(ApproximateNumberOfMessages*) は
  !! 5分粒度で CloudWatch に反映されます。
  !! watch.sh の実行は 5 分後以降にしてください。
===========================================================
  Lambda の Invocations/Errors は 1 分粒度で反映されます。
  DLQ への流入確認は maxReceiveCount=3 回失敗後なので
  consumer が 3 回 invoke されるまで数分かかります。
===========================================================

5分後に ./watch.sh を実行してください。
```

**所要時間**: 20〜30秒

---

### ステップ 4: 5分待機

SQS の `ApproximateNumberOfMessagesVisible` などのキュー系メトリクスは **5分粒度** で CloudWatch に反映される。load.sh 実行後すぐに watch.sh を実行しても `Datapoints: []` が返るだけで何も見えない。

**正確に5分（=300秒）待ってから次のステップへ進む。**

DLQ への流入（poison message の退避）は Consumer が 3回失敗するまでさらに数分かかる場合がある。DLQ のデータポイントが 0 のときは追加で数分待ってから watch.sh を再実行するとよい。

---

### ステップ 5: メトリクス観測（`make sandbox-watch-phase3`）

**何が起きるか**

`watch.sh` が以下の順序でメトリクスを取得・表示する:

1. CloudWatch ダッシュボード存在確認（スモークテスト）
2. 30秒 sleep（SQS メトリクス反映待ち）
3. SQS メインキューの `ApproximateNumberOfMessagesVisible`（--period 300）
4. SQS DLQ の `ApproximateNumberOfMessagesVisible`（--period 300）
5. SQS メインキューの `NumberOfMessagesSent` / `NumberOfMessagesDeleted`（--period 300）
6. Consumer Lambda の `Invocations` / `Errors`（--period 60）
7. Consumer Lambda の `Duration` p50 / p99（--period 60）
8. CloudWatch ダッシュボード・SQS コンソール・Lambda ログへの deep link を表示

**実行コマンド**

```bash
make sandbox-watch-phase3
```

**期待される出力例**

```
=== Phase 3 SQS 観測レポート ===
観測時刻(UTC): 2026-06-06T03:00:00Z

[Smoke] CloudWatch ダッシュボード存在確認...
phase3-sqs-dashboard
  OK: phase3-sqs-dashboard が存在します

SQS メトリクス反映待ち (30秒)...

[SQS Main] ApproximateNumberOfMessagesVisible (過去15分, 5分粒度)
--------------------------------------------------------------------
|                        GetMetricStatistics                       |
+----------------------------+-------------------------------------+
|            Max             |               Time                  |
+----------------------------+-------------------------------------+
|  52.0                      |  2026-06-06T02:55:00+00:00          |
|  0.0                       |  2026-06-06T03:00:00+00:00          |
+----------------------------+-------------------------------------+

[SQS DLQ] ApproximateNumberOfMessagesVisible (過去15分, 5分粒度)
--------------------------------------------------------------------
|                        GetMetricStatistics                       |
+----------------------------+-------------------------------------+
|            Max             |               Time                  |
+----------------------------+-------------------------------------+
|  3.0                       |  2026-06-06T03:00:00+00:00          |
+----------------------------+-------------------------------------+

[SQS Main] NumberOfMessagesSent / Deleted (5分粒度)
  NumberOfMessagesSent:
...（Sum: 63.0）
  NumberOfMessagesDeleted:
...（Sum: 60.0）

[Lambda Consumer] Invocations / Errors (1分粒度)
  Invocations:
...（Sum: 各分 5〜10 件）
  Errors:
...（Sum: poison メッセージ処理分）

[Lambda Consumer] Duration p50/p99 (1分粒度)
  p50: 〜120ms
  p99: 〜300ms

=== コンソール deep link ===
CloudWatch ダッシュボード:
  https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?...

SQS メインキュー:
  https://ap-northeast-1.console.aws.amazon.com/sqs/v3/home?...

SQS DLQ:
  https://ap-northeast-1.console.aws.amazon.com/sqs/v3/home?...

Lambda Consumer ログ:
  https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?...

===========================================================
  観測が終わったら必ず sandbox を teardown してください:
  make sandbox-down-phase3
===========================================================
```

**所要時間**: 30〜60秒（内 sleep 30秒を含む）

---

### ステップ 6: 後片付け（`make sandbox-down-phase3`）

**何が起きるか**

`terraform destroy -auto-approve` で全リソースが削除される。KMS CMK は即座に削除されず、**7日間のペンディング削除**状態になる（この間は $1/月のキー保持コストが継続する点に注意）。

**実行コマンド**

```bash
make sandbox-down-phase3
```

**期待される出力例**

```
Plan: 0 to add, 0 to change, 15 to destroy.
...
Destroy complete! Resources: 15 destroyed.
```

**所要時間**: 1〜2分

---

## 観察ポイント（チェックリスト）

CloudWatch ダッシュボード `phase3-sqs-dashboard` には 5 つのウィジェットがある。以下を load → 5分後に確認する。

### SQS Main - Visible Messages (5min) ウィジェット

- [ ] `ApproximateNumberOfMessagesVisible` がロード直後に 50〜60 付近にスパイクし、Consumer が処理するにつれて 0 に戻っていることを確認

### SQS DLQ - Visible Messages (5min) ウィジェット

- [ ] DLQ の `ApproximateNumberOfMessagesVisible` が 3 になっていることを確認（poison message: index=0,7,14 がそれぞれ 3 回失敗後に退避）
- [ ] メインキューが 0 に戻った後も DLQ には値が残り続けることを確認（DLQ は自動では処理されない）

### Consumer Lambda - Invocations / Errors ウィジェット

- [ ] `Invocations` が複数の 1 分バケットに分散して計上されていること（batch_size=5 × 複数バッチ）
- [ ] `Errors` が数件〜十数件計上されていること（poison message は Consumer が 3 回 raise → maxReceiveCount=3 で DLQ 送り）
- [ ] `Errors` の合計が `Invocations` の合計より少ないこと（多くの通常メッセージは成功）

### Consumer Lambda - Duration (p50/p99) ウィジェット

- [ ] p50 と p99 の差を確認（通常メッセージは `time.sleep(0.1)` × バッチ件数分 ≒ 500ms 以内、poison は即例外で短い）
- [ ] p99 が p50 の 2〜5 倍程度に収まっていることを確認

### SQS Main - Sent / Deleted / NotVisible (5min) ウィジェット

- [ ] `NumberOfMessagesSent` が 63（Producer 50 + CLI 10 + poison 3）になっていること
- [ ] `NumberOfMessagesDeleted` が 60（poison 3件は DLQ に退避され main から削除されず、maxReceiveCount 到達時に SQS が移動）またはそれに近い値になっていること
- [ ] `ApproximateNumberOfMessagesNotVisible`（処理中・visibility timeout 中のメッセージ）が一時的に上昇したことを確認

---

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| watch.sh で SQS の Datapoints が空 | load 後 5 分未満で実行した | 5 分待ってから再実行。`--period 300` で集計されるため 5 分ごとにしかデータポイントが生まれない |
| DLQ に 3 件来ない | Consumer がまだ 3 回失敗していない | 数分待つ。Consumer ESM の polling 間隔が最大 20 秒のため、3 回失敗には最大 60 秒程度かかる場合がある |
| `make sandbox-up-phase3` で `Error: error creating SQS Queue Policy` | SQS キューポリシーは IAM ロールの ARN が確定してから適用される。依存関係が正しく設定されていれば再 apply で解消する場合がある | `terraform apply` を再実行。解消しなければ `terraform state list` でリソース状態を確認 |
| Lambda invoke で `KMS.KmsDisabledException` | Producer ロールに `kms:GenerateDataKey` が付いていない | iam.tf を確認。Producer ロールのインラインポリシーに `kms:GenerateDataKey` と `kms:Decrypt` が必要 |
| Consumer Lambda ログに `AccessDenied: kms:Decrypt` | Consumer ロールに KMS Decrypt 権限がない | iam.tf の Consumer ロールポリシーを確認 |
| `terraform validate` で `Invalid provider configuration` | `.terraform` が初期化されていない | `terraform -chdir=terraform/sandboxes/phase3 init -backend=false` を手動実行してから `make sandbox-test-phase3` を再実行 |
| `make sandbox-down-phase3` で KMS の削除に失敗 | CMK は即座に削除できない（7日ペンディング）| 正常動作。`deletion_window_in_days = 7` の設定通り。Terraform は destroy 後に CMK をペンディング削除状態にする。7日後に自動削除される |
| watch.sh の deep link を開くとコンソールで `ResourceNotFound` | apply 前に watch.sh を実行している | `make sandbox-up-phase3` と `make sandbox-load-phase3` を先に実行する |

---

## コスト目安

| サービス | 課金項目 | sandbox 規模の概算 |
|---|---|---|
| SQS | $0.40/百万リクエスト | 63件のメッセージ → **$0.00（無料枠 100万件/月）** |
| KMS CMK | $1/月のキー保持 + $0.03/10,000 APIコール | キー保持: **約 $0.03/日**。APIコール数 ≒ 数十件 → $0.00 |
| Lambda | 無料枠: 100万 invoke/月、400,000 GB-秒/月 | sandbox 規模 → **$0.00** |
| CloudWatch ダッシュボード | $3/ダッシュボード/月 | **約 $0.10/日**。destroy すれば即停止 |
| CloudWatch ログ | $0.76/GB（取り込み） | 数KB 未満 → **$0.00** |

**ハンズオン 1 回あたりの合計コスト目安: $0.00〜$0.15 程度（KMS + ダッシュボードの日割り）**

> KMS CMK は `terraform destroy` 後も **7 日間のペンディング削除**状態が続き、その間は $0.03/日程度のキー保持コストが発生する。誤って再参照するとエラーになるため、7 日後に完全削除されるまで同名のエイリアスは使えない。

---

## 後片付けの確認

destroy 前にやっておくこと:

- [ ] CloudWatch ダッシュボードのスクリーンショットを保存した（必要な場合）
- [ ] DLQ に残るメッセージを redrive したい場合は事前に実施（destroy 後はメッセージごと削除される）

destroy 後の確認:

- [ ] `make sandbox-down-phase3` が `Destroy complete! Resources: N destroyed.` で終了した
- [ ] AWS コンソール → SQS → ap-northeast-1 で `phase3-main` / `phase3-dlq` が表示されないことを確認
- [ ] AWS コンソール → Lambda → ap-northeast-1 で `phase3-producer` / `phase3-consumer` が表示されないことを確認
- [ ] AWS コンソール → KMS → ap-northeast-1 で `alias/phase3-sqs` が「ペンディング削除」状態になっていることを確認（7日後に自動削除）
- [ ] AWS コンソール → CloudWatch → ダッシュボード で `phase3-sqs-dashboard` が削除されていることを確認
- [ ] タグ `Sandbox=phase3` のリソースがリソースグループタグエディタで残っていないことを確認
