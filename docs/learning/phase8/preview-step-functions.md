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
