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

**Phase 1 / Task 2: Backend — Python 環境セットアップ** の学習段階。

### Task 1 完了（2026-04-18 採点済み）

Task 1「Terraform DynamoDBモジュール」で習得:
- DynamoDB キー設計（PK/SK/GSI）、RDB比較、スキーマレス、Single Table Design
- DynamoDB = 分散ハッシュテーブル（DHT）のメンタルモデル、Dynamo論文系譜
- Terraform の基本（HCL構文、モジュール構造、variables/outputs）、Bootstrap パターン、state locking
- AWS IAM（ユーザー/ロール/ポリシー、Identity Center）、AWS認証のベストプラクティス
- 設計原則（YAGNI、明示性、最小公開）

振り返り採点結果: Q5(b) default の使い分け（ルート側）、Q6(b) ARN の構成要素 が **要復習** → `docs/learning/review-queue.md` に記録済み。

### Task 2 概要

`backend/requirements.txt`、`backend/requirements-dev.txt`、`backend/tests/conftest.py` を整備し、**Lambda向けPython開発環境 + moto によるDynamoDBモック**をセットアップする。コード自体は少ないが、以下の新概念に触れる:

- **moto**: AWSサービスをローカルで完全エミュレーションするライブラリ
- **pytest fixture**: テスト用の前提条件を関数として定義する仕組み
- **monkeypatch**: 環境変数・関数をテスト中だけ差し替えるpytest機能
- **venv**: Pythonの仮想環境（プロジェクトごとに依存を隔離）

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
