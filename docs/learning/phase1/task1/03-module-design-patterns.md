# Terraformモジュール分割の設計パターン

## 概要

`terraform/modules/` をどういう単位で切るかの設計論。現在このプロジェクトは「AWSサービス単位」（`modules/cognito/`, `modules/dynamodb/` ...）で切っているが、これは唯一の正解ではなく、複数ある流派の1つ。プロジェクト規模・目的に応じて選ぶべき。

## 解説

### 主な流派

#### 流派1: AWSサービス単位で切る（現在このプロジェクト）

```
modules/
├── cognito/
├── api_gateway/
├── lambda/
├── dynamodb/
└── s3/
```

**特徴**:
- 直感的、初学者に優しい
- チュートリアルや AWS公式ブログ に多いパターン
- HashiCorp のコミュニティモジュール (`terraform-aws-modules`) もこの形

**向いてる場面**:
- 汎用モジュールとして公開・再利用する場合
- 学習プロジェクト

**弱点**:
- プロジェクトが大きくなると、`lambda/` に複数のLambda関数が混在
- 「この機能を使うのに必要なリソースは？」が分散（1機能理解に複数モジュールを見る必要）

#### 流派2: 機能/ドメイン単位で切る（logical component方式）

```
modules/
├── auth/              # Cognito + IAM Role
├── user_api/          # API Gateway route + Lambda + IAM
├── submission_sync/   # EventBridge + Lambda + DynamoDB access policy
└── storage/           # DynamoDB + S3 + バックアップ設定
```

**特徴**:
- 1つのビジネス機能 = 1モジュール
- 関連リソースを1箇所にまとめる → 認知負荷低減
- DDD やマイクロサービス設計の発想に近い
- Gruntwork や大規模エンタープライズでよく見られる

**向いてる場面**:
- プロダクション運用の本格的IaC
- 複数人チームで責任分界したい場合

**弱点**:
- モジュール境界の設計が難しい（「このIAMロールはどのモジュールに入れる？」論争）
- 同じAWSサービスの設定が複数モジュールに散らばる

#### 流派3: 階層的ハイブリッド（primitives + services）

```
modules/
├── primitives/              ← 低レベル: AWSサービス単位
│   ├── dynamodb_table/
│   ├── lambda_function/
│   └── api_route/
└── services/                ← 高レベル: 機能単位で primitives を組み合わせる
    ├── user_management/
    └── submission_pipeline/
```

**特徴**:
- Gruntwork の推奨パターン
- 再利用性（primitives）+ ドメイン性（services）の両取り
- 業界で "Service Module" と "Infrastructure Module" と呼ばれる

**弱点**:
- 設計コストが高い。小さなプロジェクトには過剰

### AWS/Terraform界隈のデファクトは？

明確なデファクトはなく「場合による」が正直な答え。傾向:

| プロジェクト規模 | よく見るパターン |
|---|---|
| 個人開発 / 学習 / スモール | 流派1（AWSサービス単位）が多数派 |
| 中規模スタートアップ | 流派1+2のハイブリッド（読みやすさ重視） |
| 大規模エンタープライズ | 流派3 に収束していく傾向 |

HashiCorp 公式ドキュメントも「Standard Module Structure」は定めているが、**何でモジュールを切るかの指針は示していない**。設計判断はプロジェクト次第。

### このプロジェクトでの評価

現在の「AWSサービス単位」分割は学習目的なら最適解に近い:

1. Phase ごとに新規AWSサービスを1つずつ学ぶ目的と一致
2. 「Cognito を学ぶ = `modules/cognito/` を読む」がシンプル
3. 流派2・3 への変更は、機能が増えてからのリファクタで十分間に合う

### 後々問題になりそうな点（先読み）

#### IAMロールをどこに書く？

Lambda が DynamoDB を読み書きするとき、IAMロールが必要。このロール定義は:

- `modules/lambda/` に書く？（アクセス先情報をモジュール外から注入する必要）
- `modules/dynamodb/` に書く？（使う側のLambdaを知る必要）
- 別モジュール `modules/iam/` を作る？

正解はないが、流派1で厳密にやると**循環依存っぽい問題**が発生しやすい。

#### Lambda関数が複数になったとき

`sync_submissions`, `get_submissions`, `get_problems` ... と増えると、`modules/lambda/` をさらに細分化するか、流派2風に機能単位で切り直すかの判断が迫られる。

### 今後の方針

このままの構造で進めつつ、**Lambda が複数関数を持つ Task 3 あたりで設計を見直すタイミングを取る**のがおすすめ。先回りして流派3にするのは過剰設計。

## Q&A

**Q: 今のmodulesってまさにAWSの機能名で切ってるわけだけど、これは適切なディレクトリ分け、名前づけの方法なの？AWS界隈ではそうするの？**

「AWS機能名で切る」は唯一の正解ではなく、複数ある流派の1つ。AWS/Terraform界隈に明確なデファクトはなく、プロジェクト規模と目的に応じて選ぶ。

- 小規模・学習プロジェクト → 流派1（AWSサービス単位）が多数派
- 中規模 → 流派1+2ハイブリッド
- 大規模エンタープライズ → 流派3（primitives + services）に収束

HashiCorp 公式も「何でモジュールを切るか」の指針は示しておらず、設計はプロジェクト次第。

このプロジェクトの現状（流派1）は学習目的に最適。機能が増えた段階（Lambda が複数関数を持つTask 3頃）で見直すのが現実的。

## 関連

- [01-dynamodb-keys.md](01-dynamodb-keys.md) - DynamoDBのキー設計
- [02-terraform-code-walkthrough.md](02-terraform-code-walkthrough.md) - Terraformコード解説
- [reference/terraform-basics.md](reference/terraform-basics.md) - Terraform基礎リファレンス

---

_Saved at 2026-04-18 via /learning-flow:topic_
