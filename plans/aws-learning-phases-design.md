# AtCoder 復習支援ツール - AWS学習Phase設計書

## 概要

AtCoderの提出履歴をもとに復習を支援するWebアプリケーションを、AWS学習を主目的として段階的に構築する。各PhaseでAWSサービスを1-2個ずつ導入し、じっくり理解しながらシステムを成熟させる。

## 設計方針

- **1 Phaseあたり新規AWSサービスは1-2個** に抑え、段階的に学ぶ
- **インフラ成熟度軸** で進める: 最初はシンプルに動かし、同じ機能をよりAWSらしい構成に育てる
- **機能追加と運用改善を織り交ぜる**: 新機能だけでなく、監視・セキュリティ・トレーシング等の運用スキルも習得する
- **セキュリティはAI導入前に整備する**: コストの発生するBedrock導入前にCloudFront + WAFで保護する

## 技術スタック全体像

| サービス | 導入Phase | カテゴリ |
|---|---|---|
| Cognito | Phase 1 | 認証 |
| API Gateway | Phase 1 | API管理 |
| Lambda | Phase 1 | コンピュート |
| DynamoDB | Phase 1 | データベース |
| Amplify Hosting | Phase 1 | ホスティング |
| S3 | Phase 2 | ストレージ |
| SQS | Phase 3 | メッセージング |
| CloudWatch | Phase 4 | 監視 |
| CloudFront | Phase 5 | CDN / セキュリティ |
| WAF | Phase 5 | セキュリティ |
| Bedrock (Claude) | Phase 6 | AI |
| EventBridge | Phase 7 | イベント駆動 |
| Step Functions | Phase 8 | ワークフロー |
| X-Ray | Phase 9 | トレーシング |
| SNS | Phase 10 | 通知 |

## IaC / CI/CD

| 領域 | 技術 |
|---|---|
| IaC | Terraform |
| CI/CD | GitHub Actions |
| フロントエンド | Next.js (App Router) / TypeScript |
| バックエンド | AWS Lambda (Python) |

---

## Phase 1: MVP

**新規AWSサービス**: Cognito, API Gateway, Lambda, DynamoDB, Amplify Hosting
**ゴール**: ログインして、AtCoderの提出履歴を取得・保存・一覧表示できる

### 構成

```
[ユーザー] → [Next.js (Amplify Hosting)] → [API Gateway + Cognito Authorizer]
                                                    │
                                          ┌─────────┴─────────┐
                                          │                    │
                                [Lambda: sync_submissions]  [Lambda: get_submissions]
                                          │                    │
                                          ▼                    ▼
                                [AtCoder Problems API]     [DynamoDB]
                                [AtCoder スクレイピング] ──▶ [DynamoDB]
```

### 実装内容

- Terraform でAWSリソースを一括構築（Cognito, API Gateway, Lambda, DynamoDB, Amplify Hosting）
- Cognito User Pool + Amplify UI `<Authenticator>` でサインアップ/ログイン/ログアウト
- `sync_submissions` Lambda: AtCoder Problems APIからメタデータ取得、AtCoder本体からソースコードスクレイピング、DynamoDBに保存
- `get_submissions` Lambda: DynamoDBから提出一覧をページネーション付きで取得
- APIエンドポイント: `POST /users/me`, `POST /submissions/sync`, `GET /submissions`
- フロントエンド: ユーザー名登録、同期ボタン + 進捗表示、提出一覧、コード表示

### 学ぶこと

- Cognito User Pool の構築と認証フロー（SRP認証、JWT）
- API Gateway REST API + Cognito Authorizer
- Lambda関数の作成・デプロイ（Python、IAMロール設定）
- DynamoDB のテーブル設計、クエリ、ページネーション
- Amplify Hosting によるNext.jsデプロイ
- Terraform によるAWSリソースの一括管理

### DynamoDB テーブル設計

**users テーブル**:
- PK: `user_id` (Cognito sub)
- 属性: `atcoder_username`, `created_at`, `updated_at`, `last_sync_epoch`

**submissions テーブル**:
- PK: `user_id`
- SK: `SUB#{submission_id}`
- 属性: `problem_id`, `contest_id`, `language`, `result`, `score`, `code_length`, `execution_time`, `submitted_at`, `source_code`, `difficulty`

**problems テーブル**:
- PK: `PROBLEM#{problem_id}`
- GSI1 PK: `TAG#{tag}`, GSI1 SK: `DIFFICULTY#{difficulty}`
- 属性: `contest_id`, `title`, `difficulty`, `tags`, `category`

### 設計上の注意点（エンジニアBレビューより）

- `userId` は必ず Cognito JWT の `sub` クレームから取得する（リクエストボディからの取得は禁止）
- submissions保存時に `difficulty` を非正規化して保存する（Phase後半の集計に備える）
- APIレスポンス形式を `{ data, meta: { nextToken } }` に統一する
- `BatchWriteItem` (25件ずつ) を `sync_submissions` で使用する
- `from_second`（最後の同期時刻）を users テーブルに保存し、差分同期を可能にする
- Lambda の IAM ロールは機能単位で分離する（sync用とget用で別ロール）

---

## Phase 2: S3（ストレージ分離）

**新規AWSサービス**: S3
**ゴール**: ソースコードがS3に保存され、フロントから閲覧できる

### 背景

DynamoDBの400KBアイテムサイズ制限により、大きなソースコードの保存に問題が生じる。ソースコードをS3にオフロードし、DynamoDBにはS3キーのみを保持する。

### 構成変更

```
[Lambda: sync_submissions] ──▶ [S3: ソースコード保存]
                               [DynamoDB: S3キーのみ保持]

[Lambda: get_submissions]  ──▶ [S3: 署名付きURL発行] ──▶ [フロント: コード表示]
```

### 実装内容

- S3バケットをTerraformで作成（サーバーサイド暗号化、バージョニング、ライフサイクルポリシー）
- `sync_submissions` Lambdaの改修: ソースコードをS3に保存し、DynamoDBには `s3_key` を保持
- 提出詳細取得時にS3から署名付きURL（Presigned URL）を発行して返却
- フロントのコード表示を署名付きURL経由に変更
- Lambda IAMロールにS3権限を追加

### S3バケット設計

- バケット名: `{project_name}-source-code-{environment}`
- キー構造: `users/{user_id}/submissions/{submission_id}.txt`
- 暗号化: AES-256 (SSE-S3)
- パブリックアクセス: 全ブロック
- 署名付きURLの有効期限: 15分

### 学ぶこと

- S3バケットの作成・設定（暗号化、バージョニング、ライフサイクル）
- Lambda から S3 への読み書き（`boto3` の `put_object` / `get_object`）
- 署名付きURL（Presigned URL）の発行と利用
- IAMポリシーでのS3アクセス制御（バケットポリシー、IAMロール）

---

## Phase 3: SQS（非同期処理）

**新規AWSサービス**: SQS
**ゴール**: 同期ボタンを押すと即座に応答が返り、バックグラウンドで処理が進む

### 背景

Phase 2までは `sync_submissions` Lambdaが同期的にAtCoderからデータを取得している。提出件数が多いとLambdaの5分タイムアウトに抵触するリスクがあり、ユーザーはレスポンスを待ち続ける。SQSによるキューイングでこの問題を解決する。

### 構成変更

```
[API Gateway: POST /submissions/sync]
      │
      ▼
[Lambda: enqueue_sync] ──▶ [SQS: sync-queue] ──▶ [Lambda: process_sync]
      │                           │                       │
      ▼                           ▼                       ▼
[即座にレスポンス]         [DLQ: sync-dlq]         [S3 + DynamoDB に保存]
```

### 実装内容

- SQSキュー（標準キュー）をTerraformで作成
- デッドレターキュー（DLQ）を作成し、maxReceiveCount=3 で設定
- `POST /submissions/sync` の動作変更: SQSにメッセージをエンキューして即座にレスポンス返却
- 新規Lambda `process_sync`: SQSトリガーで起動し、AtCoderデータ取得を実行
- DynamoDBに同期ステータスを保存（`pending` / `in_progress` / `completed` / `failed`）
- `GET /submissions/sync/status` エンドポイント追加
- フロントで同期進捗のポーリング表示

### SQS設計

- キュー名: `{project_name}-sync-queue-{environment}`
- DLQキュー名: `{project_name}-sync-dlq-{environment}`
- 可視性タイムアウト: 360秒（Lambda 5分 + バッファ）
- メッセージ保持期間: 4日
- DLQ maxReceiveCount: 3

### 学ぶこと

- SQSキューの作成・設定（標準キュー、可視性タイムアウト、保持期間）
- デッドレターキュー（DLQ）によるエラーハンドリングパターン
- SQS → Lambda トリガーの設定（イベントソースマッピング）
- 非同期処理パターン（リクエスト/レスポンスの分離、ステータスポーリング）

---

## Phase 4: CloudWatch（監視基盤）

**新規AWSサービス**: CloudWatch
**ゴール**: Lambdaのエラーやキュー滞留に気づける監視体制が整い、ダッシュボードで稼働状況を確認できる

### 背景

Phase 3までで複数のLambdaとSQSが稼働している。問題が起きたときに気づける仕組みがないため、ここで監視基盤を整備する。

### 実装内容

- Lambda内のログ出力を構造化JSON形式に統一（`json.dumps()` 形式）
- CloudWatch Logs Insightsでクエリを書いて同期処理の状況を分析
- カスタムメトリクスの作成（`PutMetricData`）: 同期成功/失敗件数、処理時間
- CloudWatchアラームの設定:
  - DLQにメッセージが溜まったらアラーム
  - Lambdaエラー率が閾値を超えたらアラーム
  - Lambda実行時間が閾値を超えたらアラーム
- CloudWatchダッシュボードで主要メトリクスを一覧表示
- アラームのアクション先は Phase 10 (SNS) で接続するため、この段階では `OK` / `ALARM` 状態の確認のみ

### 学ぶこと

- 構造化ログの設計とCloudWatch Logs Insightsクエリ
- カスタムメトリクスの発行（`PutMetricData` API）
- CloudWatchアラームの設定（閾値、期間、評価回数）
- CloudWatchダッシュボードの構築（ウィジェット、レイアウト）

---

## Phase 5: CloudFront + WAF（セキュリティ強化）

**新規AWSサービス**: CloudFront, WAF
**ゴール**: フロントがCDN経由で高速配信され、APIがWAFで保護されている

### 背景

次のPhase 6でBedrock（AI）を導入する。BedrockはAPI呼び出しごとにコストが発生するため、不正アクセスやAPI濫用を防ぐセキュリティ基盤を先に整備する。

### 構成変更

```
[ユーザー] ──▶ [CloudFront + WAF] ──▶ [Amplify Hosting (フロント)]
                     │
                     ▼
              [API Gateway] ──▶ [Lambda]
```

### 実装内容

- CloudFrontディストリビューションをTerraformで作成
- フロントエンド配信をCloudFront経由に変更
- API Gateway前段にもCloudFrontを配置し、GET系APIのレスポンスキャッシュを設定
- WAF Web ACLの作成:
  - レートベースルール（API呼び出し頻度の制限）
  - AWSマネージドルール（SQLインジェクション、XSS防止）
  - IP制限（必要に応じて）
- WAFをCloudFrontに関連付け
- WAFログをS3に保存

### 学ぶこと

- CloudFrontディストリビューションの設定（オリジン、ビヘイビア、キャッシュポリシー）
- CloudFront + S3 の OAC（Origin Access Control）設定
- WAF Web ACLとマネージドルールの活用
- レートベースルールによるAPI保護
- WAFログの保存と分析

---

## Phase 6: Bedrock（AI機能）

**新規AWSサービス**: Bedrock (Claude)
**ゴール**: 問題にAIタグが自動付与され、問題ごとにAIと振り返りチャットができる

### 背景

Phase 5でセキュリティを固めた状態で、AI機能を安全に導入する。元の計画のPhase 2（タグ付け）とPhase 3（AIチャット）を統合し、学ぶサービスをBedrockに集中させる。

### 構成変更

```
[Lambda: tag_problems]   ──▶ [Bedrock (Claude)] ──▶ [DynamoDB: tags更新]
[Lambda: review_chat]    ──▶ [Bedrock (Claude)] ──▶ [DynamoDB: reviews保存]
```

### 実装内容

- Bedrock のモデルアクセス有効化（Claude）
- Lambda IAMロールに Bedrock 呼び出し権限（`bedrock:InvokeModel`）を追加
- `tag_problems` Lambda: 問題文 + 提出コード + 判定結果を入力として、タグを自動生成
- `review_chat` Lambda: 問題ごとのコンテキスト（問題文、提出コード、結果、言語）を渡してAIと対話
- reviews テーブルをDynamoDBに追加:
  - PK: `USER#{userId}`, SK: `REVIEW#{problemId}`
  - 属性: `memo`, `ai_summary`, `chat_history`, `created_at`, `updated_at`
- フロントにタグ表示・手動編集UI、チャットUI、メモ編集UIを追加
- レスポンスストリーミング対応（チャットのリアルタイム表示）

### Bedrock呼び出し設計

- タグ生成: 問題文 + コードからカテゴリタグを生成（1回の呼び出し、結果をキャッシュ）
- チャット: 会話履歴を含めたマルチターン対話（`chat_history` から直近N件を渡す）
- チャット履歴が400KB制限に近づいた場合はAIサマリに圧縮して保存

### 学ぶこと

- Bedrock のモデル呼び出し（InvokeModel API, InvokeModelWithResponseStream API）
- プロンプト設計（タグ生成用、チャット用でコンテキストの渡し方が異なる）
- Bedrock のIAMポリシー設計
- レスポンスストリーミング（チャットのリアルタイム表示）

---

## Phase 7: EventBridge（スケジュール実行）

**新規AWSサービス**: EventBridge
**ゴール**: 提出履歴が自動で定期同期され、設定画面からON/OFFできる

### 背景

ここまではユーザーが手動で同期ボタンを押す必要がある。AtCoderでコンテストに参加するたびに手動同期するのは面倒なので、EventBridgeで定期同期を自動化する。Phase 3で作ったSQSパイプラインを再利用する。

### 構成変更

```
[EventBridge スケジュールルール] ──▶ [SQS: sync-queue] ──▶ [Lambda: process_sync]
```

### 実装内容

- EventBridge スケジュールルールをTerraformで作成（例: 毎日1回）
- スケジュールからSQSにメッセージを投入し、Phase 3の非同期パイプラインを再利用
- ユーザーごとの同期設定をDynamoDBに保存（有効/無効、頻度）
- フロントに自動同期の設定画面を追加（ON/OFF切り替え）
- Phase 4のCloudWatchダッシュボードに定期同期のメトリクスを追加

### 学ぶこと

- EventBridge スケジュールルールの作成・管理（cron式 / rate式）
- EventBridge → SQS のイベントルーティング
- IAMロールによるEventBridgeの実行権限設定
- 既存の非同期パイプライン（Phase 3 SQS）との統合パターン

---

## Phase 8: Step Functions（ワークフロー管理）

**新規AWSサービス**: Step Functions
**ゴール**: 同期処理がStep Functionsで管理され、各ステップの成功/失敗がコンソール上で可視化される

### 背景

Phase 3でSQS非同期化、Phase 7でEventBridge定期実行と、同期処理が複雑化してきている。実際のフローは「メタデータ取得 → ソースコード取得 → S3保存 → タグ自動生成」と複数ステップを跨ぐ。Step Functionsで可視化・制御し、エラー時のリトライや途中再開を明確にする。

### 構成変更

```
[SQS / EventBridge] ──▶ [Step Functions ステートマシン]
                               │
                    ┌──────────┼──────────┬──────────┐
                    ▼          ▼          ▼          ▼
              [メタデータ取得] [コード取得] [S3+DB保存] [タグ生成]
              [Lambda]       [Lambda]    [Lambda]   [Lambda]
```

### ステートマシン定義

1. **FetchMetadata**: AtCoder Problems APIからメタデータ取得
2. **ScrapeCodes**: 各提出のソースコードをスクレイピング（Map stateで処理、レート制限のためWait state挿入）
3. **StoreData**: S3 + DynamoDB に保存
4. **GenerateTags**: Bedrock でタグ自動生成（Phase 6で作成済みのロジックを再利用）
5. **NotifyCompletion**: 完了ステータスをDynamoDBに書き込み

### 実装内容

- Step Functions ステートマシンをTerraformで作成（ASL定義）
- 既存の `process_sync` Lambda を各ステップに分割
- SQSトリガーの起動先をStep Functionsに変更
- 各ステップにRetry / Catch設定を追加
- Step Functionsコンソールで実行状況を可視化

### 学ぶこと

- ステートマシンの定義（Amazon States Language）
- Task / Map / Choice / Wait / Parallel ステートの使い分け
- エラーハンドリング（Retry, Catch, Fallback）
- Step Functions → Lambda のサービス統合
- 実行履歴の可視化とデバッグ

---

## Phase 9: X-Ray（分散トレーシング）

**新規AWSサービス**: X-Ray
**ゴール**: リクエストの流れがサービスマップで可視化され、ボトルネックを特定できる

### 背景

Phase 8までで API Gateway → Lambda → SQS → Step Functions → Lambda → S3 / DynamoDB / Bedrock と、呼び出しチェーンが長くなっている。「リクエストがどこで遅いか」「どのサービス間でエラーが起きたか」を追跡するためにX-Rayを導入する。Phase 4のCloudWatchが「何が起きたか」なら、X-Rayは「どう流れたか」を見るツール。

### 実装内容

- API GatewayのX-Rayトレーシング有効化
- 各LambdaでX-Ray SDKを導入（`aws-xray-sdk-python`）
- DynamoDB、S3、Bedrock への呼び出しを自動計測（SDK パッチ適用）
- Step Functionsのトレーシング有効化
- カスタムサブセグメントの追加（AtCoderスクレイピング処理の計測）
- X-Rayのサービスマップでシステム全体のリクエストフローを可視化
- Phase 4のCloudWatchダッシュボードにX-Rayのレイテンシメトリクスを追加

### 学ぶこと

- X-Ray のトレース・セグメント・サブセグメントの概念
- Lambda / API Gateway でのX-Ray有効化
- X-Ray SDK によるAWSサービス呼び出しの自動計測（パッチ適用パターン）
- サービスマップの読み方とボトルネック特定
- CloudWatchとX-Rayの連携

---

## Phase 10: SNS（通知統合）

**新規AWSサービス**: SNS
**ゴール**: システムの各種イベントがメール通知され、運用上の問題にすぐ気づける

### 背景

Phase 4でCloudWatchアラームを設定済みだが、通知先が未接続のまま。Phase 8のStep Functions完了通知、Phase 7のEventBridgeイベントなど、通知を繋ぎたい箇所が十分揃った段階で、SNSをまとめて統合する。

### 実装内容

- SNSトピックをTerraformで作成（アラーム通知用、同期完了通知用）
- メールサブスクリプションの設定
- CloudWatchアラームのアクション先にSNSトピックを設定:
  - DLQ滞留アラーム → SNS通知
  - Lambdaエラー率アラーム → SNS通知
  - Lambda実行時間アラーム → SNS通知
- Step Functions ステートマシンの完了/失敗時にSNS通知を追加
- Lambda IAMロールにSNS Publish権限を追加

### 学ぶこと

- SNSトピックの作成とサブスクリプション管理
- SNSのメッセージフィルタリング
- CloudWatch Alarm → SNS の連携パターン
- Step Functions → SNS のサービス統合
- IAMポリシーでのSNS Publish権限設定

---

## Phase間の依存関係

```
Phase 1 (MVP)
  └──▶ Phase 2 (S3) ── ソースコード保存の改善
        └──▶ Phase 3 (SQS) ── 同期処理の非同期化
              └──▶ Phase 4 (CloudWatch) ── 稼働中システムの監視
                    └──▶ Phase 5 (CloudFront + WAF) ── セキュリティ強化
                          └──▶ Phase 6 (Bedrock) ── AI機能の安全な導入
                                └──▶ Phase 7 (EventBridge) ── 定期同期の自動化
                                      └──▶ Phase 8 (Step Functions) ── ワークフロー管理
                                            └──▶ Phase 9 (X-Ray) ── 分散トレーシング
                                                  └──▶ Phase 10 (SNS) ── 通知の一括統合
```

## 最終アーキテクチャ（Phase 10完了時）

```
                          [CloudFront + WAF]
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
            [S3: 静的サイト]          [API Gateway + Cognito]
            [Amplify Hosting]               │
                                     ┌──────┴──────┐
                                     ▼              ▼
                              [Lambda群]      [Lambda群]
                              (同期系)         (参照系)
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
              [SQS + DLQ]           [EventBridge]
                    │                       │
                    └───────────┬───────────┘
                                ▼
                        [Step Functions]
                    ┌──────┬──────┬──────┐
                    ▼      ▼      ▼      ▼
                [Lambda] [Lambda] [Lambda] [Lambda]
                    │      │       │       │
              ┌─────┴──────┴───────┴───────┘
              ▼           ▼           ▼
          [DynamoDB]    [S3]     [Bedrock (Claude)]

  監視: [CloudWatch] + [X-Ray]    通知: [SNS]
```

## コスト見積もり（月額概算、個人利用・低トラフィック前提）

| サービス | 想定コスト |
|---|---|
| Cognito | 無料（MAU 50,000以下） |
| DynamoDB | ~$1-3（オンデマンド） |
| Lambda | ~$0（無料枠内） |
| API Gateway | ~$0-1 |
| S3 | ~$0-1 |
| SQS | ~$0（無料枠内） |
| CloudWatch | ~$0-3（カスタムメトリクス数による） |
| CloudFront | ~$0-1 |
| WAF | ~$5-6（Web ACL $5 + ルール $1/個） |
| Bedrock (Claude) | ~$3-10（使用量次第） |
| EventBridge | ~$0（無料枠内） |
| Step Functions | ~$0（無料枠内） |
| X-Ray | ~$0（無料枠内） |
| SNS | ~$0（無料枠内） |
| **合計** | **~$10-25/月** |

注: WAFの固定費用（Web ACL $5/月）が追加されるため、元の計画より若干コスト増。
