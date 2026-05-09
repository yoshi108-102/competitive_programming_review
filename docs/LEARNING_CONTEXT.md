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

**Phase 1 / Task 17 + Task 18 (デプロイ実行待ち)**。Task 3〜16 のコード・教材は全て実装完了。
ユーザー判断により lesson とまとめクイズは MVP 動作確認後に一括解説する方針 (`feedback_lesson_after_implementation.md`)。

### Task 4〜16 実装完了（2026-05-09、lesson と クイズは MVP 動作確認後に一括採点）

#### Backend Python (Tasks 4〜8)

| Task | 成果物 | テスト |
|---|---|---|
| 4 | `shared/db.py` (get_table, query_all) | 6 件 |
| 5 | `shared/atcoder_client.py` (AtCoderClient) | 7 件 |
| 6 | `lambdas/save_user/handler.py` | 7 件 |
| 7 | `lambdas/sync_submissions/handler.py` | 6 件 |
| 8 | `lambdas/get_submissions/handler.py` (list+detail+pagination) | 12 件 |

合計 50 件 (test_response.py 12 件含む) 全パス。

#### Terraform (Tasks 9, 10)

- `terraform/modules/lambda/` — IAM 実行ロール、3 関数を `for_each` で一括定義、CloudWatch Log Group、API Gateway 用 permission
- `terraform/modules/api_gateway/` — `/users/me`, `/sync`, `/submissions`, `/submissions/{submission_id}` 各エンドポイント + CORS preflight (OPTIONS) + Cognito Authorizer
- `modules.tf` で全モジュール配線、`terraform validate` 通過

#### Frontend (Tasks 11〜15) — Next.js 16 + React 19 + Amplify v6

- `frontend/app/lib/types.ts` — Backend `{data, meta}` / `{error}` 形式の型 + ドメイン型
- `frontend/app/lib/api.ts` — Cognito JWT を `idToken` で取り出して `Authorization: Bearer` 付きで fetch するクライアント
- `frontend/app/components/AppShell.tsx` — 共通ヘッダ + ナビゲーション
- `frontend/app/page.tsx` — ホームダッシュボード
- `frontend/app/settings/page.tsx` — AtCoder ユーザー名登録フォーム
- `frontend/app/submissions/page.tsx` — 提出一覧 + 同期ボタン + ページネーション
- `frontend/app/submissions/[submission_id]/page.tsx` — 動的ルートで詳細表示
- `tsc --noEmit` 通過

#### デプロイスクリプト (Task 16)

- `backend/scripts/build_lambda.sh` — uv pip install --target で依存と app コードを ZIP 化（生成成功: ~16MB）
- `scripts/deploy_phase1.sh` — build / plan / apply / sync-env / destroy のサブコマンド分離

#### 残: Task 17 + 18 (実行待ち)

`scripts/deploy_phase1.sh` の各サブコマンドを実行することで完成。
**実 AWS 課金が発生**するためユーザー実行待ち。手順は `docs/learning/phase1/task17/` と `task18/` に詳細あり。

Task 7 で発覚した実物の知見（教材 02 / Decimal 問題の伏線回収）:
- Boto3 は `float` を拒否し `Decimal` を要求する → `_floats_to_decimal()` ヘルパで変換



### Task 3 実装完了（2026-05-09、まとめクイズは MVP 完成後に採点予定）

Task 3「Backend — shared/response.py (APIレスポンスヘルパー)」で実装したもの:
- `backend/shared/response.py` — `success(data, meta, status_code)` / `error(code, message, status_code)`
- `backend/tests/test_response.py` — 12 件の単体テスト（CORS / Decimal / ステートレス性 など）
- `backend/lambdas/get_submissions/handler.py` — 最小ハンドラ（end-to-end 動作確認用）
- `backend/tests/test_get_submissions.py` — moto + DynamoDB 結合テスト 3 件

教材は `docs/learning/phase1/task3/` に 3 枚:
- `01-lambda-response-format-and-cors.md` — Lambda Proxy Integration / CORS / SOP / Clickjacking / CSRF（採点済み）
- `02-json-dumps-default-and-decimal.md` — `default=str` 慣用句、Boto3 Decimal、JSONEncoder（クイズ生成済み・未採点 = 1問のみ部分回答）
- `03-shared-response-helper-design.md` — `shared/response.py` の設計ノート（クイズなし = 実装で代替）

**Task 2 + 3 統合まとめクイズは `phase1/task3/main.md` に生成済み**だが、ユーザー判断により採点は MVP 完成後に先送り。
理由: API GW / Cognito / フロントが揃っていない段階では横断的論点（環境変数経由でのテーブル名注入、warm start のステートレス性、JWT × CORS preflight 等）が点でしか繋がらず、動くものを見ないとピンと来ないため。

### Task 1 完了（2026-04-18 採点済み）

Task 1「Terraform DynamoDBモジュール」で習得:
- DynamoDB キー設計（PK/SK/GSI）、RDB比較、スキーマレス、Single Table Design
- DynamoDB = 分散ハッシュテーブル（DHT）のメンタルモデル、Dynamo論文系譜
- Terraform の基本（HCL構文、モジュール構造、variables/outputs）、Bootstrap パターン、state locking
- AWS IAM（ユーザー/ロール/ポリシー、Identity Center）、AWS認証のベストプラクティス
- 設計原則（YAGNI、明示性、最小公開）

振り返り採点結果: Q5(b) default の使い分け（ルート側）、Q6(b) ARN の構成要素 が **要復習** → `docs/learning/review-queue.md` に記録済み。

### Task 2 完了（2026-04-18、振り返りは Task 3/4 と統合予定）

Task 2「Backend — Python 環境セットアップ」で習得:
- **moto ライブラリ**: AWS を丸ごとローカルでエミュレート、性能計測以外の全機能テストに使える
- **`AWS_ACCESS_KEY_ID="testing"` の正体**: boto3 の認証チェック回避 + 本物AWS 誤叩き事故防止
- **2段階 fixture 設計**: `aws_env`（monkeypatch で環境変数注入）→ `dynamodb_tables`（`with mock_aws()` + yield でテーブル準備）
- **環境変数経由でテーブル名を渡す設計**: Lambda 本番では Terraform、ローカルでは monkeypatch

実装内容: `backend/pyproject.toml` (uv ベース、元計画の requirements.txt から変更)、`shared/lambdas/tests/__init__.py`、`conftest.py` (2段階fixture)。

振り返りは **pytest を実際に書く Task (Task 3 or Task 4) とまとめて実施**する方針。

### Task 4 概要

`backend/shared/db.py` を作成。Lambda ハンドラから DynamoDB を操作するための共通ヘルパー。

主な学習ポイント（予定）:
- Boto3 Resource API vs Client API
- `Table.query` / `Table.put_item` のラップ方針
- ページネーション（`LastEvaluatedKey`）の扱い
- 環境変数経由でテーブル名解決（Task 3 で確立した方針の延長）

## タスクごとの学習フロー

各タスクで以下のサイクルを回す:

1. **解説**: 何をするか、なぜそうするか、AWSの設計思想やベストプラクティスとの関連
2. **確認**: ユーザーが理解したか確認、質問があれば回答
3. **実装**: ユーザーの「進めて」を受けてからサブエージェントが実行
4. **振り返り**: 生成されたコードの解説、注目ポイント、疑問の議論
5. **次へ**: ユーザーの「次に進む」を受けてから次のタスクへ

**重要: 勝手に進めない。** 各ステップでユーザーの確認を取る。

## ドキュメント構成ルール

### 学習ノート

```
docs/learning/phase{N}/task{M}/
├── main.md                     ← 目次 + 振り返り
├── 01-{トピック名}.md           ← トピック別の解説・Q&A
├── 02-{トピック名}.md
└── reference/
    ├── {テーマ}-{詳細}.md       ← Web検索を含む詳細リファレンス
    └── ...
```

### ルール

- **大枠ごとにmdを分ける**（1つのmdにすべてを入れない）
- **referenceは深掘り用**: Web検索のソース付き、詳細な比較表、具体例
- **トピックmdはQ&A中心**: 解説 + 質疑応答の記録
- **main.mdは目次**: トピックmdとreferenceへのリンク + 振り返り
- **tfファイルにもコメント**: 該当コードの上に1行の説明 + docsへのリンク

### コード上のコメント例

```hcl
# Terraformの状態ファイルをS3に保存。dynamodb_tableは同時apply防止のロック。
# → docs/learning/phase1/task1/reference/terraform-basics.md
backend "s3" { ... }
```

## 関連ドキュメントの場所

| ドキュメント | パス |
|---|---|
| Phase設計書 | `plans/aws-learning-phases-design.md` |
| Phase 1 実装計画 | `plans/phase1-mvp-implementation.md` |
| Phase 1 / Task 1 学習ノート | `docs/learning/phase1/task1/` |
| 既存のMVP計画（参考） | `plans/mvp/` |
