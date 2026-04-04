# テックリード: MVP設計方針書

## 1. MVP全体のアーキテクチャ設計方針

### コンポーネント構成とデータフロー

```
[ユーザー] → [Next.js (CSR)] → [API Gateway + Cognito Authorizer]
                                        │
                              ┌─────────┴─────────┐
                              │                    │
                    [Lambda: sync_submissions]  [Lambda: get_submissions]
                              │                    │
                              ▼                    ▼
                    [AtCoder Problems API]     [DynamoDB]
                    [AtCoder スクレイピング] ──▶ [DynamoDB]
```

### 設計原則
- **Stateless Lambda**: 各Lambda関数は独立・ステートレスに設計
- **API Gatewayは薄く**: ルーティングと認証のみ、ビジネスロジックはLambdaに集約
- **フロントエンドはCSR中心**: MVP段階ではSSRの複雑さを避け、Cognito認証後のSPA的な動作に集中
- **Terraformモジュール分離**: cognito / dynamodb / api_gateway / lambda / hosting の5モジュールで独立管理

---

## 2. 実装優先順位と依存関係グラフ

```
1-1. プロジェクト基盤
 ├── Terraform backend (S3 + DynamoDB for state)
 ├── Next.js 初期化
 └── ディレクトリ構成確定
      │
      ▼
1-2. 認証 ──────────────────────┐
 ├── Cognito User Pool (Terraform) │
 ├── Next.js 認証UI               │
 └── API Gateway Authorizer       │
      │                           │
      ▼                           ▼
1-3. バックエンド ◀─────── 1-4. フロントエンド
 ├── DynamoDB テーブル作成         ├── ユーザー名登録
 ├── Lambda: sync_submissions     ├── 同期ボタン + 進捗表示
 ├── Lambda: get_submissions      └── 提出一覧画面
 └── API Gateway エンドポイント
      │
      ▼
1-5. デプロイ
 ├── Amplify Hosting 設定
 └── GitHub Actions CI/CD
```

### クリティカルパス
**Terraform基盤 → Cognito → API Gateway + Lambda → フロント結合 → デプロイ**

### ブロッカー
- Cognito が立ち上がらないとAPI認証テストができない
- DynamoDB テーブルがないとLambda開発が進まない
- → **Terraform を最優先で完成させる**

---

## 3. 技術的判断ポイント

### SSR vs CSR
**判断: CSR (Client-Side Rendering) を採用**
- 理由: MVP段階ではSEO不要、認証後の画面のみ、Amplify HostingでのSSRは設定が複雑
- Next.js App Routerの `"use client"` ディレクティブを活用
- 静的エクスポート (`output: 'export'`) も選択肢だが、将来のSSR移行を考慮しAmplify Hostingで通常デプロイ

### Lambda構成
**判断: 機能単位で分離（2つのLambda）**
- `sync_submissions`: 同期処理（AtCoder APIコール + スクレイピング + DB書き込み）
  - タイムアウト: 5分（大量の提出履歴を処理するため）
  - メモリ: 256MB
- `get_submissions`: 読み取り専用（DynamoDBクエリ）
  - タイムアウト: 30秒
  - メモリ: 128MB

### DynamoDB設計のポイント
- **Single Table Design は採用しない**: テーブル数が少なくアクセスパターンが明確なため、テーブル分離の方が可読性・保守性が高い
- **submissionsテーブルのSK設計**: `SUB#{submissionId}` でAtCoderの提出IDをそのまま使用 → 冪等な同期が可能
- **オンデマンドキャパシティ**: 個人利用のため、Provisioned は不要

### 認証フロー
- Cognito Hosted UI は使わず、Amplify UI の `<Authenticator>` コンポーネントを使用
- JWTトークンをAPI Gatewayに渡す形式（Cognito Authorizer）

---

## 4. リスクと対策

| リスク | 影響 | 対策 |
|---|---|---|
| AtCoderスクレイピングのブロック | 提出コード取得不可 | レート制限厳守（2秒間隔）、User-Agent設定、robots.txt確認 |
| Lambda 5分タイムアウト超過 | 大量提出の同期失敗 | ページネーション実装、途中からの再開機能、最新N件のみ同期 |
| Cognito設定の複雑さ | 認証周りで時間消費 | Amplify UI ライブラリで定型処理を省力化 |
| AtCoder Problems API仕様変更 | データ取得不可 | APIレスポンスのバリデーション、エラー通知 |
| DynamoDBのコスト想定外 | 月額超過 | アイテムサイズ注意（source_codeが大きい場合）、必要に応じてS3にオフロード |

---

## 5. Phase 2以降への拡張を見据えた設計上の注意点

### MVPで最初から考慮すべきこと
- **APIレスポンス形式の統一**: `{ data: T, meta: { nextToken?: string } }` 形式に統一 → Phase 2以降のAPI追加時に一貫性を保てる
- **Lambda共有レイヤー**: `backend/shared/` にDB操作・AtCoderクライアントを配置 → Phase 2以降のLambdaからも再利用
- **Terraformモジュール構造**: 新しいLambdaやAPIエンドポイントを追加しやすい構造に
- **DynamoDBのキー設計**: `USER#` / `SUB#` / `PROBLEM#` のプレフィックス規約を守る

### MVPで作り込みすぎない部分
- **問題データの詳細取得**: Phase 1ではAtCoder Problems APIのメタデータのみ、問題文のスクレイピングはPhase 2以降
- **タグ・カテゴリ**: problemsテーブルにカラムは用意するが、MVP段階では空でよい
- **エラーハンドリングの完璧さ**: 基本的なエラー表示のみ、リトライ機構はPhase 2以降
- **テスト**: MVP段階ではE2Eテストは不要、Lambda単体のローカルテストのみ
- **モニタリング**: CloudWatch Logsの基本設定のみ、アラートはPhase 2以降
