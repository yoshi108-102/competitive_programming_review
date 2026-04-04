# AtCoder 復習支援ツール - プロジェクト計画書

## 概要

AtCoderの提出履歴をもとに、解法パターンの整理・分類、AIによる振り返り、苦手分野の可視化、次に取り組むべき問題のレコメンドを行うWebアプリケーション。

---

## 技術スタック

| 領域 | 技術 |
|---|---|
| フロントエンド | Next.js (App Router) / TypeScript |
| ホスティング | AWS Amplify Hosting（または S3 + CloudFront） |
| 認証 | Amazon Cognito |
| API | Amazon API Gateway + AWS Lambda (Python) |
| データベース | Amazon DynamoDB |
| AI | Amazon Bedrock (Claude) |
| 外部データ | AtCoder Problems API + AtCoderスクレイピング |
| IaC | Terraform |
| CI/CD | GitHub Actions |

---

## アーキテクチャ

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│  Next.js    │────▶│ API Gateway  │────▶│  Lambda         │
│  (Amplify)  │     │              │     │  (Python)       │
└─────────────┘     └──────────────┘     └────────┬────────┘
      │                                           │
      │                                    ┌──────┴──────┐
      │                                    │             │
┌─────┴─────┐                        ┌─────▼───┐  ┌─────▼─────┐
│  Cognito  │                        │ DynamoDB │  │  Bedrock  │
│  (認証)   │                        │          │  │  (Claude) │
└───────────┘                        └──────────┘  └───────────┘
                                          ▲
                                          │
                                   ┌──────┴──────┐
                                   │ AtCoder     │
                                   │ Problems API│
                                   │ + Scraping  │
                                   └─────────────┘
```

---

## DynamoDB テーブル設計（案）

### users テーブル
| キー | 属性 |
|---|---|
| PK: `USER#{userId}` | atcoder_username, created_at, updated_at |

### submissions テーブル
| キー | 属性 |
|---|---|
| PK: `USER#{userId}` | - |
| SK: `SUB#{submissionId}` | problem_id, contest_id, language, result (AC/WA/TLE等), score, code_length, execution_time, submitted_at, source_code |

### problems テーブル
| キー | 属性 |
|---|---|
| PK: `PROBLEM#{problemId}` | contest_id, title, difficulty, tags (自動+手動), category |
| GSI1 PK: `TAG#{tag}` | difficulty でソート可能にする |

### reviews テーブル（Phase 2以降）
| キー | 属性 |
|---|---|
| PK: `USER#{userId}` | - |
| SK: `REVIEW#{problemId}` | memo, ai_summary, chat_history, created_at, updated_at |

---

## フェーズ分け

### Phase 1: 認証 + 提出履歴取得（MVP）
**ゴール**: ログインして、AtCoderの提出履歴を取得・保存・一覧表示できる

#### 1-1. プロジェクト基盤構築
- [ ] Git リポジトリ初期化、ディレクトリ構成の決定
- [ ] Terraform の初期セットアップ（backend: S3 + DynamoDB for state管理）
- [ ] Next.js プロジェクト作成

#### 1-2. 認証機能
- [ ] Cognito User Pool を Terraform で構築
- [ ] Next.js にサインアップ / ログイン / ログアウト画面を実装
- [ ] API Gateway の Cognito Authorizer 設定

#### 1-3. AtCoder 提出履歴取得
- [ ] Lambda: AtCoder Problems API から提出メタデータを取得
- [ ] Lambda: AtCoder本体から提出コードをスクレイピング（レート制限付き）
- [ ] DynamoDB に提出データを保存
- [ ] API Gateway エンドポイント: `POST /submissions/sync` （取得開始）
- [ ] API Gateway エンドポイント: `GET /submissions` （一覧取得）

#### 1-4. フロントエンド（提出一覧）
- [ ] AtCoder ユーザー名の登録画面
- [ ] 「提出履歴を取得」ボタン + 取得状況の表示
- [ ] 提出一覧画面（問題名、結果、日時、コードの閲覧）

#### 1-5. デプロイ
- [ ] Amplify Hosting（または S3 + CloudFront）で Next.js をデプロイ
- [ ] GitHub Actions で Terraform apply + フロントデプロイの CI/CD

---

### Phase 2: 問題のタグ付け・分類
**ゴール**: 問題にAI自動タグ + 手動タグを付けて、分類・フィルタリングできる

- [ ] Bedrock (Claude) で問題文 + 提出コードからタグを自動生成
- [ ] 手動タグの追加・編集 UI
- [ ] タグ別の問題一覧フィルタリング
- [ ] problems テーブルへのタグ保存

---

### Phase 3: AI 振り返りチャット + メモ
**ゴール**: 問題ごとにAIと対話して振り返り、メモを残せる

- [ ] Bedrock (Claude) を使った振り返りチャット API
  - 問題文、提出コード、結果をコンテキストとして渡す
  - 「なぜ解けなかったか」「どう考えればよかったか」を対話的に深掘り
- [ ] チャット履歴の保存 (reviews テーブル)
- [ ] メモの作成・編集 UI
- [ ] AI によるサマリ自動生成

---

### Phase 4: ダッシュボード + 弱点可視化
**ゴール**: 解いた問題の傾向を可視化し、苦手分野を特定できる

- [ ] ダッシュボード画面
  - 解いた問題数の推移（時系列グラフ）
  - タグ別の正答率
  - difficulty 別の分布
- [ ] 苦手分野の可視化
  - タグ × difficulty のヒートマップ
  - クラスタリングによる弱点の可視化（Bedrock で分析）

---

### Phase 5: 次に取り組むべき問題のレコメンド
**ゴール**: AIが苦手分野・未解決問題からおすすめ問題を提示する

- [ ] AtCoder Problems API から未解決問題リストを取得
- [ ] Bedrock (Claude) による推薦ロジック
  - 苦手タグ・difficulty帯を考慮
  - 直近の学習状況を加味
- [ ] レコメンド結果の表示画面

---

## ディレクトリ構成（案）

```
competitive_programming_review/
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── modules/
│   │   ├── cognito/
│   │   ├── dynamodb/
│   │   ├── api_gateway/
│   │   ├── lambda/
│   │   └── hosting/
│   └── environments/
│       └── prod/
├── backend/
│   ├── lambdas/
│   │   ├── sync_submissions/    # 提出履歴取得
│   │   ├── get_submissions/     # 提出一覧API
│   │   ├── tag_problems/        # タグ付け (Phase 2)
│   │   ├── review_chat/         # AIチャット (Phase 3)
│   │   └── recommend/           # レコメンド (Phase 5)
│   ├── shared/                  # Lambda共通コード
│   │   ├── atcoder_client.py    # AtCoder API/スクレイピング
│   │   └── db.py                # DynamoDB操作
│   └── requirements.txt
├── frontend/
│   ├── src/
│   │   ├── app/                 # Next.js App Router
│   │   ├── components/
│   │   ├── lib/                 # API クライアント、認証
│   │   └── types/
│   ├── package.json
│   └── next.config.js
├── .github/
│   └── workflows/
│       └── deploy.yml
├── PLAN.md
└── README.md
```

---

## コスト見積もり（月額概算）

個人利用・低トラフィック前提

| サービス | 想定コスト |
|---|---|
| Cognito | 無料（MAU 50,000以下） |
| DynamoDB | ~$1〜3（オンデマンド、低トラフィック） |
| Lambda | ~$0（無料枠内に収まる見込み） |
| API Gateway | ~$0〜1 |
| Amplify Hosting | ~$0〜1 |
| Bedrock (Claude) | ~$3〜10（使用量次第） |
| **合計** | **~$5〜15/月** |

---

## 開発の進め方

1. **各フェーズで都度相談しながら進める**（勝手に実装しない）
2. Terraform で AWS リソースを先に作り、動作確認してからフロントを繋ぐ
3. 各 Phase の開始時に詳細設計を行い、合意してから実装に入る

---

## 補足: AtCoder データ取得戦略

- **メタデータ**: AtCoder Problems API (`/v3/user/submissions`) から取得。レート制限なし（常識的な範囲で）
- **提出コード**: AtCoder本体 (`/contests/{contest}/submissions/{id}`) からHTMLをパースして取得
  - レート制限: 1〜2秒間隔
  - 一度取得したコードはDBに保存し、再取得しない
  - コンテスト時間帯のスクレイピングは避ける
  - ユーザーのボタン操作起点でのみ実行
