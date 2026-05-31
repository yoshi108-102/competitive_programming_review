# Phase 別 実 AWS sandbox（ハイブリッド観測） — 設計書

- 日付: 2026-05-31
- ステータス: ドラフト（ユーザーレビュー待ち）
- 関連: `docs/LEARNING_CONTEXT.md`, `plans/aws-learning-phases-design.md`, 既存デモ `docs/learning/phaseN/demo/index.html`

## 1. 目的

各 Phase の AWS サービス挙動を、**実 AWS の CloudWatch で実際に観測**できるようにする。ただし常時課金は避け、普段は無料・無起動で検証し、見たい時だけ短時間立てる「**ハイブリッド**」運用にする。

- 既定ループ（無料・無起動）: `moto` による pytest ＋ `terraform validate` / `plan`
- 観測ループ（実 AWS・短時間）: `terraform apply` → 活動生成 → CloudWatch ダッシュボードで観測 → `terraform destroy`

既存の HTML デモ（JS シミュレーション）は概念入門として残し、その「実物版」を sandbox として追加する。

## 2. 非目標（Non-goals）

- 常時稼働インフラを作らない（観測時のみ apply、終わったら destroy）。
- LocalStack は使わない（プロジェクト方針 `feedback_test_schema_duplication` に従う外部依存回避）。
- Claude（本エージェント）が `terraform apply` を実行しない。実課金リソースの作成・破棄は**ユーザーが Makefile target で実行**する。
- 本番 MVP スタック（`terraform/` 直下）の構成・state は変更しない（sandbox は完全分離）。

## 3. 用語の確定

- 「全10 Phase 一気」= **10 Phase 分の sandbox コード（IaC＋スクリプト＋テスト）を一括で用意する**こと。一度に全部 apply する意味ではない。各 sandbox は独立に apply/destroy する。

## 4. アーキテクチャ（採用案 A: Phase 別の独立 Terraform ルート）

各 Phase に**独立した Terraform ルート**を持たせる。

```
terraform/sandboxes/
  _budget/                 # 任意: アカウント単位の Budget アラーム（opt-in 単発）
  phase1/ ... phase10/
    main.tf                # provider + 最小リソース
    variables.tf
    outputs.tf
    dashboard.tf           # aws_cloudwatch_dashboard（観測の入口）
    load.sh                # 活動生成（Phase 固有）
    watch.sh               # dashboard URL / console deep link / metric スナップショット出力
    .gitignore             # *.tfstate*, .terraform/
backend/sandboxes/
  phase2/ ... phase10/
    handler.py             # 小さな Lambda ハンドラ（必要な Phase のみ）
backend/tests/sandboxes/
  phase2/ ... phase10/
    test_handler.py        # moto による単体テスト
```

設計上の要点:

- 各ルートは**独自 provider・ローカル state**（`terraform.tfstate` を sandbox ディレクトリ内に置き、`.gitignore`）。本番 MVP の `atcoder-review-tfstate` とは混ざらないため、sandbox 操作が本番に波及しない。ローカル state は使い捨て前提で十分（単一ユーザー・短命）。
- 全リソースに `Sandbox = "phaseN"` と `Project = "atcoder-review"` タグを付与（一括掃除・コスト把握用）。`provider "aws"` の `default_tags` で付ける。
- 各ルートはその Phase のサービスを**最小限**だけ作り、CloudWatch にシグナルを出す。`aws_cloudwatch_dashboard` を1枚作り、「見る」を URL 一発にする。
- Lambda が要る Phase は、依存のない小さな Python ハンドラ（標準 `boto3` のみ、Lambda ランタイム同梱）を `data "archive_file"` で zip 化。重いビルド（uv/依存解決）は不要。

### 不採用案

- 案 B（1モジュール＋workspace）: DRY だが、Phase ごとに異なるリソースを条件分岐させると複雑化し、state も共有で destroy 粒度が鈍る。
- 案 C（本番スタックにフラグ追加）: 本番 MVP の state に sandbox が同居し、誤適用が本番に波及。destroy の隔離も不可。

→ 隔離・安全・明快さで**案 A** を採用。

## 5. ハイブリッド運用（Makefile pattern target, N=1..10）

Makefile に pattern rule を追加（Phase 固有処理は各 sandbox の `load.sh` / `watch.sh` に委譲し、Makefile 自体は DRY に保つ）。

| target | 中身 | 課金 |
|---|---|---|
| `make sandbox-test-phaseN` | `terraform validate` は常時実行＋`backend/tests/sandboxes/phaseN` が存在すれば moto pytest（ハンドラの無い Phase は validate のみ） | なし |
| `make sandbox-up-phaseN` | `terraform -chdir=terraform/sandboxes/phaseN init && apply` | あり |
| `make sandbox-load-phaseN` | `bash terraform/sandboxes/phaseN/load.sh`（活動生成） | わずか |
| `make sandbox-watch-phaseN` | `bash terraform/sandboxes/phaseN/watch.sh`（dashboard URL・deep link・`aws cloudwatch get-metric-statistics` 数発） | なし |
| `make sandbox-down-phaseN` | `terraform -chdir=... destroy` | — |
| `make sandbox-down-all` | 全 sandbox を順に destroy（消し忘れ防止の安全弁） | — |
| `make sandbox-budget` | `terraform/sandboxes/_budget` を apply（任意・単発のコスト見張り） | ごくわずか |

`watch.sh` の出力例: `https://<region>.console.aws.amazon.com/cloudwatch/home?region=<region>#dashboards/dashboard/atcoder-sandbox-phaseN` ＋ 該当サービスのコンソール deep link ＋ 直近メトリクスの CLI スナップショット。

## 6. Phase 別の中身と観測性（⚠ は注意点）

| Phase | サービス | 最小リソース | ロード生成 | CloudWatch で見えるもの |
|---|---|---|---|---|
| 1 | MVP | 既存本体スタックに `dashboard.tf` を追加（別ルートから参照、本体は不変更） | API 呼出 | Lambda/API GW/DynamoDB メトリクス ✅ |
| 2 | S3 | bucket ＋ `ObjectCreated`→Lambda | オブジェクト upload | Lambda Invocations は即時 ✅ / ⚠ S3 ストレージ系（BucketSizeBytes 等）は**日次**集計 |
| 3 | SQS | queue ＋ DLQ ＋ producer/consumer Lambda | メッセージ送信 | キュー深さ・滞留時間・送受信数・DLQ ✅ |
| 4 | CloudWatch | カスタムメトリクス発行 Lambda ＋ `aws_cloudwatch_metric_alarm` | Lambda 呼出 | カスタム指標・アラーム状態・dashboard ✅ |
| 5 | CloudFront+WAF | CloudFront ＋ S3 origin ＋ WAF Web ACL（`scope=CLOUDFRONT`, us-east-1） | URL に curl | リクエスト・キャッシュ率・WAF ブロック数 / ⚠ CF は作成・破棄に **15〜20 分**、メトリクスは us-east-1 名前空間 |
| 6 | Bedrock | Claude 呼出 Lambda | Lambda 呼出 | `AWS/Bedrock` InvokeModel メトリクス / ⚠ **モデルアクセスの事前有効化**が必要・**トークン課金**あり・利用可能リージョン要確認 |
| 7 | EventBridge | `rate(1 minute)` rule → Lambda（＋ put-events 手動発火） | put-events / 待機 | ルール発火数・失敗数・Lambda ✅ |
| 8 | Step Functions | 小さな state machine（Pass/Choice/Task） | start-execution | 実行開始/成功/失敗数・所要時間＋コンソールのビジュアル実行 ✅ |
| 9 | X-Ray | トレース有効 Lambda → DynamoDB | Lambda 呼出 | ⚠ トレース＆サービスマップは **X-Ray / CloudWatch ServiceLens** 側（古典 CloudWatch メトリクスではない） |
| 10 | SNS | topic ＋ SQS 購読（＋ Lambda 購読） | publish | 発行/配信/失敗数 ✅ |

リージョン: 既定は本番に合わせ `ap-northeast-1`。例外として Phase 5 の WAF(CLOUDFRONT) ＋ CloudFront メトリクスは `us-east-1`。Phase 6 はモデル提供リージョンに合わせる（spec 実装時に確認）。

## 7. テスト戦略

- **moto pytest**: `backend/sandboxes/phaseN/handler.py` のロジック（SQS 消費・冪等処理・S3 イベント処理・カスタムメトリクス発行など）を `mock_aws` で検証。既存 `backend/tests/` の 2 段階 fixture 流儀を踏襲。
- **terraform validate / plan**: 各 sandbox ルートの構文・参照整合を無料で検証（`-backend=false` 不要、ローカル state なので `init` 後に `validate`）。
- Terraform と moto/handler のスキーマ二重管理は手動同期（プロジェクト既定方針）。

## 8. コスト・安全ガードレール

- **私（Claude）は apply/destroy を実行しない**。ユーザーが Makefile target で実行。
- 全リソースに `Sandbox=phaseN` タグ → コンソール/CLI で一括把握・掃除可能。
- `make sandbox-down-all` で全消し。`make sandbox-down-phaseN` で個別消し。
- 任意 `make sandbox-budget` でアカウント単位の月次 Budget 通知（既定 $5）。
- 重い/前提ありの Phase（5 CloudFront・6 Bedrock）は caveat を `watch.sh` 冒頭と README にも明記。実装順は最後。
- sandbox state（`*.tfstate*`, `.terraform/`）は `.gitignore`。

## 9. 既存デモとの接続

各 Phase の `docs/learning/phaseN/demo/index.html` 末尾の「正式教材で深掘り」付近に一行追加:
「実物で動かす: `make sandbox-up-phaseN` → `make sandbox-watch-phaseN` → `make sandbox-down-phaseN`」。
概念（シミュレーション）→ 実物（実 AWS 観測）の橋渡しにする。

## 10. 実装の進め方（概要・詳細は実装計画で）

- 共通の雛形（provider/tags/dashboard/.gitignore、Makefile pattern target、_budget、README）を先に確立。
- 観測性が高く安い Phase（3 SQS / 4 CloudWatch / 8 Step Functions / 10 SNS / 7 EventBridge / 9 X-Ray / 2 S3）を先に。
- 重い Phase（5 CloudFront / 6 Bedrock）を最後に、caveat 付きで。
- Phase 1 は既存本体スタックに dashboard を足すだけ（apply は既存 `make apply`）。
- 生成自体は sonnet サブエージェントのワークフローで並列化しても良い（デモ生成と同様）。各 sandbox は独立なので並列生成と相性が良い。

## 11. リスク / 未確定

- Bedrock のモデルアクセスはアカウント側の手動有効化が前提（実装時にユーザー確認）。
- CloudFront は作成/破棄が長く、観測体験のテンポが他 Phase と異なる。
- ローカル state は単一ユーザー前提。複数環境で使うなら S3 prefix 分離に切替（今回は対象外）。
- 無料枠を超える可能性は短時間運用なら低いが、destroy 忘れがコスト要因 → `sandbox-down-all` と Budget で緩和。

## 12. 受け入れ条件

- `make sandbox-test-phaseN` が全 Phase で無料・無起動で通る。
- `make sandbox-up-phaseN` → `load` → `watch` → `down` の 4 ステップが各 Phase で完結し、`watch` が CloudWatch ダッシュボード URL を提示する。
- 本番 MVP スタックの state・構成に一切変更がない。
- sandbox state が git に混入しない。
