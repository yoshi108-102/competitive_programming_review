# AtCoder 復習支援ツール — 学習コンテキスト

## プロジェクトの目的

AWS学習が主目的。AtCoderの復習支援ツールを構築する過程で、AWSサービスを段階的に学ぶ。コード完成が目的ではなく、各サービスの理解が最優先。

## Phase構成（全10 Phase）

各Phaseで新規AWSサービスを1-2個ずつ導入し、じっくり学ぶ。

| Phase | テーマ | 新規AWSサービス | 状態 |
|---|---|---|---|
| 1 | MVP | Cognito, API Gateway, Lambda, DynamoDB, Amplify Hosting | **進行中** |
| 2 | ストレージ分離 | S3 | 未着手 |
| 3 | 非同期処理 | SQS | 未着手 |
| 4 | 監視基盤 | CloudWatch | 未着手 |
| 5 | セキュリティ強化 | CloudFront, WAF | 未着手 |
| 6 | AI機能 | Bedrock (Claude) | 未着手 |
| 7 | スケジュール実行 | EventBridge | 未着手 |
| 8 | ワークフロー管理 | Step Functions | 未着手 |
| 9 | 分散トレーシング | X-Ray | 未着手 |
| 10 | 通知統合 | SNS | 未着手 |

設計書: `plans/aws-learning-phases-design.md`
Phase 1 実装計画: `plans/phase1-mvp-implementation.md`

## 現在の進捗

**Phase 1: コード・教材ともに実装完了。実 AWS デプロイ (Tasks 17/18) はユーザー実行待ち。**

学習ノートは AWS トピック単位に再構成済み (`docs/learning/phase1/`):

- `task1/` — DynamoDB / Terraform / IAM の基礎（**完了・採点済み**）
- `task2/02-lambda-proxy-integration-and-cors.md` — Lambda 戻り値仕様 + CORS
- `task2/03-boto3-resource-vs-client.md` — Boto3 SDK
- `task2/04-dynamodb-decimal-and-pagination.md` — Decimal の素性 + 1MB / LastEvaluatedKey
- `task2/05-lambda-execution-role-and-deployment.md` — IAM 実行ロール + ZIP デプロイ
- `task2/06-api-gateway-rest-api-structure.md` — REST API + Authorizer + CORS preflight
- `task2/07-cognito-and-api-gateway-authorizer.md` — Cognito + JWT (idToken vs accessToken)
- `practice/` — 実装 Q&A、設計ノート、参考メモ
- `main.md` — 目次 + Task 2+3 まとめクイズ（採点保留）

ユーザー方針: lesson とまとめクイズは MVP 動作確認後に一括採点する (`feedback_lesson_after_implementation.md`, `feedback_defer_retrospective.md`)。

### 実装済みコード（2026-05-09）

#### Backend Python (50 tests pass)

- `backend/shared/{response,db,atcoder_client}.py`
- `backend/lambdas/{save_user,sync_submissions,get_submissions}/handler.py`
- `backend/tests/test_*.py`

#### Terraform (validate pass)

- `terraform/modules/{lambda,api_gateway,cognito,dynamodb}/`
- `terraform/modules.tf`, `main.tf`, `variables.tf`, `outputs.tf`

#### Frontend (tsc pass) — Next.js 16 + React 19 + Amplify v6

- `frontend/app/lib/{types,api}.ts`
- `frontend/app/components/AppShell.tsx`
- `frontend/app/{page,settings,submissions,submissions/[submission_id]}/page.tsx`

#### デプロイ補助

- `Makefile` ルートに統合（`make build/plan/apply/sync-env/destroy/test/tf-validate`）
- `make build` で `backend/dist/lambda.zip` (~16MB) 生成

### 残: Task 17 + 18（ユーザー実行）

```bash
make plan       # Lambda ZIP build + terraform plan
make apply      # 実 AWS デプロイ（課金開始）
make sync-env   # frontend/.env.local 生成
cd frontend && npm run dev   # ローカル動作確認
make destroy    # 課金停止
```

手順詳細: `docs/learning/phase1/practice/terraform-apply-walkthrough.md`、`practice/frontend-integration-test.md`

### 実物の知見（メモ）

- **Boto3 は float を拒否し Decimal を要求する**: AtCoder Problems API レスポンスの `point` は float なので `_floats_to_decimal()` ヘルパで変換。教材 `task2/04-dynamodb-decimal-and-pagination.md` の伏線回収。

### Task 1 完了（2026-04-18 採点済み）

Task 1「Terraform DynamoDBモジュール」で習得:
- DynamoDB キー設計（PK/SK/GSI）、RDB比較、スキーマレス、Single Table Design
- DynamoDB = 分散ハッシュテーブル（DHT）のメンタルモデル、Dynamo論文系譜
- Terraform の基本（HCL構文、モジュール構造、variables/outputs）、Bootstrap パターン、state locking
- AWS IAM（ユーザー/ロール/ポリシー、Identity Center）、AWS認証のベストプラクティス
- 設計原則（YAGNI、明示性、最小公開）

振り返り採点結果: Q5(b) default の使い分け、Q6(b) ARN の構成要素 が **要復習** → `docs/learning/review-queue.md` に記録済み（既習得済みに移動）。

### Task 2 完了（2026-04-18、振り返りは Task 3 と統合）

Task 2「Backend — Python 環境セットアップ」で習得:
- **moto ライブラリ**: AWS を丸ごとローカルでエミュレート
- **`AWS_ACCESS_KEY_ID="testing"` の正体**: boto3 の認証チェック回避 + 本物AWS 誤叩き事故防止
- **2段階 fixture 設計**: `aws_env`（monkeypatch で環境変数注入）→ `dynamodb_tables`（`with mock_aws()` + yield）

詳細メモ: `docs/learning/phase1/practice/{moto-and-aws-test-credentials,pytest-fixtures-for-aws}.md`
振り返りクイズ: `docs/learning/phase1/main.md` の §振り返り（Task 2+3 統合まとめ）

## ドキュメント構成ルール

### 学習ノート構成 (Phase 1 採用)

```
docs/learning/phase{N}/
├── main.md                          ← Phase 全体目次 + まとめクイズ
├── task1/                           ← 既存 (Topic 1 ぶんだけサブディレクトリ運用)
│   ├── 01-...md
│   ├── ...
│   └── reference/
├── 02-{aws-topic}.md                ← AWS 学習トピック (連番付き)
├── 03-{aws-topic}.md
├── ...
└── practice/                        ← 実装 Q&A、設計ノート、参考メモ
    ├── README.md
    ├── {topic}.md                   ← トピック単位の md
    └── reference/                   ← Q&A 議論ログ
```

### ルール

- **AWS の中核概念は phase1/ 直下の番号付き md** に書く（02-... 〜）
- **実装の Q&A・設計判断は `practice/` 配下** に分離（連番なし、kebab-case トピック名）
- **議論ログ・Web 検索ベースの参照は `practice/reference/`** に置く
- **コード側コメントから docs を参照**するパスは新構造に合わせる（`# → docs/learning/phase1/{topic}.md`）

### コード上のコメント例

```hcl
# Terraformの状態ファイルをS3に保存。
# → docs/learning/phase1/task1/reference/terraform-basics.md
backend "s3" { ... }
```

```python
# default=str は Decimal を文字列化するため
# → docs/learning/phase1/practice/json-dumps-default-str.md
return json.dumps(body, default=str)
```

## 関連ドキュメントの場所

| ドキュメント | パス |
|---|---|
| Phase設計書 | `plans/aws-learning-phases-design.md` |
| Phase 1 実装計画 | `plans/phase1-mvp-implementation.md` |
| Phase 1 学習ノート目次 | `docs/learning/phase1/main.md` |
| Phase 1 / Topic 1 (基礎) | `docs/learning/phase1/task1/` |
| Phase 1 実装 Q&A | `docs/learning/phase1/practice/README.md` |
| 復習キュー | `docs/learning/review-queue.md` |
| 既存のMVP計画（参考） | `plans/mvp/` |

## タスクごとの学習フロー

各タスクで以下のサイクルを回す:

1. **解説**: 何をするか、なぜそうするか、AWSの設計思想やベストプラクティスとの関連
2. **確認**: ユーザーが理解したか確認、質問があれば回答
3. **実装**: ユーザーの「進めて」を受けてから着手
4. **振り返り**: 生成されたコードの解説、注目ポイント、疑問の議論
5. **次へ**: ユーザーの「次に進む」を受けてから次のタスクへ

**重要: 勝手に進めない。** 各ステップでユーザーの確認を取る。

ただし**実装系 Task では lesson を実装後に回す**運用 (`feedback_lesson_after_implementation.md`)。
