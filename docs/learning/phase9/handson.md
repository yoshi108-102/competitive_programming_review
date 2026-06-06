# Phase 9 ハンズオン — X-Ray sandbox

## 前提条件

### AWS 認証・権限

- `aws sts get-caller-identity` が正常に返ること（IAM ユーザーまたはロールの認証済み状態）
- 必要な権限: `xray:*` / `lambda:*` / `dynamodb:*` / `sqs:*` / `kms:*` / `apigateway:*` / `cloudwatch:*` / `logs:*` / `iam:*`
- 手元の `~/.aws/credentials` または環境変数 `AWS_PROFILE` / `AWS_DEFAULT_REGION` が設定済みであること

### リージョン

```bash
export AWS_DEFAULT_REGION=ap-northeast-1
```

`ap-northeast-1`（東京）固定。他リージョンでは X-Ray ServiceLens の deep link が壊れる。

### 課金開始の注意

`make sandbox-up-phase9` を実行した瞬間から課金が始まる。今 Phase の主要コストは KMS CMK（$1/月）。トレース量は無料枠内。終わったら必ず `make sandbox-down-phase9` を実行する。詳細は「コスト目安」節を参照。

### Phase 固有の前提

- **aws-xray-sdk は Lambda Layer 提供が必要**。本 sandbox では `backend/sandboxes/phase9/` の `producer.py` / `consumer.py` が aws-xray-sdk を `import` しているが、IaC 側で Layer ARN を固定していないため、デプロイ前に Layer の事前作成またはデプロイパッケージへの同梱が必要。詳細は `docs/learning/phase9/preview-xray.md` を参照。
- Terraform >= 1.7 / AWS CLI v2 / Python 3.12 / GNU make が手元にあること。
- `jq` があると watch.sh の JSON 整形がきれいになる（任意）。

---

## 全体の流れ

```
sandbox-test-phase9  →  sandbox-up-phase9  →  sandbox-load-phase9  →  sandbox-watch-phase9  →  sandbox-down-phase9
     (検証・無課金)         (リソース作成)        (トラフィック生成)       (メトリクス・X-Ray観察)       (後片付け)
```

---

## ステップ詳細

### ステップ 1: テスト・バリデーション（無課金）

**何が起きるか**

moto pytest（`backend/tests/sandboxes/phase9/` があれば）を実行したあと、`terraform validate` で IaC の構文エラーを検出する。実際の AWS リソースは一切作成しないため課金ゼロ。

**実行コマンド**

```bash
make sandbox-test-phase9
```

**期待される出力例**

```
==> phase9 に moto テストなし (validate のみ)
==> terraform validate phase9
Terraform has been successfully initialized!
Success! The configuration is valid.
```

**所要時間**: 15〜30 秒（初回 init は provider DL で 1〜2 分）

---

### ステップ 2: リソース作成（sandbox-up）

**何が起きるか**

Terraform が以下を ap-northeast-1 に作成する。

- KMS CMK (`alias/phase9-xray`) + X-Ray 暗号化設定
- X-Ray サンプリングルール 2 本（`phase9-high-priority` / `phase9-health-check`）
- DynamoDB テーブル `phase9-items`（PITR 有効・KMS 暗号化）
- SQS キュー `phase9-main` + DLQ `phase9-main-dlq`
- Lambda `phase9-producer` / `phase9-consumer`（Active トレーシング）
- API Gateway HTTP API `phase9-api` (`POST /v1/items`)
- CloudWatch Log Groups × 3（retention=1d・KMS 暗号化）
- CloudWatch Dashboard `phase9-xray-sandbox`

**実行コマンド**

```bash
make sandbox-up-phase9
```

**期待される出力例**

```
Terraform will perform the following actions:
  # aws_kms_key.phase9 will be created
  # aws_xray_encryption_config.phase9 will be created
  # aws_xray_sampling_rule.phase9_high_priority will be created
  # aws_xray_sampling_rule.phase9_health will be created
  # aws_dynamodb_table.phase9 will be created
  # aws_sqs_queue.phase9_dlq will be created
  # aws_sqs_queue.phase9 will be created
  # aws_lambda_function.producer will be created
  # aws_lambda_function.consumer will be created
  # aws_apigatewayv2_api.phase9 will be created
  ...
Apply complete! Resources: 22 added, 0 changed, 0 destroyed.

Outputs:
api_url             = "https://xxxxxxxxxx.execute-api.ap-northeast-1.amazonaws.com/v1"
consumer_function_name = "phase9-consumer"
dashboard_url       = "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=phase9-xray-sandbox"
dynamodb_table_name = "phase9-items"
kms_key_arn         = "arn:aws:kms:ap-northeast-1:123456789012:key/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
producer_function_name = "phase9-producer"
sqs_url             = "https://sqs.ap-northeast-1.amazonaws.com/123456789012/phase9-main"
```

**所要時間**: 約 2〜4 分

---

### ステップ 3: トラフィック生成（sandbox-load）

**何が起きるか**

`load.sh` が 4 つのシナリオを順番に実行し、X-Ray にトレースデータを送り込む。

| シナリオ | 内容 | 狙い |
|---|---|---|
| 1/4 | `POST /items` × 20 回（正常系） | producer → DynamoDB/SQS トレースチェーン生成 |
| 2/4 | Lambda 直接 invoke × 1 回 | コールドスタート（Init Duration セグメント）誘発 |
| 3/4 | 壊れた JSON で POST × 5 回 | X-Ray にエラーセグメント（Fault/Error）を生成 |
| 4/4 | SQS 直接送信 × 5 件 | consumer Lambda の非同期トレース伝播を観測 |

**実行コマンド**

```bash
make sandbox-load-phase9
```

**期待される出力例**

```
================================================================
  Phase9 ロード生成 — X-Ray トレースを作成します
================================================================

  サービス : X-Ray / ServiceLens
  リージョン: ap-northeast-1

>>> terraform output から識別子を取得中...

  API_URL      : https://xxxxxxxxxx.execute-api.ap-northeast-1.amazonaws.com/v1
  QUEUE_URL    : https://sqs.ap-northeast-1.amazonaws.com/123456789012/phase9-main
  PRODUCER_FN  : phase9-producer

----------------------------------------------------------------
 [1/4]  正常系: POST /items  x20
        狙い: producer → DynamoDB/SQS のトレースチェーンを生成
----------------------------------------------------------------
   1/20  HTTP 200  ✓
   2/20  HTTP 200  ✓
  ...
  20/20  HTTP 200  ✓

  >>> 正常系完了: 成功=20  失敗/その他=0

----------------------------------------------------------------
 [2/4]  コールドスタート誘発: Lambda 直接 invoke
        狙い: Init Duration セグメントを X-Ray に出す
----------------------------------------------------------------
  invoke レスポンス:
    {
        "statusCode": 200,
        "body": "{\"item_id\": \"...\"}"
    }

----------------------------------------------------------------
 [3/4]  エラー誘発: 壊れた JSON  x5
        狙い: X-Ray のエラーセグメント (Fault/Error) を生成
              ServiceLens でエラーレートが色付き表示される
----------------------------------------------------------------
  error-1: HTTP 400
  error-2: HTTP 400
  error-3: HTTP 400
  error-4: HTTP 400
  error-5: HTTP 400

  >>> エラー誘発完了 (4xx/5xx が X-Ray Fault として記録されます)

----------------------------------------------------------------
 [4/4]  SQS 直接送信  x5  (consumer Lambda のトレースを生成)
        狙い: SQS → consumer の非同期トレース伝播を確認
----------------------------------------------------------------
  sent [1/5]: MessageId = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  ...
  sent [5/5]: MessageId = yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy

  >>> SQS 送信完了: 5/5 件

================================================================
  ロード完了サマリ
================================================================

  シナリオ1 (正常系 POST)  : 20/20 件 成功
  シナリオ2 (コールドスタート): Lambda invoke 1 回
  シナリオ3 (エラー誘発)   :  5 件
  シナリオ4 (SQS 直送)    : 5/5 件 送信

  X-Ray にトレースが届くまで 1-3 分かかります。
  consumer Lambda の SQS 処理もその後 30-60 秒以内に完了します。

  *** メトリクス反映を待ってから以下を実行してください ***

      make sandbox-watch-phase9

================================================================
```

**所要時間**: 約 1〜2 分（send + sleep 込み）

---

### ステップ 4: 観測（sandbox-watch）

**何が起きるか**

`watch.sh` が以下を順に行う。

1. CloudWatch Dashboard の存在確認
2. 観察ポイントの解説（期待値の表示）
3. メトリクス反映待ち（90 秒）
4. Lambda Invocations（過去 10 分）を取得・表示
5. Lambda Duration p99 を取得・表示
6. Lambda Errors を取得・表示
7. SQS キュー深度（`phase9-main`）を取得・表示
8. X-Ray トレース件数（過去 10 分）を取得・表示
9. X-Ray / ServiceLens コンソールへの deep link を出力

**実行コマンド**

```bash
make sandbox-watch-phase9
```

**期待される出力例（抜粋）**

```
── [2] Lambda Invocations (過去10分) ────────────────────────────────────
    期待値: producer=21前後, consumer=SQS送信数前後

  phase9-producer:
  -------------------------------------------------------
  |            GetMetricStatistics                      |
  +--------------------------+--------------------------+
  |  2026-06-06T10:00:00Z    |            21.0          |
  +--------------------------+--------------------------+

  phase9-consumer:
  -------------------------------------------------------
  |            GetMetricStatistics                      |
  +--------------------------+--------------------------+
  |  2026-06-06T10:00:00Z    |             5.0          |
  +--------------------------+--------------------------+

── [3] Lambda Duration p99 ms (過去10分) ────────────────────────────────
    期待値: コールドスタートで 300-800ms, ウォーム後は数十ms 台

  phase9-producer:
  -------------------------------------------------------
  |            GetMetricStatistics                      |
  +--------------------------+--------------------------+
  |  2026-06-06T10:00:00Z    |           524.3          |
  +--------------------------+--------------------------+

── [4] Lambda Errors (過去10分) ─────────────────────────────────────────
    期待値: producer=5前後(エラー誘発分), consumer=0

  phase9-producer: Errors = 5
  phase9-consumer: Errors = 0

── [5] SQS: phase9-main キュー深度 (period=300s) ─────────────────────
    期待値: consumer が処理済みなら 0 に近い / DLQ に流れていれば要調査

  +--------------------------+--------------------------+
  |  2026-06-06T10:00:00Z    |             0.0          |
  +--------------------------+--------------------------+

── [6] X-Ray トレース件数 (過去10分, サンプリング) ──────────────────────
    期待値: 数件〜30件前後 (サンプリングルール fixed_rate=10%)

  過去10分のトレース件数(サンプリング): 8 件

── [7] コンソール ディープリンク ────────────────────────────────────────

  【CloudWatch Dashboard】
  https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=phase9-xray-sandbox

  【ServiceLens Service Map】
  https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#servicelens:map

  【X-Ray Traces】
  https://ap-northeast-1.console.aws.amazon.com/xray/home?region=ap-northeast-1#/traces

  【X-Ray Service Map】
  https://ap-northeast-1.console.aws.amazon.com/xray/home?region=ap-northeast-1#/service-map

  【X-Ray Sampling Rules (fixed_rate=10% を確認)】
  https://ap-northeast-1.console.aws.amazon.com/xray/home?region=ap-northeast-1#/sampling-rules
```

**所要時間**: 約 3〜4 分（90 秒の待機込み）

---

### ステップ 5: 後片付け（sandbox-down）

**実行コマンド**

```bash
make sandbox-down-phase9
```

**期待される出力例**

```
Terraform will perform the following actions:
  # aws_lambda_function.producer will be destroyed
  ...
Destroy complete! Resources: 22 destroyed.
```

**所要時間**: 約 2〜3 分。KMS CMK は削除保留（7 日間）のため、destroy 後も AWS コンソールに残る（下記「後片付けの確認」を参照）。

---

## 観察ポイント（チェックリスト）

### CloudWatch Dashboard (`phase9-xray-sandbox`)

- [ ] ウィジェット「Lambda: Invocations」で `phase9-producer` が 21 前後・`phase9-consumer` が 5 前後の棒グラフを確認
- [ ] ウィジェット「Lambda: Duration (p99)」で producer の最初の棒が 300〜800ms 台（コールドスタート）、以降が数十 ms 台に落ちていることを確認
- [ ] ウィジェット「Lambda: Errors & Throttles」で producer の Errors が 5 前後、consumer の Errors が 0 であることを確認
- [ ] ウィジェット「Lambda: ConcurrentExecutions」でピーク時の同時実行数が数個であることを確認
- [ ] ウィジェット「SQS: phase9-main キュー深度」で `ApproximateNumberOfMessagesVisible` が 0 に収束していることを確認（consumer が処理済み）

### X-Ray Traces コンソール

- [ ] X-Ray > Traces で過去 30 分のトレースが数件〜数十件表示されることを確認
- [ ] エラー誘発分（シナリオ 3）が赤/黄色でハイライトされていることを確認
- [ ] 個別トレースを開き、タイムライン（ウォーターフォール）に `DynamoDB` サブセグメントと `SQS` サブセグメントが展開できることを確認
- [ ] シナリオ 2（コールドスタート誘発）のトレースに `Initialization` サブセグメントが表示されていることを確認
- [ ] Filter 式 `annotation.aws:function_name = "phase9-producer"` で絞り込めることを確認

### X-Ray / ServiceLens Service Map

- [ ] ServiceLens > Service Map（または X-Ray > Service Map）で `phase9-producer` ノードが描画されていることを確認
- [ ] `phase9-producer` から `DynamoDB` ノードへのエッジが表示されていることを確認
- [ ] `phase9-producer` から `SQS` ノードへのエッジが表示されていることを確認
- [ ] `phase9-consumer` ノードが `SQS` ノードの下流に描画されていることを確認
- [ ] `phase9-producer` ノードがエラー誘発後に赤/黄色になっていることを確認

### X-Ray 暗号化・サンプリング

- [ ] X-Ray > Sampling Rules で `phase9-high-priority`（priority=100 / fixed_rate=10%）と `phase9-health-check`（priority=50 / fixed_rate=1%）の 2 本が存在することを確認
- [ ] X-Ray > Encryption で `Type: KMS` / `Key: alias/phase9-xray` が設定されていることを確認

---

## トラブルシュート

| 症状 | 原因候補 | 対処 |
|---|---|---|
| `POST /items` が 502 を返す | aws-xray-sdk が Lambda にインストールされていない | デプロイパッケージに aws-xray-sdk を同梱するか、Layer を作成して Lambda にアタッチする |
| X-Ray にトレースが全く出ない | サンプリングルールが適用されていない・数分の遅延 | load.sh 実行から 1〜3 分待つ。X-Ray > Sampling Rules で `phase9-high-priority` が有効か確認 |
| トレース件数が期待より極端に少ない | `fixed_rate=0.10`（10%サンプリング）が効いている | 正常動作。20 リクエストで 2〜5 件程度になる。`reservoir_size=5` で毎秒最低 5 件は通るため、短時間バースト分はほぼ取れる |
| Service Map にノードが出ない | patch_all() が未適用・トレースが届いていない | X-Ray > Traces でトレース自体が届いているか確認。届いていれば Service Map の更新まで 5〜10 分かかることがある |
| consumer の Errors が増えている | SQS メッセージのパース失敗・DLQ に流れている | CloudWatch Logs `/aws/lambda/phase9-consumer` でスタックトレースを確認。DLQ (`phase9-main-dlq`) のメッセージ数を確認 |
| `make sandbox-watch-phase9` でメトリクスが「データなし」 | Lambda メトリクスの反映遅延（1〜3 分） | 90 秒の待機後にもデータがない場合は、load.sh が正常に実行されたか (`OK_COUNT=20` か) を確認 |
| `watch.sh` の SQS メトリクスが「データなし」 | SQS メトリクスは 5 分粒度 | watch.sh 実行から 5〜10 分後に AWS コンソールで直接確認する |
| `terraform apply` で KMS の権限エラー | 実行 IAM ユーザーに `kms:CreateKey` / `kms:PutKeyPolicy` が不足 | 管理者に `AWSKeyManagementServicePowerUser` または該当権限の付与を依頼する |
| destroy 後も KMS CMK が残る | `deletion_window_in_days = 7` による削除保留（正常） | 7 日後に自動削除される。即時削除が必要なら AWS コンソール > KMS > スケジュールされたキー削除をキャンセルして手動削除 |

---

## コスト目安

| リソース | 料金 | 備考 |
|---|---|---|
| KMS CMK (`alias/phase9-xray`) | $1.00/月 | destroy 後も 7 日間の削除保留期間中は課金継続 |
| X-Ray トレース | 無料枠内（100,000 トレース/月まで無料） | sandbox のトレース量は数十件なので実質 $0 |
| Lambda 実行 | 無料枠内（1M リクエスト/月まで無料） | load.sh の 26 回程度は無視できる |
| DynamoDB | 無料枠内（25 GB / 200 万 WCU まで無料） | PITR は apply 中のみ課金（$0.20/GB/月）、sandbox 用途では $0.01 未満 |
| SQS | 無料枠内（100 万リクエスト/月まで無料） | 実質 $0 |
| API Gateway HTTP API | 無料枠内（100 万リクエスト/月まで無料） | 実質 $0 |
| CloudWatch Dashboard | $3.00/月（3 ダッシュボードまで無料） | ダッシュボード 1 個：$0 |
| CloudWatch Logs | 取り込み $0.76/GB | retention=1d のため翌日自動削除。sandbox 量では $0.01 未満 |

**概算合計**: destroy まで数時間の利用なら **$0.01〜$0.10 程度**（KMS の日割りが支配的）。

---

## 後片付けの確認

- [ ] `make sandbox-down-phase9` が `Destroy complete!` で終了したことを確認
- [ ] AWS コンソール > Lambda で `phase9-producer` / `phase9-consumer` が削除されていることを確認
- [ ] AWS コンソール > DynamoDB で `phase9-items` テーブルが削除されていることを確認
- [ ] AWS コンソール > SQS で `phase9-main` / `phase9-main-dlq` が削除されていることを確認
- [ ] AWS コンソール > API Gateway で `phase9-api` が削除されていることを確認
- [ ] AWS コンソール > CloudWatch > Dashboards で `phase9-xray-sandbox` が削除されていることを確認
- [ ] AWS コンソール > KMS で `alias/phase9-xray` が「削除保留中」状態になっていることを確認（7 日後に自動削除される）
- [ ] AWS リソースグループ で タグ `Sandbox=phase9` を持つリソースが上記以外に残っていないことを確認
- [ ] X-Ray のトレースデータは 30 日保存（destroy しても残る。読み取り課金はなし）
