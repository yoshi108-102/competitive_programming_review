# Phase / Task ごとのテスト・検証ガイド

「うまく動いてるか」を自分で確認する手順を Phase / Task 単位でまとめる。新しい Task を完了したらここに追記される。

---

## 🎯 今すぐ使える「Task 1 完了時の検証コマンド」

コピペして実行できる。成功すれば Task 1 の成果物（Cognito / API Gateway / DynamoDB）は正常に動いている。

### 1. AWS リソース存在確認

```bash
# DynamoDB テーブル 3つ + ロックテーブル が存在するか
aws dynamodb list-tables --region ap-northeast-1 \
  --query 'TableNames[?starts_with(@, `atcoder-review`)]'

# 期待値:
# [
#   "atcoder-review-problems-prod",
#   "atcoder-review-submissions-prod",
#   "atcoder-review-tflock",
#   "atcoder-review-users-prod"
# ]
```

```bash
# users テーブルの構造確認
aws dynamodb describe-table \
  --table-name atcoder-review-users-prod \
  --region ap-northeast-1 \
  --query 'Table.{Keys:KeySchema,Attrs:AttributeDefinitions,Billing:BillingModeSummary.BillingMode}'
```

```bash
# problems テーブルの GSI 確認
aws dynamodb describe-table \
  --table-name atcoder-review-problems-prod \
  --region ap-northeast-1 \
  --query 'Table.GlobalSecondaryIndexes[*].{Name:IndexName,Keys:KeySchema}'

# 期待: TagDifficultyIndex が表示される
```

### 2. DynamoDB に実際に書き込み/読み出し

```bash
# テストデータ書き込み
aws dynamodb put-item \
  --table-name atcoder-review-users-prod \
  --region ap-northeast-1 \
  --item '{"user_id":{"S":"test-user-001"},"handle":{"S":"tester"},"created_at":{"S":"2026-04-18"}}'

# 読み出し
aws dynamodb get-item \
  --table-name atcoder-review-users-prod \
  --region ap-northeast-1 \
  --key '{"user_id":{"S":"test-user-001"}}'

# 削除（後片付け）
aws dynamodb delete-item \
  --table-name atcoder-review-users-prod \
  --region ap-northeast-1 \
  --key '{"user_id":{"S":"test-user-001"}}'
```

### 3. API Gateway /health エンドポイント

```bash
curl -i https://hwccyb59ic.execute-api.ap-northeast-1.amazonaws.com/prod/health

# 期待: 200 OK + JSON ボディ（/health の現状実装次第）
```

### 4. Cognito ユーザー登録

```bash
# ユーザープールの存在確認
aws cognito-idp describe-user-pool \
  --user-pool-id ap-northeast-1_4E9Glk5W7 \
  --region ap-northeast-1 \
  --query 'UserPool.{Name:Name,Policies:Policies.PasswordPolicy,MFA:MfaConfiguration}'
```

### 5. フロントエンドをローカルで起動

```bash
cd frontend

# .env.local を作成（最初の1回のみ）
cat > .env.local <<EOF
NEXT_PUBLIC_COGNITO_USER_POOL_ID=ap-northeast-1_4E9Glk5W7
NEXT_PUBLIC_COGNITO_USER_POOL_CLIENT_ID=62eag7d103e67okjg8lkjunhuf
EOF

npm run dev
# → http://localhost:3000
```

ブラウザで:
- ログイン画面が表示される ✅
- メールアドレスでサインアップ → 確認コードがメールに来る ✅
- コードを入れてログイン → ヘッダに email が出る ✅

ここまで通れば、認証基盤が動いていることの証明。

---

## Phase 1 全体の Task 別検証

### ✅ Task 1: Terraform DynamoDB モジュール

→ 上記「今すぐ使える検証コマンド」

### 📋 Task 2: Backend Python 環境セットアップ（未着手）

**検証するもの**: pytest 実行環境、moto による DynamoDB モック

```bash
cd backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt

# pytest が動くか
pytest --version

# conftest.py のフィクスチャが動くか（ダミーテストで確認）
pytest tests/ -v
```

**成功条件**: pytest がクラッシュせず collected 0 items で終わる（テストが無くても設定は通る）。

### 📋 Task 3: `backend/shared/db.py` (DynamoDB操作)

**検証するもの**: UserRepository / SubmissionRepository のユニットテスト

```bash
cd backend
pytest tests/test_db.py -v
```

**成功条件**: 全ユニットテスト green。moto が DynamoDB をモックして、put/get が動く。

### 📋 Task 4: `sync_submissions` Lambda

**検証するもの**: AtCoder Problems API 連携、DynamoDB へのデータ保存

ローカルで:
```bash
# 自分の AtCoder ハンドルで試す
python -c "
from lambdas.sync_submissions.handler import sync_user_submissions
sync_user_submissions(user_id='test-local', handle='yoshi108-102')
"

# DynamoDB に入ったか確認
aws dynamodb scan \
  --table-name atcoder-review-submissions-prod \
  --max-items 5
```

**成功条件**: submissions テーブルに実際のデータが書き込まれている。

### 📋 Task 5: `get_submissions` Lambda + ページネーション

```bash
python -c "
from lambdas.get_submissions.handler import lambda_handler
event = {'pathParameters': {'user_id': 'test-local'}, 'queryStringParameters': {'limit': '10'}}
print(lambda_handler(event, None))
"
```

**成功条件**: submissions の最初10件 + 次ページ用 `next_token` が返る。

### 📋 Task 6: Lambda モジュール + API Gateway /submissions ルート

デプロイ後:
```bash
# Cognito でログイン → トークン取得
TOKEN=$(aws cognito-idp admin-initiate-auth \
  --user-pool-id ap-northeast-1_4E9Glk5W7 \
  --client-id 62eag7d103e67okjg8lkjunhuf \
  --auth-flow ADMIN_NO_SRP_AUTH \
  --auth-parameters USERNAME=<your-email>,PASSWORD=<your-password> \
  --query 'AuthenticationResult.IdToken' --output text)

# API を叩く
curl https://hwccyb59ic.execute-api.ap-northeast-1.amazonaws.com/prod/submissions \
  -H "Authorization: Bearer $TOKEN"
```

**成功条件**: 401 ではなく 200 が返り、submissions の JSON が取れる。

### 📋 Task 7: Frontend /submissions ページ

ローカルで:
```bash
cd frontend && npm run dev
# http://localhost:3000/submissions にアクセス
```

**成功条件**: ログイン後、submissions 一覧が表示される。ページネーション「次へ」も動作。

### 📋 Task 8: Amplify Hosting でデプロイ

```bash
# Amplify コンソール URL にアクセス
# または
curl -i https://<amplify-app-domain>.amplifyapp.com
```

**成功条件**: 公開 URL でサイトが見られる、Cognito ログインも動く。

---

## Phase 2 以降（未着手）

新しい Phase で追加される AWS サービスに応じてテスト方法が増える:

- **Phase 2 (S3)**: `aws s3 ls`, presigned URL でファイル取得
- **Phase 3 (SQS)**: キューにメッセージ投入 → Lambda が発火する
- **Phase 4 (CloudWatch)**: ダッシュボードでメトリクス確認
- **Phase 5 (CloudFront/WAF)**: CDN経由でアクセスされているか、WAFルールが効いているか
- **Phase 6 (Bedrock)**: プロンプト投入 → Claude応答
- **Phase 7 (EventBridge)**: スケジュール起動が走っているか
- **Phase 8 (Step Functions)**: ワークフロー実行の可視化
- **Phase 9 (X-Ray)**: トレース確認
- **Phase 10 (SNS)**: 通知が届くか

各Phase完了時にこのファイルに追記していく。

---

## テストの原則

1. **実装完了 = テスト通過**、で測る（「書いたけど動くか不明」は完了扱いしない）
2. **AWS上の実リソースで確認**（ローカルモックだけでなく）
3. **失敗時のログの読み方**もセットで学ぶ
4. **テストコマンドはコピペで動くもの**をここに載せる（自分がハマった手順も含めて）

---

## 関連

- [LEARNING_CONTEXT.md](../LEARNING_CONTEXT.md) - Phase / Task の全体像
- [review-queue.md](review-queue.md) - 復習キュー
