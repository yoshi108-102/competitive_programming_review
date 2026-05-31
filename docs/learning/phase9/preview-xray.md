# Phase 9 プレビュー教材: X-Ray — 分散トレースを読む

> プレビュー教材: デモ体験のために先行生成しました。正式な lesson / 振り返りクイズ / 採点は Phase 9 到達時に実施します。

---

## このサービスは何か

AWS X-Ray は、分散アプリケーションのリクエストを **エンドツーエンドでトレース** するサービスです。単一リクエストが複数のサービス（API Gateway → Lambda → DynamoDB → 外部 HTTP）を通過するとき、それぞれの処理時間・成功／失敗・付帯情報を 1 本のトレースとして記録・可視化します。

X-Ray が提供する主な機能は次の 3 つです。

| 機能 | 説明 |
|---|---|
| **トレース収集** | SDK / X-Ray デーモンを介してセグメントを送信・保存 |
| **サービスマップ** | サービス間の依存関係をグラフで俯瞰し、ボトルネック・エラー源を特定 |
| **タイムラインビュー** | 1 リクエスト内の処理をウォーターフォール形式でレイテンシ内訳を確認 |

---

## いつ使うか・使わないか

### 使うべき場面

- **レイテンシ増大の原因特定**: 複数サービスのどこで時間がかかっているかを即座に絞り込みたい
- **エラー発生箇所の特定**: 5xx/4xx がどのサービス・処理で起きているかを追跡したい
- **非同期処理のフロー把握**: SQS・Step Functions 経由の処理でもトレース ID を引き継いで追跡できる
- **外部 API 呼び出しの監視**: AtCoder API など外部 HTTP へのレイテンシ・失敗率を把握したい

### 使わない（他の手段が適切な）場面

- **ビジネスメトリクス集計**: CloudWatch Metrics / Logs Insights の方が向いている
- **セキュリティ監査ログ**: CloudTrail が担う領域
- **詳細なアプリケーションログ**: CloudWatch Logs で十分（X-Ray トレースと補完関係）

---

## コアコンセプト

### トレース・セグメント・サブセグメント

```
Trace（1 リクエスト全体）
├── Segment: API Gateway
├── Segment: Lambda (handler)
│   ├── Subsegment: DynamoDB.GetItem
│   ├── Subsegment: DynamoDB.PutItem
│   └── Subsegment: HTTP GET https://atcoder.jp/...
└── Segment: (レスポンス返却)
```

- **Trace**: 1 つのリクエスト全体を一意の Trace ID で束ねる単位
- **Segment**: サービス（Lambda 関数など）が X-Ray に送信するデータの基本単位。開始時刻・終了時刻・HTTP 情報・エラー有無を含む
- **Subsegment**: Segment 内部のさらに細かい処理単位。AWS SDK 呼び出しや外部 HTTP リクエストが自動的にサブセグメント化される

### サンプリング

X-Ray はデフォルトですべてのリクエストを記録しません。**サンプリングルール** によって記録対象を絞ります。

- デフォルト: 毎秒 1 リクエスト + その後の 5% をサンプリング
- カスタムルール: パス・メソッド・ホストで条件を指定し、rate（割合）と reservoir（毎秒固定数）を設定
- **目的**: 本番トラフィックが大量でもコストを抑えながら代表的なトレースを取得する

### Annotation と Metadata

| 項目 | インデックス | 検索 | 用途例 |
|---|---|---|---|
| **Annotation** | される | フィルタ式で検索可能 | `user_id`, `contest_id`, `status_code` |
| **Metadata** | されない | 検索不可（トレース詳細でのみ閲覧） | デバッグ用の大きなオブジェクト、リクエストボディ |

Annotation はトレースをフィルタするためのキーとして使い、Metadata は詳細デバッグ情報の保存に使います。

### サービスマップ

- サービス（Lambda, DynamoDB, 外部 HTTP など）をノード、呼び出し関係をエッジで表したグラフ
- 各エッジに **平均レイテンシ** と **エラー率** が表示される
- ノードをクリックすると該当サービスのトレース一覧にドリルダウンできる

---

## 主要な設定・API・パラメータ

### X-Ray SDK（Python の場合）

```python
from aws_xray_sdk.core import xray_recorder, patch_all

# AWS SDK (boto3) の呼び出しを自動的にサブセグメント化
patch_all()

# カスタムサブセグメント
with xray_recorder.in_subsegment('fetch-atcoder-submissions') as subsegment:
    subsegment.put_annotation('user_id', user_id)
    subsegment.put_metadata('request_params', params)
    # ... 処理 ...
```

### Lambda での有効化

```hcl
# Terraform
resource "aws_lambda_function" "example" {
  # ...
  tracing_config {
    mode = "Active"   # Active | PassThrough
  }
}
```

| mode | 動作 |
|---|---|
| `Active` | サンプリングルールにかかわらずトレースを送信 |
| `PassThrough` | アップストリームからトレースヘッダーが来たときのみ送信 |

### サンプリングルール（主要パラメータ）

| パラメータ | 説明 |
|---|---|
| `reservoir_size` | 毎秒必ず記録するリクエスト数（固定枠） |
| `fixed_rate` | 固定枠を超えた分のサンプリング割合（0.0〜1.0） |
| `host`, `url_path`, `http_method` | ルール適用条件のフィルタ |
| `priority` | ルールの優先順位（数値が低いほど高優先） |

### フィルタ式（コンソール検索）

```
annotation.user_id = "12345"
service("my-lambda") { error = true }
responsetime > 2
```

---

## よくある落とし穴・誤解

**1. "Active" にしたのにトレースが出ない**
Lambda の実行ロールに `xray:PutTraceSegments` と `xray:PutTelemetryRecords` の権限が必要です。IAM ポリシーの `AWSXRayDaemonWriteAccess` マネージドポリシーを付与してください。

**2. サンプリングで重要なリクエストが欠ける**
デフォルトのサンプリング率（5%）では、低トラフィック時にエラートレースが記録されないことがあります。開発環境では `fixed_rate = 1.0` にするか、エラーパスにカスタムルールを設定してください。

**3. Annotation と Metadata を混同する**
コンソールのフィルタ検索で絞り込みたい値（user_id, contest など）は必ず Annotation に入れます。Metadata に入れると検索できません。

**4. Cold Start が別セグメントに見える**
Lambda の初期化フェーズ（Cold Start）は `Initialization` サブセグメントとして表示されます。関数本体の実行時間とは別カウントなので、レイテンシ分析時は両方を確認してください。

**5. X-Ray デーモンが不要なケース**
Lambda と API Gateway は X-Ray デーモンを自前で持つため、アプリ側での起動は不要です。EC2/ECS で動かす場合はデーモンプロセスの起動が必要です。

---

## このプロジェクト（AtCoder 復習）での使いどころ

AtCoder 復習ツールは `API Gateway → Lambda → DynamoDB` と外部 HTTP（AtCoder API）が絡む典型的な分散構成です。X-Ray を導入すると以下が可能になります。

- **提出履歴取得の遅延分析**: `sync_submissions` Lambda が AtCoder API を呼ぶ外部 HTTP 時間と DynamoDB への書き込み時間を分離して把握できる
- **ユーザーごとの処理時間追跡**: `user_id` を Annotation に付けることで、特定ユーザーのリクエストだけをフィルタしてトレースを確認できる
- **DynamoDB スロットリングの即時検知**: スロットリングが発生したセグメントは Fault としてマークされ、サービスマップ上でノードが赤くなることで一目で把握できる
- **段階的なボトルネック解消**: フェーズ 1 で作った Lambda の処理のどこに時間がかかっているかを、コードを変えずにまず可視化できる

---

## デモで体験したこと

`docs/learning/phase9/demo/index.html` のデモでは、「リクエスト実行」ボタンを押すことで `API Gateway → Lambda → DynamoDB → 外部 HTTP` の一連のトレースが生成されます。タイムライン上のウォーターフォール（各セグメント/サブセグメントを横棒で表示）から、どのサービスでどれだけの時間がかかったかを視覚的に確認できます。各バーをクリックすると duration・レスポンスコード・Annotation・Metadata の詳細が展開され、Annotation のインデックス性と Metadata の非検索性の違いが実感できます。また「障害を注入」機能で DynamoDB スロットリングを起こすと、該当セグメントが赤くハイライトされ、サービスマップのノードも赤化することで、エラー源の特定がいかに直感的かを体験できます。

---

## 公式ドキュメント（出典）

- https://docs.aws.amazon.com/xray/latest/devguide/aws-xray.html（閲覧日 2026-05-31）
- https://docs.aws.amazon.com/xray/latest/devguide/xray-concepts.html（閲覧日 2026-05-31）
- https://docs.aws.amazon.com/xray/latest/devguide/xray-console-servicemap.html（閲覧日 2026-05-31）
- https://docs.aws.amazon.com/xray/latest/devguide/xray-concepts.html#xray-concepts-annotations（閲覧日 2026-05-31）

---

## 関連・発展サービス

### CloudWatch ServiceLens — X-Ray をチームで「使いやすくする」レイヤー

X-Ray コンソールはエンジニア向けの生データ表示で、ルーティングや絞り込みに慣れが必要だ。CloudWatch ServiceLens はその上に「AWS の運用 UI」を被せた統合ビュー。`CloudWatch > ServiceLens > Service Map` を開くと、X-Ray トレースから自動生成されたノードグラフに、リクエスト数・平均レイテンシ・エラー率のメトリクスがオーバーレイされる。

実務での利点は「コンテキストジャンプ」にある。DynamoDB ノードをクリックすると、そのサービスに紐付くトレース・Logs Insights クエリ・CloudWatch メトリクスへのリンクがすべて一画面に集まる。「DynamoDB のレイテンシが急騰したトレースを絞り込んで原因 Lambda を特定する」という操作が、画面遷移なく 3 クリックで完結する。チームで障害対応するときに「X-Ray 画面を共有する」より「ServiceLens の URL を貼る」方が伝わりやすい。

### Application Signals（2024年 GA）— SLO 管理の新機能

Application Signals は X-Ray + CloudWatch の上に SLO（Service Level Objective）を重ねる。`CloudWatch > Application Signals > Services` から対象サービスを選び、「p99 レイテンシ < 500ms」「エラー率 < 0.1%」という目標を設定すると、SLO Burn Rate アラームが自動で生成される。ADOT（AWS Distro for OpenTelemetry）で計装すると、コード変更なしでこのダッシュボードに乗ってくる。

つまずきポイント: Lambda に対して Application Signals を有効にするには ADOT Lambda Layer の特定バージョン以降が必要で、Python 3.12 と Layer バージョンの組み合わせに注意が要る。互換マトリクスは [公式ページ](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Application-Signals-Enable-Lambda.html) で随時更新されている。

### ADOT（AWS Distro for OpenTelemetry）— ベンダーロックインを避けつつ X-Ray に送る

aws-xray-sdk で書いたコードは X-Ray 専用になる。将来 Datadog や Grafana Tempo に移行するとき、SDK 依存の計装コードを書き直すコストが発生する。ADOT は OpenTelemetry の AWS フォークで、Lambda Layer として付けるだけで SDK 依存なしにトレースを送れる。エクスポーター先を `collector.yaml` で切り替えられるため、移行時にアプリコードは無変更で済む。

```hcl
# ADOT Layer (ap-northeast-1, Python 3.12, 2025年時点の例)
resource "aws_lambda_function" "producer_adot" {
  # ...
  layers = [
    "arn:aws:lambda:ap-northeast-1:901920570463:layer:aws-otel-python-amd64-ver-1-24-0:1"
  ]
  environment {
    variables = {
      AWS_LAMBDA_EXEC_WRAPPER            = "/opt/otel-instrument"
      OPENTELEMETRY_COLLECTOR_CONFIG_URI = "/var/task/collector.yaml"
    }
  }
}
```

`collector.yaml` でエクスポーター先を `awsxray` と `otlp`（Grafana Cloud など）の両方に向けることもできる。「今は X-Ray、将来は別ツール」という段階的移行が現実的になる。

### X-Ray Insights — 異常検知の自動化

X-Ray Insights は正常時のトレースパターンを機械学習で学習し、エラー率やレイテンシが統計的に逸脱したタイミングで自動的に「Insight イベント」を生成する。CloudWatch EventBridge と連携して Slack 通知を飛ばすことも可能だ。

Terraform での有効化:

```hcl
resource "aws_xray_group" "phase9" {
  group_name        = "phase9-group"
  filter_expression = "annotation.function = \"producer\" OR annotation.function = \"consumer\""

  insights_configuration {
    insights_enabled      = true
    notifications_enabled = true  # EventBridge にイベントを投げる
  }
}
```

注意: Insights が精度の高いベースラインを学習するには数日〜1週間のトレース蓄積が必要。起動直後の sandbox ではほぼ機能しないが、本番運用開始後に有効化するタイミングを知っておくと役立つ。

### サンプリングルール設計論 — 「全量とれば安心」は幻想

本番環境では高トラフィックサービスで全量トレースを取ると X-Ray のコストと Storage が爆発する。設計の基本方針は「重要パスは reservoir で固定枠を確保、ノイズパスは間引く」。

| パターン | reservoir_size | fixed_rate | 用途 |
|---|---|---|---|
| 全量（デバッグ中） | 999999 | 1.0 | 負荷が低い・障害調査中のみ |
| 重要エンドポイント | 10 | 0.10 | /checkout・/payment など |
| ヘルスチェック間引き | 0 | 0.01 | /health の過剰トレースを防ぐ |
| バッチ処理 | 1 | 0.05 | SQS/Batch のバックグラウンド処理 |

落とし穴: サンプリングルールは X-Ray サービスが中央集権的に配布する。SDK がルールを取得するために `xray:GetSamplingRules` と `xray:GetSamplingTargets` の **両方** が IAM で必要。片方だけ許可している場合、サンプリングルールが取得できずにデフォルトルール（毎秒 1 件 + 5%）にフォールバックし、「カスタムルールが効いていない」と長時間気づかないケースが多い。

### Lambda Powertools Tracer — 実務での事実上の標準

aws-xray-sdk を直接使うよりも、Lambda Powertools の `Tracer` クラスを経由する方が現場では一般的だ。デコレータベースで計装でき、Logger・Metrics と組み合わせると「トレース ID をログに自動埋め込み」「エラー時に自動フラグ」が無設定で手に入る。

```python
from aws_lambda_powertools import Tracer, Logger

tracer = Tracer(service="phase9-producer")
logger = Logger(service="phase9-producer")

@tracer.capture_lambda_handler
@logger.inject_lambda_context(log_event=True)
def handler(event: dict, context) -> dict:
    return _process(event)

@tracer.capture_method   # このメソッドが自動でサブセグメントになる
def _process(event: dict) -> dict:
    # ... 処理 ...
```

Terraform での Layer 指定:

```hcl
resource "aws_lambda_function" "producer_powertools" {
  # ...
  layers = [
    # Powertools for Python v3 マネージド Layer (ap-northeast-1)
    "arn:aws:lambda:ap-northeast-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-arm64:7"
  ]
  environment {
    variables = {
      POWERTOOLS_SERVICE_NAME = "phase9-producer"
      LOG_LEVEL               = "INFO"
    }
  }
}
```

参考: https://docs.powertools.aws.dev/lambda/python/latest/#lambda-layer（Layer ARN はリージョン・バージョンで変わるため常にここを確認）

---

## セキュリティ課題と対策

### 課題1: トレースデータに機微情報が乗りうる

`patch_all()` や ADOT の自動計装は便利だが、意図せず個人情報がトレースに記録されることがある。具体的には:

- DynamoDB の `put_item` パラメータ（個人情報の属性値が含まれる場合）
- HTTP クライアントのリクエスト URL（クエリパラメータにトークンが入っている場合）
- SQS メッセージボディ（aws-xray-sdk はデフォルトで記録しないが SDK バージョンで挙動が異なる）

対策は「メタデータに何を入れるかを明示的に制御する」こと:

```python
from aws_xray_sdk.core import xray_recorder

segment = xray_recorder.current_segment()
# 良い例: 検索に必要な識別子だけ Annotation に
segment.put_annotation("user_id", event.get("user_id"))
segment.put_annotation("item_id", item_id)
# 悪い例: event 全体を Metadata に入れると機微情報が乗る可能性がある
# segment.put_metadata("event", event)  ← PII レビューなしでは危険
```

### 課題2: X-Ray トレースへのアクセス制御が甘くなりがち

X-Ray データの読み取り権限は `xray:GetTraceSummaries`・`xray:BatchGetTraces`・`xray:GetServiceGraph` で制御する。「開発者全員に ReadOnly を付与」する前に、「そのトレースにどんな情報が乗っているか」を棚卸しすること。最低限の対策として、本番アカウントと開発アカウントを分離し、本番トレースを開発者が参照できないポリシー（SCP）を AWS Organizations で適用する。

```json
// SCP: 本番アカウントへの X-Ray 読み取りを制限する例
{
  "Effect": "Deny",
  "Action": [
    "xray:GetTraceSummaries",
    "xray:BatchGetTraces",
    "xray:GetServiceGraph"
  ],
  "Resource": "*",
  "Condition": {
    "ArnNotLike": {
      "aws:PrincipalArn": "arn:aws:iam::*:role/ProdReadOnlyRole"
    }
  }
}
```

### 課題3: KMS 暗号化の「既存トレースは再暗号化されない」落とし穴

本 Phase の構成では X-Ray の暗号化設定に KMS CMK を指定している。よくあるミスは「KMS キーを変更したら既存トレースが自動で再暗号化される」という誤解。X-Ray の暗号化設定は **新しく書き込まれるトレースにのみ適用** される。既存トレースの再暗号化は不可能。CMK を無効化・削除すると旧キーで暗号化された既存トレースが読めなくなる。キーローテーション後もしばらくは旧キーを有効にしたまま運用する必要がある。

### 課題4: X-Ray への書き込みを特定 Lambda のみ許可したい問題

IAM の `aws:SourceArn` 条件を `xray:PutTraceSegments` に付けようとすると「X-Ray はリソースレベルのアクセス制御をサポートしていない」という壁にぶつかる。X-Ray の既知制約で、Resource に `*` 以外を指定できない。ワークアラウンドとして VPC エンドポイントポリシーで送信元 VPC を制限する方法がある:

```hcl
resource "aws_vpc_endpoint_policy" "xray" {
  vpc_endpoint_id = aws_vpc_endpoint.xray.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
      Resource  = "*"
      Condition = {
        StringEquals = {
          "aws:SourceVpc" = aws_vpc.phase9.id
        }
      }
    }]
  })
}
```

「Lambda を VPC 内に配置 + X-Ray VPC エンドポイント」の組み合わせで、特定 VPC からの書き込みのみを許可する。ただし Lambda を VPC に入れると Cold Start が増える（ENI アタッチ時間）トレードオフがある。Hyperplane ENI（デフォルト有効）でほぼ解消されているが、アカウントの設定を確認すること。

### 課題5: サンプリング率低下による「漏洩リスク低減」

逆説的だが、サンプリング率を下げることで「外部漏洩するトレースの絶対量」も減る。PCI-DSS 対応が必要な決済フローは `/payment` パスのサンプリング率を `fixed_rate = 0.01` にする設計が選択肢になる。ただし問題発生時にトレースがなければデバッグが困難なため、CloudWatch アラーム発火をトリガーに「一時的にサンプリングルールを書き換える」RunBook（手順書）を用意しておくこと。

---

## インフラ応用パターン

### パターン1: SQS 経由のトレース ID 伝播設計

本 Phase の `producer → SQS → consumer` チェーンで、最も引っかかりやすいのが「SQS を挟んだらトレースが断絶する」問題だ。HTTP では `X-Amzn-Trace-Id` ヘッダが自動伝播されるが、SQS はメッセージキューのため **手動でメッセージ属性にトレース ID を乗せる** 必要がある。

```python
# producer 側: SQS 送信時にトレース ID を属性として埋め込む
sqs.send_message(
    QueueUrl=QUEUE_URL,
    MessageBody=json.dumps({"item_id": item_id}),
    MessageAttributes={
        "X-Amzn-Trace-Id": {
            "DataType": "String",
            "StringValue": xray_recorder.current_segment().trace_id
        }
    }
)

# consumer 側: 属性から読み取って Annotation に記録
trace_id = record.get("messageAttributes", {}).get(
    "X-Amzn-Trace-Id", {}).get("stringValue", "unknown")
xray_recorder.current_segment().put_annotation("upstream_trace_id", trace_id)
```

2024 年以降、aws-xray-sdk は SQS の自動伝播を一部サポートし始めたが、SDK バージョンと SQS のトリガー設定によって挙動が変わる。確実に繋げたいなら上記の手動伝播を明示的に書く方が安全だ。ADOT を使う場合は W3C TraceContext ヘッダ（`traceparent`）での自動伝播が可能で、より標準的なアプローチになる。

### パターン2: コールドスタート分析と Provisioned Concurrency のビフォーアフター

Lambda コールドスタートは X-Ray のタイムラインで `Initialization` サブセグメントとして可視化される。CloudWatch Logs に出力される `Init Duration` と合わせると全体像がつかめる。

```
# コールドスタートあり（X-Ray タイムライン）
[Initialization: 850ms][Handler: 120ms] ← 合計 970ms
Duration メトリクス: 120ms（Initは含まれない！）
Init Duration (Logs): 850ms

# コールドスタートなし（Provisioned Concurrency 有効後）
[Handler: 95ms]
Initialization サブセグメントが消える
```

Duration メトリクスが同じでも、X-Ray で `Initialization` の有無を確認することで「Provisioned Concurrency が機能しているか」を視覚的に検証できる。コスト正当化の根拠として「ビフォーアフター」をスクリーンショットで保存すると有用だ。

```hcl
# Provisioned Concurrency（extra-credit。sandbox では高コストなので任意）
resource "aws_lambda_alias" "producer_live" {
  name             = "live"
  function_name    = aws_lambda_function.producer.function_name
  function_version = aws_lambda_function.producer.version
}

resource "aws_lambda_provisioned_concurrency_config" "producer" {
  function_name                     = aws_lambda_function.producer.function_name
  qualifier                         = aws_lambda_alias.producer_live.name
  provisioned_concurrent_executions = 2
}
```

### パターン3: カスタムサブセグメントでボトルネックを ms 単位で特定

`watch.sh` でも確認できるが、Lambda 全体の Duration メトリクスは「関数が何 ms かかったか」しか教えてくれない。処理のどこが遅いかは X-Ray のカスタムサブセグメントで初めてわかる。

```python
with xray_recorder.in_subsegment("schema-validation") as subsegment:
    subsegment.put_annotation("input_size_bytes", len(body_raw))
    validated = validate_schema(body)   # バリデーションに何 ms?

with xray_recorder.in_subsegment("external-api-call") as subsegment:
    subsegment.put_annotation("endpoint", "atcoder.jp")
    result = fetch_atcoder_submissions(user_id)  # 外部 API に何 ms?

with xray_recorder.in_subsegment("dynamodb-batch-write") as subsegment:
    subsegment.put_annotation("item_count", len(result))
    write_to_dynamodb(result)  # DB 書き込みに何 ms?
```

タイムライン上でこれらが横棒として並ぶため、「DynamoDB が遅い」と思っていたら実は「外部 API 呼び出し」が全体の 80% を占めていた、という発見が実務でよくある。

### パターン4: Step Functions との連携 — 手動伝播の苦労がなくなる

Lambda + SQS の非同期チェーンで手動伝播が必要な X-Ray に対し、Step Functions はネイティブ統合を持つ。`aws_sfn_state_machine` の `tracing_configuration { enabled = true }` を付けるだけで、ステートマシンの各ステート（Task・Choice・Wait・Parallel）がサブセグメントとして自動的に現れる。

```hcl
resource "aws_sfn_state_machine" "phase9_workflow" {
  name     = "phase9-workflow"
  role_arn = aws_iam_role.sfn.arn

  tracing_configuration {
    enabled = true  # これだけで全ステートが X-Ray に乗る
  }

  definition = jsonencode({ ... })
}
```

「どのステートで 3 分詰まっているか」が Service Map でノードとして見えるため、SQS 経由の複雑な伝播設計なしに分散処理をトレースできる。Lambda + SQS より Step Functions + Lambda の方が X-Ray との相性は格段に良い。

### パターン5: X-Ray Group + エラー専用 Service Map

エラートレースだけを絞り込んだ Service Map を作ると、障害対応時間を大幅に短縮できる。

```hcl
resource "aws_xray_group" "errors_only" {
  group_name        = "phase9-errors"
  filter_expression = "fault = true OR error = true"

  insights_configuration {
    insights_enabled      = true
    notifications_enabled = true
  }
}
```

コンソールの `X-Ray > Groups` でこのグループを選択すると、エラーが発生したトレースだけの Service Map が表示される。「全トレースの Service Map」では正常リクエストに埋もれていたエラーノードが浮き上がる。障害対応の初動で「どのサービスが赤くなっているか」を素早く確認する用途に特に有効だ。

### パターン6: クロスアカウント集約（CloudWatch Cross-Account Observability）

本番・ステージング・開発の複数アカウントでトレースが分散すると、インシデント時に各コンソールを行き来する必要が生じる。CloudWatch Cross-Account Observability を使うと、監視専用アカウントから複数アカウントのトレースを一括参照できる。

```hcl
# ソースアカウント側（各環境アカウント）
resource "aws_oam_link" "phase9" {
  label_template = "$AccountName"
  resource_types = [
    "AWS::XRay::Trace",
    "AWS::CloudWatch::Metric",
    "AWS::Logs::LogGroup"
  ]
  sink_identifier = var.monitoring_account_sink_arn
}
```

監視アカウントの Service Map が複数アカウントをまたいでノードを描画するようになる。追加コストはなく、設定はコンソールの `CloudWatch > Settings > Cross-account observability` から数分で完了する。マルチアカウント構成を取る場合は最初期に設定しておくと、後から「あのエラーはどのアカウントの Lambda だった？」という混乱を防げる。

### パターン7: X-Ray vs Datadog / Grafana — 使い分けの判断基準

| 観点 | X-Ray | Datadog APM | Grafana Tempo + ADOT |
|---|---|---|---|
| セットアップコスト | 低（Active 有効化のみ） | 中（Agent インストール） | 中（ADOT Layer + collector.yaml） |
| コスト | 100万トレース/月 無料、以降 $5/100万 | 有償（ホスト課金） | Tempo 自体は無料（ストレージ別） |
| 保存期間 | 30日固定 | プラン依存（15日〜） | 自由（自己管理） |
| AWS 統合 | 最高（Service Map が AWS アーキテクチャ図と一致） | 良好 | 良好（ADOT 経由） |
| マルチクラウド | 不可 | 可 | 可 |
| ベンダーロックイン | X-Ray SDK に依存 | Datadog Agent に依存 | OpenTelemetry 標準 |

判断基準: AWS only のシステムなら X-Ray が最も低コスト・低摩擦。将来マルチクラウドが視野に入る・オンプレ混在・長期トレース分析が必要、の場合は ADOT + Grafana Tempo を検討する。Datadog は可観測性のオールインワン（ログ・メトリクス・トレース・APM・インシデント管理）が必要なチームに向く。
