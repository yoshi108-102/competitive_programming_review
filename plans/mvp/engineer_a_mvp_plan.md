# エンジニアA: MVP実装プラン

## 実装方針
**最短でMVPを動かすことに集中。** 完璧さよりも「ログインして提出履歴が見える」状態を最速で達成する。

---

## 1. 実装タスク詳細ブレークダウン

### 1-1. プロジェクト基盤構築（目安: 0.5日）

#### タスク一覧
- [ ] ディレクトリ構成の作成
- [ ] Next.js プロジェクト初期化 (`npx create-next-app@latest frontend --typescript --app --tailwind`)
- [ ] Python バックエンド環境セットアップ (`backend/requirements.txt`)
- [ ] Terraform 初期セットアップ
  - `terraform/main.tf` - provider設定 (AWS, ap-northeast-1)
  - `terraform/backend.tf` - S3 + DynamoDB for state管理
  - `terraform/variables.tf` - 共通変数
  - `terraform/environments/prod/main.tf` - 環境固有設定

#### 主要ライブラリ
```
# frontend/package.json
next, react, @aws-amplify/ui-react, aws-amplify, axios

# backend/requirements.txt
boto3, requests, beautifulsoup4
```

#### マイルストーン 0: `terraform init` が成功する、`npm run dev` でNext.jsが起動する

---

### 1-2. 認証機能（目安: 1日）

#### Terraform (Cognito)
- [ ] `terraform/modules/cognito/main.tf`
  ```hcl
  # Cognito User Pool
  - email をユーザー名として使用
  - パスワードポリシー: 最低8文字
  - 自動メール検証
  # Cognito User Pool Client
  - SRP認証フロー
  - トークン有効期限: Access 1h, Refresh 30d
  ```

#### フロントエンド (認証UI)
- [ ] `frontend/src/lib/amplify-config.ts` - Amplify設定（Cognito接続情報）
- [ ] `frontend/src/app/layout.tsx` - AmplifyProvider ラップ
- [ ] `frontend/src/components/AuthGuard.tsx` - 認証ガード（未ログイン時リダイレクト）
- [ ] `frontend/src/app/page.tsx` - ログイン後のホーム画面
- [ ] Amplify UI の `<Authenticator>` コンポーネントでサインアップ/ログイン/ログアウト

#### API Gateway Authorizer
- [ ] `terraform/modules/api_gateway/main.tf`
  - REST API 作成
  - Cognito Authorizer 設定
  - CORS 設定

#### マイルストーン 1: ブラウザでサインアップ → ログイン → ログアウトができる

---

### 1-3. AtCoder 提出履歴取得（目安: 2日）

#### DynamoDB テーブル作成
- [ ] `terraform/modules/dynamodb/main.tf`
  ```
  users テーブル:
    PK: user_id (String) - CognitoのsubをそのままPKに
    属性: atcoder_username, created_at, updated_at

  submissions テーブル:
    PK: user_id (String)
    SK: submission_id (String) - "SUB#{atcoder_submission_id}"
    属性: problem_id, contest_id, language, result, score,
          code_length, execution_time, submitted_at, source_code
    
  problems テーブル:
    PK: problem_id (String) - "PROBLEM#{problem_id}"
    属性: contest_id, title, difficulty
  ```

#### Lambda: sync_submissions
- [ ] `backend/lambdas/sync_submissions/handler.py`
  ```python
  def handler(event, context):
      # 1. リクエストからuser_id, atcoder_usernameを取得
      # 2. AtCoder Problems API呼び出し
      #    GET https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions
      #    ?user={username}&from_second={last_sync_epoch}
      # 3. 各提出のメタデータをDynamoDBに保存
      # 4. (オプション) AtCoder本体から提出コードをスクレイピング
      #    - 1提出あたり2秒のスリープ
      #    - Lambda5分制限があるためバッチサイズを制限（最大100件/回）
      # 5. 同期結果を返す（取得件数、残件数）
  ```

- [ ] `backend/shared/atcoder_client.py`
  ```python
  class AtCoderClient:
      def get_submissions(username, from_second=0) -> list[dict]
          # AtCoder Problems API からメタデータ取得
      
      def get_source_code(contest_id, submission_id) -> str
          # AtCoder本体からHTMLパース
          # time.sleep(2) でレート制限
  ```

- [ ] `backend/shared/db.py`
  ```python
  class SubmissionRepository:
      def save_submissions(user_id, submissions: list[dict])
      def get_submissions(user_id, limit=50, next_token=None)
      
  class UserRepository:
      def save_user(user_id, atcoder_username)
      def get_user(user_id)
  ```

#### Lambda: get_submissions
- [ ] `backend/lambdas/get_submissions/handler.py`
  ```python
  def handler(event, context):
      # 1. user_id をCognito JWTから取得
      # 2. DynamoDBからsubmissionsをクエリ
      # 3. ページネーション対応（LastEvaluatedKey → nextToken）
      # 4. レスポンス返却
  ```

#### API Gateway エンドポイント
- [ ] `POST /users/me` - AtCoderユーザー名登録
- [ ] `POST /submissions/sync` - 提出履歴同期開始
- [ ] `GET /submissions` - 提出一覧取得（クエリパラメータ: limit, nextToken）

#### Lambda デプロイ設定 (Terraform)
- [ ] `terraform/modules/lambda/main.tf`
  - Lambda関数定義（zip デプロイ）
  - IAMロール（DynamoDB読み書き権限）
  - API Gateway統合

#### マイルストーン 2: curlでAPI叩いて提出データがDynamoDBに保存される

---

### 1-4. フロントエンド（目安: 1.5日）

#### 画面構成
```
/                → ホーム（ログイン後ダッシュボード的なもの）
/settings        → AtCoderユーザー名の登録
/submissions     → 提出一覧
```

#### コンポーネント
- [ ] `frontend/src/app/settings/page.tsx`
  - AtCoderユーザー名の入力フォーム
  - 保存ボタン → `POST /users/me`
  
- [ ] `frontend/src/app/submissions/page.tsx`
  - 「提出履歴を同期」ボタン → `POST /submissions/sync`
  - 同期中のローディング表示
  - 提出一覧テーブル（問題名, コンテスト, 結果, 言語, 提出日時）
  - ページネーション（もっと読み込むボタン）
  
- [ ] `frontend/src/app/submissions/[id]/page.tsx`
  - 提出詳細（ソースコード表示）
  - シンタックスハイライト（`prism-react-renderer` を使用）

- [ ] `frontend/src/lib/api.ts`
  ```typescript
  // Amplify の Auth から JWT を取得して Authorization ヘッダーに付与
  const apiClient = {
    post: (path, body) => fetch(API_URL + path, { headers: { Authorization: token }, body }),
    get: (path, params) => fetch(API_URL + path + '?' + params, { headers: { Authorization: token } }),
  }
  ```

- [ ] `frontend/src/components/SubmissionTable.tsx` - 提出一覧テーブル
- [ ] `frontend/src/components/CodeViewer.tsx` - ソースコード表示
- [ ] `frontend/src/components/Layout.tsx` - 共通レイアウト（ヘッダー、ナビゲーション）

#### マイルストーン 3: ブラウザで提出履歴の同期と一覧表示ができる

---

### 1-5. デプロイ（目安: 1日）

#### Amplify Hosting
- [ ] `terraform/modules/hosting/main.tf`
  - Amplify App + Branch 設定
  - ビルド設定（`next build`）
  - 環境変数（API Gateway URL, Cognito設定）

#### GitHub Actions
- [ ] `.github/workflows/deploy.yml`
  ```yaml
  on:
    push:
      branches: [main]
  jobs:
    deploy-infra:
      # terraform plan → apply
    deploy-backend:
      # Lambda のzip作成 → S3アップロード → Lambda更新
    deploy-frontend:
      # Amplify が自動デプロイ（Git連携）またはCLIデプロイ
  ```

#### マイルストーン 4: 本番URLでアプリが動作する

---

## 2. 実装順序サマリ

```
Day 1 (前半): 1-1 基盤 + 1-2 Cognito Terraform
Day 1 (後半): 1-2 フロント認証UI + API Gateway
Day 2:        1-3 DynamoDB + Lambda (sync_submissions)
Day 3 (前半): 1-3 Lambda (get_submissions) + API統合テスト
Day 3 (後半): 1-4 フロントエンド（設定画面 + 一覧画面）
Day 4 (前半): 1-4 フロントエンド（詳細画面 + 結合テスト）
Day 4 (後半): 1-5 デプロイ + CI/CD
Day 5:        バグ修正 + 最終確認
```

---

## 3. MVPで意図的にスキップするもの

| スキップ項目 | 理由 |
|---|---|
| 問題文の取得・表示 | Phase 2 でタグ付けと合わせて実装 |
| タグ・カテゴリ機能 | Phase 2 |
| AI機能全般 | Phase 2-3 |
| グラフ・可視化 | Phase 4 |
| テストコード | MVP後に追加（ただしローカル動作確認は行う） |
| エラーリトライ | 基本的なエラー表示のみ |
| レスポンシブデザイン | PC表示のみで十分 |
| ダークモード | 不要 |
| 提出コードのスクレイピング | MVP段階ではメタデータのみでも可（コード取得は任意） |

---

## 4. 想定される技術的課題と解決方針

### AtCoderスクレイピング
- **課題**: レート制限、HTML構造変更、Lambda 5分制限
- **解決**: 2秒間隔、1回のsyncで最大100件に制限、`from_second` パラメータで差分取得、HTMLパースはBeautifulSoupで堅牢に

### Cognito連携のハマりポイント
- **課題**: Amplify v6 の設定方法が変わっている、CORS設定ミス
- **解決**: 公式ドキュメントの最新版に従う、API Gatewayの CORS は Terraform で明示設定

### Lambda デプロイ
- **課題**: 依存ライブラリの含め方、shared モジュールの参照
- **解決**: Lambda Layer で共通ライブラリをまとめるか、zip作成時に `shared/` をコピーして含める（MVP段階では後者がシンプル）

### DynamoDB のアイテムサイズ
- **課題**: source_code が大きい場合 400KB制限に引っかかる
- **解決**: MVP段階では source_code を最大100KB に切り詰め。超えるものは Phase 2 で S3 オフロードを検討
