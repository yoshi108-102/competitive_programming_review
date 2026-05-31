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
