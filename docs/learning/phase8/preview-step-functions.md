# Phase 8 プレビュー教材: Step Functions

> プレビュー教材: デモ体験のために先行生成しました。正式な lesson / 振り返りクイズ / 採点は Phase 8 到達時に実施します。

---

## このサービスは何か

AWS Step Functions は、**ステートマシン**（状態機械）として複数の処理ステップを宣言的に定義し、オーケストレーションするサーバーレスサービス。  
ワークフローは **Amazon States Language (ASL)** という JSON 形式で記述し、各ステートが「何をするか」「次にどこへ行くか」「失敗時にどうするか」を明示的に宣言する。  
実行の可視化・履歴記録・自動リトライを組み込みで提供するため、複数 Lambda の連鎖ロジックを Lambda 内コードで管理する必要がなくなる。

---

## いつ使うか・使わないか

| 使う場面 | 使わない場面 |
|---|---|
| 複数 Lambda / サービスを順次・並列・条件分岐で呼び出す | 単一 Lambda で完結する処理 |
| 長時間ワークフロー（数分〜数ヶ月）の状態管理が必要 | 単純な SQS キュー → Lambda のパイプライン |
| 失敗箇所を可視化・再実行したい | 超低レイテンシ(<10ms)が最優先のリアルタイム処理 |
| 人間の承認ステップ（waitForTaskToken）を挟む | ランニングコストを最小化したいシンプルな非同期処理 |
| 冪等性を保証した再試行が必要 | |

---

## コアコンセプト

### ステートマシンと ASL

ステートマシンは `States` オブジェクトで複数のステートを宣言し、`StartAt` で開始ステートを指定する。

```json
{
  "Comment": "サンプル",
  "StartAt": "ValidateInput",
  "States": {
    "ValidateInput": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:ap-northeast-1:123456789012:function:validate",
      "Next": "RouteChoice"
    },
    "RouteChoice": {
      "Type": "Choice",
      "Choices": [
        { "Variable": "$.valid", "BooleanEquals": true, "Next": "Process" }
      ],
      "Default": "FailState"
    },
    "Process": { "Type": "Task", "Resource": "arn:...", "End": true },
    "FailState": { "Type": "Fail", "Error": "InvalidInput" }
  }
}
```

### ステートの種類

| Type | 役割 |
|---|---|
| **Task** | Lambda・ECS・DynamoDB 等のサービスを呼び出す |
| **Choice** | 条件分岐（if/else 相当）。`End` は持てない |
| **Parallel** | 複数のブランチを並列実行し、全完了を待つ |
| **Map** | 配列の各要素に同一ワークフローを並列適用 |
| **Wait** | 指定秒数 or タイムスタンプまで待機 |
| **Pass** | 入力をそのまま（変換して）次へ渡す。デバッグに便利 |
| **Succeed** | 正常終了 |
| **Fail** | エラーを指定して終了 |

### 入出力処理

各ステートは JSON ドキュメントを入力として受け取り、出力を次ステートへ渡す。4 つのパスフィルタで制御する。

| フィールド | 役割 |
|---|---|
| `InputPath` | 入力 JSON のどの部分をタスクに渡すか（デフォルト `$` = 全体） |
| `Parameters` | タスクへ渡す入力を静的値や JsonPath で再構築 |
| `ResultPath` | タスク結果を入力 JSON のどのキーに格納するか |
| `OutputPath` | 次ステートへ渡す範囲を絞る |

```json
"ResultPath": "$.taskResult",
"OutputPath": "$.taskResult"
```

### Retry と Catch

```json
"Retry": [
  {
    "ErrorEquals": ["Lambda.ServiceException", "States.TaskFailed"],
    "IntervalSeconds": 2,
    "MaxAttempts": 3,
    "BackoffRate": 2.0
  }
],
"Catch": [
  {
    "ErrorEquals": ["States.ALL"],
    "Next": "FallbackState",
    "ResultPath": "$.error"
  }
]
```

- **Retry**: 指数バックオフ（`IntervalSeconds × BackoffRate^n`）で再試行。Lambda の一時障害に対して有効。  
- **Catch**: `MaxAttempts` 超過後に `ErrorEquals` に一致したエラーを捕捉し、代替ステートへ遷移。Lambda 内 `try/except` をオーケストレーション層に引き上げる。

### Standard vs Express

| | Standard | Express |
|---|---|---|
| 最大実行時間 | 1 年 | 5 分 |
| 実行履歴 | AWS コンソールで完全保存 | CloudWatch Logs に保存 |
| 課金モデル | 状態遷移数 | 実行回数 × 実行時間 |
| 用途 | 長時間・冪等・監査が必要 | 高頻度・短命・低コスト |

---

## 主要な設定・API・パラメータ

### ASL 必須フィールド

| フィールド | 必須 | 説明 |
|---|---|---|
| `Type` | ○ | ステートの種類 |
| `Next` or `End` | ○ | 次ステート名 or `true` で終了 |
| `Resource` | Task のみ | 呼び出す ARN |
| `Choices` | Choice のみ | 条件ルールの配列 |
| `Branches` | Parallel のみ | 並列ブランチの配列 |
| `Iterator` | Map のみ | 各要素に適用するサブ SM |

### 代表的な比較演算子（Choice ステート）

`StringEquals` / `NumericGreaterThan` / `BooleanEquals` / `IsNull` / `TimestampLessThan`  
複合条件は `And` / `Or` / `Not` で組み合わせ可能。

### StartExecution API

```bash
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:ap-northeast-1:123456789012:stateMachine:MyMachine \
  --input '{"userId": "u001"}'
```

---

## よくある落とし穴・誤解

1. **Choice ステートに `End` は使えない** — 必ず `Next` で別ステートに遷移するか `Default` を設定する。設定漏れは実行時エラー。

2. **ResultPath を設定しないと元の入力が上書きされる** — デフォルト `ResultPath: "$"` はタスク結果で入力を完全に置き換えるため、後続ステートで元の値が消える。

3. **Parallel の全ブランチが成功しないと次ステートに進めない** — 1 ブランチが失敗すると Parallel ステート全体が失敗する。ブランチ内で Catch を設けて局所的に処理することを検討する。

4. **Lambda の 15 分タイムアウトと Task ステートのタイムアウトは別物** — `TimeoutSeconds` を Task ステートに設定しないと、Lambda が無応答でもデフォルト 1 年待ち続ける（Standard の場合）。

5. **Express はコンソールで実行履歴を確認できない** — CloudWatch Logs へのエクスポート設定を忘れると失敗の原因追跡が困難になる。

6. **Map の MaxConcurrency を指定しないと無制限並列** — 下流サービスのスロットリングを引き起こすことがある。

---

## このプロジェクト(AtCoder復習)での使いどころ

AtCoder 復習ツールのバックエンドでは現在 Lambda を個別に呼び出しているが、Phase 8 では以下のオーケストレーションを Step Functions で管理することを想定している。

```
Start
  └─ Task: SyncSubmissions (AtCoder スクレイピング)
       └─ Choice: 新規提出あり?
            ├─ Yes → Parallel
            │          ├─ Task: SaveSubmissions (DynamoDB 書き込み)
            │          └─ Task: TriggerReview  (SES/SNS 通知)
            └─ No  → Succeed
```

- **可視化**: コンソールで同期処理のどのステップで詰まったか即座に特定できる。  
- **Retry**: AtCoder HTML スクレイピングで一時的な接続エラーが起きても自動リトライ。  
- **Parallel**: DynamoDB 保存と通知送信を並列化してレイテンシを削減。  
- **Map**: 複数コンテスト分の提出を配列で受け取り、各コンテストを並列処理。

---

## デモで体験したこと

デモページ（`docs/learning/phase8/demo/index.html`）では、以下を操作して確認できる。

1. **ステップ遷移の可視化** — 「実行開始」ボタンを押すと `Start → ValidateInput → Choice → Process → Parallel → Map → Wait → Succeed` の順に `.flow-node.active` がハイライトされ、各ステートで JSON ペイロードの入力・出力がどう変化するかをリアルタイムで確認できる。

2. **ASL との対応** — 画面右の ASL JSON ペースト欄では現在実行中のステートの行が `.hl` でハイライトされ、宣言的な記述と実際の遷移が 1 対 1 で対応していることを体感できる。

3. **Retry/Catch の動作** — Task を意図的に失敗させると、指数バックオフで Retry が走り、上限超過後に Catch が発火してフォールバックブランチへ遷移する様子を確認できる。これにより Lambda 内の `try/except` との責務分担が視覚的に理解できる。

---

## 公式ドキュメント（出典）

- [What is Step Functions? — AWS Step Functions](https://docs.aws.amazon.com/step-functions/latest/dg/welcome.html)（閲覧日 2026-05-31）
- [Using Amazon States Language — AWS Step Functions](https://docs.aws.amazon.com/step-functions/latest/dg/concepts-amazon-states-language.html)（閲覧日 2026-05-31）
- [Step Functions states — AWS Step Functions](https://docs.aws.amazon.com/step-functions/latest/dg/concepts-states.html)（閲覧日 2026-05-31）
- [Handling errors in Step Functions workflows — AWS Step Functions](https://docs.aws.amazon.com/step-functions/latest/dg/concepts-error-handling.html)（閲覧日 2026-05-31）

---

## 関連・発展サービス

### Standard vs Express — 何を基準に選ぶか

表面的には「5 分制限かどうか」で語られるが、実際の選択基準はもっと多軸になる。

| 観点 | Standard | Express |
|---|---|---|
| 最大実行時間 | 1 年 | 5 分 |
| 実行セマンティクス | **Exactly-once** | **At-least-once** |
| 実行履歴保持 | 90 日（コンソール/API で参照可） | なし（CloudWatch Logs への書き出しが必須） |
| 料金 | 状態遷移数 × $0.025/1000 | 実行数 × 時間 × メモリ（Lambda 類似） |
| スループット | 2,000 req/s（緩和申請で増枠可） | 100,000 req/s |
| 向いている用途 | Saga・人手承認・長時間 ETL | IoT パイプライン・高頻度マイクロバッチ |

**なぜ Saga には Standard か**: Express は「At-least-once」なので、Lambda 側が冪等でないと重複課金・重複 INSERT が発生する。Saga は補償トランザクションという概念上「一度だけ実行されたことが追跡できる」ことが前提なので、Exactly-once の Standard が本命になる。  
**Standard のコスト地雷**: Map ステートで 1,000 アイテムを直列処理すると 1,000 回分の状態遷移が課金される。大量アイテムには後述の Distributed Map + Express の組み合わせへ移行するのが実務のパターン。

---

### SDK 統合（Optimized Integration） — Lambda なしで AWS API を直接呼ぶ

`Resource: "arn:aws:states:::dynamodb:putItem"` のような **Optimized Integration** を使うと Lambda を挟まずに DynamoDB・SQS・SNS・ECS・Glue・Bedrock などを直接呼べる。

```json
{
  "Type": "Task",
  "Resource": "arn:aws:states:::dynamodb:putItem",
  "Parameters": {
    "TableName": "phase8-orders",
    "Item": {
      "order_id": { "S.$": "$.order_id" },
      "status":   { "S": "CREATED" }
    }
  },
  "ResultPath": "$.dynamoResult",
  "Next": "NextState"
}
```

**メリット**: Lambda コールドスタートの排除・Lambda 課金ゼロ・シンプルな IAM 設計。  
**デメリット**: エラーハンドリングが粗い（AWS SDK エラーコードと States エラーのマッピングが必要）、ビジネスロジックが ASL に滲み出す。  
**つまずき**: `Parameters` 内のフィールドで `.$` サフィックスをつけないと参照ではなくリテラル文字列として扱われる。Visual Editor では自動補完があるが、JSON 手書き時は頻発するミス。慣れるまでは `"order_id": { "S.$": "$.order_id" }` と `"status": { "S": "CREATED" }` を並べて「ドル記号がない方はリテラル」と覚えるとよい。

---

### Map / Distributed Map — 並列ファンアウトの本命

`Map` ステートは配列の各要素を並列処理する。`MaxConcurrency: 10` で同時実行数を制御でき、下流 Lambda のスロットリングを防ぐ。

配列が数千件になると Standard の状態遷移コストが爆発する。ここで **Distributed Map**（2022 年末 GA）が登場する。S3 上の CSV/JSON/Parquet を直接ソースにして、チャイルドワークフローを最大 10,000 並列で起動できる。

```json
{
  "Type": "Map",
  "ItemReader": {
    "Resource": "arn:aws:states:::s3:getObject",
    "ReaderConfig": { "InputType": "CSV", "CSVHeaderLocation": "FIRST_ROW" },
    "Parameters": {
      "Bucket": "phase8-data",
      "Key.$": "$.s3_key"
    }
  },
  "MaxConcurrency": 100,
  "ToleratedFailurePercentage": 10,
  "ItemBatcher": { "MaxItemsPerBatch": 50 },
  "ItemProcessor": {
    "ProcessorConfig": { "Mode": "DISTRIBUTED", "ExecutionType": "EXPRESS" },
    "StartAt": "ProcessRecord",
    "States": { }
  }
}
```

`ToleratedFailurePercentage: 10` がポイント。全件失敗でなく 10% まで失敗を許容して残りを続ける。大規模 ETL で「1 件の壊れたレコードで全処理が止まる」問題を防ぐ。`ItemBatcher` で 50 件ずつバッチにまとめることで Lambda 呼び出し回数を削減し、コールドスタートのオーバーヘッドを圧縮できる。

---

### コールバック / waitForTaskToken — 非同期人手承認

```json
{
  "Type": "Task",
  "Resource": "arn:aws:states:::sqs:sendMessage.waitForTaskToken",
  "Parameters": {
    "QueueUrl": "https://sqs.ap-northeast-1.amazonaws.com/123456789012/approval-queue",
    "MessageBody": {
      "TaskToken.$": "$$.Task.Token",
      "OrderId.$":   "$.order_id",
      "Amount.$":    "$.amount"
    }
  },
  "HeartbeatSeconds": 3600,
  "TimeoutSeconds": 86400,
  "Next": "OrderApproved"
}
```

人手承認フローの典型: SQS に TaskToken を送る → Lambda で Slack/メール通知 → 承認者がボタンを押すと `send-task-success` が呼ばれてワークフロー再開。  
**HeartbeatSeconds を必ず入れる**: 省略すると Standard では最大 1 年待ち続けるためコストが膨らみ、タイムアウトによる再通知もできなくなる。  
承認期限切れは `HeartbeatTimeoutError` を Catch してリマインダ通知ステップに飛ばすか `OrderExpired` 状態に遷移させるのが実務標準のパターン。

**TaskToken の保存場所**: DynamoDB に格納してから Slack に送る順番が重要。Slack 送信を先にするとトークンが消えた場合に復旧不能になる。DynamoDB への Write に条件付き PutItem を使って重複防止するのが定石。

---

### EventBridge Pipes — Lambda グルーコード不要のイベント駆動接続

2023 年 GA の EventBridge Pipes を使うと DynamoDB Streams → フィルタリング → Step Functions をコード不要で繋げられる。

```hcl
resource "aws_pipes_pipe" "ddb_to_sfn" {
  name     = "phase8-ddb-stream-to-sfn"
  role_arn = aws_iam_role.pipes_exec.arn

  source = aws_dynamodb_table.orders.stream_arn
  source_parameters {
    dynamodb_stream_parameters {
      starting_position = "LATEST"
      batch_size        = 1
    }
    filter_criteria {
      filter {
        pattern = jsonencode({ eventName = ["INSERT"] })
      }
    }
  }

  target = aws_sfn_state_machine.order_saga.arn
  target_parameters {
    step_function_state_machine_parameters {
      invocation_type = "FIRE_AND_FORGET"
    }
  }
}
```

DynamoDB に新規レコードが INSERT されると自動でワークフローが起動する完全イベント駆動アーキテクチャ。`FIRE_AND_FORGET` vs `REQUEST_RESPONSE` の選択は「Pipe レベルで起動失敗を知りたいか」で決まる。  
**注意点**: Pipes 自体のログを CloudWatch に出す設定を忘れると、フィルタリングや変換がどう動いているかデバッグが困難になる。`log_configuration` ブロックを Terraform に必ず入れること。

---

### Step Functions Local — CI でのローカルテスト

```bash
# Docker で SFN Local を起動
docker run -p 8083:8083 \
  -e AWS_DEFAULT_REGION=ap-northeast-1 \
  amazon/aws-stepfunctions-local

# ローカルでステートマシンを作成
aws stepfunctions create-state-machine \
  --endpoint-url http://localhost:8083 \
  --name "local-order-saga" \
  --definition file://state_machine_definition.json \
  --role-arn "arn:aws:iam::123456789012:role/DummyRole"

# Mock Lambda レスポンスで実行
aws stepfunctions start-execution \
  --endpoint-url http://localhost:8083 \
  --state-machine-arn "arn:aws:states:ap-northeast-1:123456789012:stateMachine:local-order-saga" \
  --input '{"order_id":"local-test-001","amount":5000}'
```

Lambda のモックレスポンスは `MockConfigFile.json` で定義する。CI/CD パイプラインで AWS 接続不要なステートマシンロジックテストが可能になり、GitHub Actions で `state_machine_definition.json` の構文エラーをマージ前に検出できる。

---

## セキュリティ課題と対策

### 1. IAM の 2 層構造 — 「誰が SFN を起動するか」と「SFN が何を呼べるか」

Step Functions の IAM は 2 層になっている。混同するとどちらかに過剰権限を与えてしまう。

**呼び出し元ポリシー**（EventBridge や Lambda が SFN を起動する場合）:
```json
{
  "Action": "states:StartExecution",
  "Resource": "arn:aws:states:ap-northeast-1:123456789012:stateMachine:phase8-order-saga"
}
```
ステートマシン ARN を個別指定するのが鉄則。`"Resource": "*"` にするとアカウント内の全ステートマシンを起動できてしまう。

**ステートマシン実行ロール**（SFN が Lambda を呼ぶ場合）: 本 sandbox の `main.tf` を参照。`lambda:InvokeFunction` の Resource に `phase8-*` の ARN を個別列挙している。`*` にすると同アカウントの全 Lambda を呼べてしまうので関数 ARN を明示する。

**Condition: ArnLike による SourceArn 制約**: `assume_role_policy` の Condition に入れた `aws:SourceArn` が重要。SFN サービスが Assume Role する際に、どのステートマシンからの要求かを制約する。これを入れないと同アカウント内の他ステートマシンが同じロールを使い回せる。

---

### 2. 実行データのログ可視性 — 最大の盲点

```hcl
logging_configuration {
  include_execution_data = true   # ← これが諸刃の剣
  level                  = "ALL"
}
```

`include_execution_data = true` にすると、**ステートマシンへの入力・各ステートの出力・エラー詳細がすべて CloudWatch Logs に書き込まれる**。デバッグには非常に便利だが、入力に PII・クレカ番号・パスワードが含まれる場合、ログ経由で情報漏洩する。

**対策パターン（優先順位順）**:

1. **入力サニタイズ**: 最初の ValidateOrder ステート内で機微フィールドを削除/マスクし、後続ステートに渡さない（最も根本的な対策）
2. **ログレベルを ERROR に下げる**: `level = "ERROR"` にすると失敗時のみログが出る。成功時の機微データはログに残らない。運用可観測性と機密保護のトレードオフ
3. **CloudWatch Logs の KMS 暗号化**: 本 sandbox で実施済み。ログ自体を暗号化することで「ログへのアクセス = KMS デクリプト権限が必要」という防御層を追加
4. **ログアクセス IAM の最小化**: CloudWatch Logs へのアクセスを特定の IAM ロール・Principal のみに付与

```bash
# ログに含まれる機微データを確認するコマンド（destroy 前の確認用）
aws logs filter-log-events \
  --log-group-name "/aws/states/phase8-order-saga" \
  --filter-pattern "{ $.type = \"ExecutionStarted\" }" \
  --query "events[0].message" \
  --output text | jq .
```

---

### 3. X-Ray トレース — セキュリティの二面性

X-Ray は便利だが、トレースデータにも入出力データが含まれる場合がある。特に Lambda Powertools を使うと `@tracer.capture_method` アノテーションがメソッドの引数を自動でトレースセグメントに付与する設定があるので注意が必要。

**X-Ray の機密データマスク**: Powertools は `capture_response=False` オプションで応答データをトレースから除外できる。

```python
from aws_lambda_powertools import Tracer
tracer = Tracer()

@tracer.capture_lambda_handler(capture_response=False)  # レスポンスをトレースに含めない
def lambda_handler(event, context):
    ...
```

**X-Ray トレースの KMS 暗号化**: X-Ray コンソール → 暗号化設定 → CMK 指定、または Terraform で:

```hcl
resource "aws_xray_encryption_config" "phase8" {
  type   = "KMS"
  key_id = aws_kms_key.phase8.arn
}
```

トレースデータはデフォルトで AWS マネージドキーで暗号化されているが、CMK に切り替えると「トレース参照 = KMS 権限が必要」という統制が加わる。

---

### 4. VPC 内 Lambda と Step Functions エンドポイント

Lambda を VPC 内に配置する場合、Step Functions が Lambda を呼び出すためには **Interface Endpoint**（PrivateLink）が必要。ないと Step Functions サービスからの呼び出しがインターネット経由になる。

```hcl
resource "aws_vpc_endpoint" "sfn" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.ap-northeast-1.states"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true
}
```

**つまずき**: VPC エンドポイントを作っても、セキュリティグループが HTTPS:443 をブロックしていると繋がらない。エンドポイントの SG インバウンドに「Lambda の SG からの 443」を許可するのを忘れがち。エンドポイントの SG と Lambda の SG が別物なので、双方向の参照を設計する。

---

### 5. 実行クォータとスロットリング対策

Standard ステートマシンの状態遷移は **リージョン単位で 5,000 req/s**（緩和申請で 100,000 まで可）。Distributed Map などで大量の子ワークフローを起動すると `ThrottlingException` が出る。

```json
"Retry": [
  {
    "ErrorEquals": ["States.ExceedToleratedFailureThreshold", "States.RuntimeExceeded", "ThrottlingException"],
    "IntervalSeconds": 5,
    "MaxAttempts": 5,
    "BackoffRate": 2.0,
    "JitterStrategy": "FULL"
  }
]
```

本番では CloudWatch Metric `ThrottledRequests`（Namespace: `AWS/States`）にアラームを張り、閾値超過前にクォータ緩和申請を行う。

---

## インフラ応用パターン

### Saga パターン — なぜ Step Functions が最適解か

マイクロサービス間の分散トランザクションで ACID を保証する手段として Saga パターンがある。2 フェーズコミット（2PC）の代替で、各ステップが失敗したら逆順で補償トランザクションを実行する。

**Step Functions が Saga に向いている理由**:
- 実行履歴が 90 日間保存され、どこで失敗したか完全に追跡できる
- `Catch` → 補償ステートへの遷移が ASL で宣言的に書ける（補償ロジックをアプリコードから分離できる）
- Lambda の冪等性さえ担保すれば Exactly-once の処理保証が得られる

**補償設計の要点**:

- 補償は「べき等であること」が前提。ChargePayment の補償（払い戻し）を 2 回実行しても安全な設計が必要。DynamoDB の条件付き書き込み（`ConditionExpression`）が鍵になる:

```python
# compensate_order_handler の中
dynamodb.update_item(
    TableName=os.environ["ORDERS_TABLE"],
    Key={"order_id": {"S": order_id}},
    UpdateExpression="SET #s = :cancelled",
    ConditionExpression="attribute_exists(order_id) AND #s <> :cancelled",
    ExpressionAttributeNames={"#s": "status"},
    ExpressionAttributeValues={":cancelled": {"S": "CANCELLED"}},
)
```

- **補償ステート自体が失敗した場合の設計を忘れない**: CompensateOrder が失敗すると「補償も失敗した中途半端な状態」が無音で放置される。CloudWatch Alarm + SNS 通知で必ず気づける仕組みを用意する

---

### 人手承認ワークフロー — Slack ボタン統合の実装パターン

実務でよく出る「金額が 10 万円超えたら上長承認が必要」パターン:

```
[Amount Check] --超過--> [Send Slack DM with TaskToken] --waitForTaskToken-->
  --approve--> [Process Order]
  --reject-->  [Cancel Order]
  --timeout (HeartbeatTimeoutError)--> [Remind Manager] --> [Send Slack DM with TaskToken]
```

Slack Bolt + Lambda で `send-task-success` / `send-task-failure` を呼ぶ実装。

```python
# Slack の承認ボタン押下時
import boto3
sfn = boto3.client("stepfunctions")

@app.action("approve_order")
def handle_approve(ack, body):
    ack()
    task_token = body["actions"][0]["value"]  # Slack メッセージに埋め込んだトークン
    sfn.send_task_success(
        taskToken=task_token,
        output=json.dumps({"approved": True, "approver": body["user"]["name"]})
    )
```

```bash
# CLI で手動承認する場合（テスト時に便利）
aws stepfunctions send-task-success \
  --task-token "AQDkAAAAKgAAAAAAAA..." \
  --task-output '{"approved": true}'
```

TaskToken の保存: DynamoDB に格納してから Slack に送る順番が重要。Slack 送信が失敗した場合でも DynamoDB からトークンを取り出してリトライできる。

---

### ETL オーケストレーション — Glue + Distributed Map

```
[Trigger from S3 Event]
  --> [List S3 Objects] (SDK Integration)
  --> [Distributed Map: MaxConcurrency=50]
      --> [Glue Job per partition] (arn:aws:states:::glue:startJobRun.sync)
  --> [Aggregate Results]
  --> [Update Data Catalog]
```

`.sync` サフィックスで Glue ジョブの完了を待てる。Lambda でポーリングするグルーコードが不要になり、Glue の実行ログも X-Ray サービスマップに統合される。

**コスト最適化**: Glue G.025X（0.25 DPU）で足りるジョブを G.1X で動かすと 4 倍の課金。Step Functions オーケストレーション層でジョブサイズを動的に選択する設計が実務では有効:

```json
{
  "Type": "Choice",
  "Choices": [
    {
      "Variable": "$.file_size_mb",
      "NumericLessThan": 100,
      "Next": "GlueJobSmall"
    }
  ],
  "Default": "GlueJobLarge"
}
```

---

### Retry/Catch の設計論 — エラーカテゴリ別に分ける

`States.ALL` で全エラーに同一リトライ設定を入れるのは初期実装として悪くないが、本番では分けて考える:

| エラーカテゴリ | 推奨 | 理由 |
|---|---|---|
| `Lambda.ServiceException` | Retry 3 回 / 指数 2x / JitterStrategy FULL | AWS 側の一時障害 |
| `Lambda.AWSLambdaException` | Retry 1 回のみ | アプリ例外の可能性大。過剰リトライは副作用を生む |
| `Lambda.TooManyRequestsException` | Retry 5 回 / 指数 2x / Jitter FULL | スロットリングには長めの待機が必要 |
| `States.TaskFailed` | Catch して補償ステートへ | ビジネスロジック失敗はリトライより補償 |
| `States.Timeout` | Catch してアラート | タイムアウトはリトライより原因調査を優先 |

`JitterStrategy: "FULL"` を全 Retry に入れるのが現代の標準。均一なバックオフは Thundering Herd（一斉リトライによる再スロットリング）を引き起こす。FULL Jitter は `[0, interval × backoffRate^n]` の一様分布でリトライタイミングを散らす。

---

### 長時間ワークフローの罠 — Wait ステートの活用

Standard は最大 1 年間実行できるが、料金は **状態遷移回数**に比例する。`Wait` ステートは遷移回数に**カウントされない**ため、長時間待機は `Wait` で実装するのが鉄則。

```json
{
  "Type": "Wait",
  "Seconds": 86400,
  "Next": "CheckDeadline"
}
```

あるいは `TimestampPath: "$.deadline"` で特定の日時まで待機することもできる。

```json
{
  "Type": "Wait",
  "TimestampPath": "$.deadline",
  "Next": "SendReminder"
}
```

**つまずき**: `Wait` 中は実行が「Running」状態のまま残るため、コンソールの実行リストが大量の「実行中」で埋まる。Dashboard でフィルタリングして「RUNNING 件数」を可視化しておくと管理しやすい。

---

### 追加: X-Ray Groups + Sampling Rules でエラーに集中する

本番運用時にすべてのトレースを保存するとコストが爆発する。Sampling Rules でエラーを優先的にサンプリングする設計が有効:

```hcl
resource "aws_xray_sampling_rule" "phase8_errors_full" {
  rule_name      = "phase8-errors-full-sample"
  priority       = 100                          # 低い数字ほど優先
  reservoir_size = 5
  fixed_rate     = 1.0                          # エラーは 100% サンプリング
  url_path       = "*"
  host           = "*"
  http_method    = "*"
  service_type   = "AWS::StepFunctions::StateMachine"
  service_name   = "phase8-order-saga"
  resource_arn   = "*"
  version        = 1
  attributes = {
    "http.status" = "5*"                        # 5xx のみ対象
  }
}

resource "aws_xray_sampling_rule" "phase8_normal" {
  rule_name      = "phase8-normal-low-sample"
  priority       = 200
  reservoir_size = 2
  fixed_rate     = 0.05                         # 正常系は 5% のみ
  url_path       = "*"
  host           = "*"
  http_method    = "*"
  service_type   = "AWS::StepFunctions::StateMachine"
  service_name   = "phase8-order-saga"
  resource_arn   = "*"
  version        = 1
}
```

X-Ray Groups の `filter_expression` と組み合わせると、エラーが発生したトレースだけを抽出したビューを常時表示しておける。CloudWatch Insights との統合で「エラーが増え始めたタイムスタンプ」を特定し、X-Ray でそのタイムスタンプ前後のトレースを掘り下げる、という運用フローが実務の標準になりつつある。
