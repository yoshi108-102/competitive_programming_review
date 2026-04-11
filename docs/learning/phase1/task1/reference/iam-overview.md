# AWS IAM（Identity and Access Management）概要

## IAMとは

**「誰が（認証）、何に対して（リソース）、何をできるか（権限）」を管理するサービス。**

AWSの全サービスへのアクセスはIAMを通じて制御される。AWSアカウントを作った時点でIAMが有効になっている。

---

## 1. IAMの主要コンポーネント

```
IAM の構成要素:

  ┌─ ユーザー (User)     ── 人やアプリに紐づくアカウント
  │
  ├─ グループ (Group)    ── ユーザーをまとめて権限を一括付与
  │
  ├─ ロール (Role)       ── 一時的に「被れる帽子」（誰でも使える権限セット）
  │
  └─ ポリシー (Policy)   ── 「何を許可/拒否するか」のJSON定義
```

### ユーザー (IAM User)

```
人やアプリケーションに紐づく永続的なアカウント。

例:
  - 開発者 tanaka → IAMユーザー "tanaka" → アクセスキー発行
  - CI/CDシステム → IAMユーザー "ci-bot" → アクセスキー発行

問題点:
  - アクセスキーが永続的 → 漏洩リスク
  - 2026年現在、人間のアクセスにはIAM Identity Centerが推奨
```

### グループ (IAM Group)

```
ユーザーをまとめるコンテナ。グループにポリシーを付ければ、所属ユーザー全員に権限が付く。

例:
  グループ "developers" → DynamoDB読み書き権限のポリシーを付与
    ├── ユーザー tanaka → DynamoDB読み書きOK
    ├── ユーザー suzuki → DynamoDB読み書きOK
    └── ユーザー sato   → DynamoDB読み書きOK
```

### ロール (IAM Role)

```
「一時的に被れる帽子」。特定のユーザーに紐づかず、必要なときに誰でも（許可された相手が）引き受ける（assume）できる。

例:
  ロール "lambda-sync-role"
    → DynamoDB読み書き権限
    → Lambda関数がこのロールを引き受けて実行
    → 一時的な認証情報が自動発行される（数時間で期限切れ）

今回のプロジェクト:
  - Lambda: sync_submissions → "lambda-sync-role" を引き受ける → DynamoDB読み書きOK
  - Lambda: get_submissions  → "lambda-get-role" を引き受ける  → DynamoDB読み取りのみ
```

ロールの重要な特徴:
- **永続的な認証情報を持たない**（アクセスキーがない）
- **一時的な認証情報が自動で発行・ローテーションされる**
- **信頼ポリシー（Trust Policy）で「誰がこのロールを使えるか」を制御**

### ポリシー (IAM Policy)

**「何を許可/拒否するか」をJSON形式で定義したもの。** IAMの中核。

---

## 2. IAMポリシーの構造

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:Query"
      ],
      "Resource": "arn:aws:dynamodb:ap-northeast-1:123456789:table/atcoder-review-users-prod"
    }
  ]
}
```

### 各要素の意味

| 要素 | 意味 | 例 |
|---|---|---|
| **Effect** | 許可 or 拒否 | `"Allow"` or `"Deny"` |
| **Action** | 何の操作か | `"dynamodb:GetItem"`, `"s3:PutObject"` |
| **Resource** | どのリソースに対して | テーブルのARN、S3バケットのARN等 |
| **Condition** | 条件（省略可） | IPアドレス制限、MFA必須等 |

### 読み方の例

```json
{
  "Effect": "Allow",                           ← 許可する
  "Action": ["dynamodb:GetItem", "dynamodb:Query"],  ← GetItemとQueryの操作を
  "Resource": "arn:aws:dynamodb:...:table/users"      ← usersテーブルに対して
}
```

→ 「usersテーブルへのGetItemとQueryを許可する」

### Deny は Allow より強い

```json
// ポリシー1: 全DynamoDB操作を許可
{ "Effect": "Allow", "Action": "dynamodb:*", "Resource": "*" }

// ポリシー2: DeleteTable を拒否
{ "Effect": "Deny", "Action": "dynamodb:DeleteTable", "Resource": "*" }

// → 両方が付いている場合、DeleteTable は拒否される（Deny が勝つ）
```

---

## 3. ポリシーの種類

### 管理ポリシー（Managed Policy）

```
AWS管理ポリシー: AWSが用意した定番ポリシー
  例: "AmazonDynamoDBReadOnlyAccess" → DynamoDB全テーブルの読み取り権限

カスタマー管理ポリシー: 自分で作るポリシー
  例: "atcoder-review-sync-dynamodb" → 特定テーブルの読み書き権限
```

再利用可能。複数のユーザーやロールに付けられる。

### インラインポリシー（Inline Policy）

```
特定のユーザー/ロール/グループに直接埋め込むポリシー。
そのエンティティが削除されると一緒に消える。

今回のTerraformコードではこちらを使用:
  aws_iam_role_policy → ロールに直接ポリシーを埋め込む
```

### 使い分け

| | 管理ポリシー | インラインポリシー |
|---|---|---|
| 再利用性 | 複数のロール/ユーザーに付けられる | 1つのエンティティ専用 |
| 管理 | 独立して存在 | エンティティと一体 |
| 用途 | 共通の権限セット | そのロール固有の権限 |

---

## 4. ARN（Amazon Resource Name）

ポリシーの `Resource` で使う、AWSリソースの一意な識別子。

```
arn:aws:dynamodb:ap-northeast-1:123456789012:table/atcoder-review-users-prod
│   │   │        │              │             │
│   │   │        │              │             └── リソース名
│   │   │        │              └── AWSアカウントID
│   │   │        └── リージョン
│   │   └── サービス名
│   └── パーティション（通常 aws）
└── ARNプレフィックス
```

ワイルドカードも使える:
```
"arn:aws:dynamodb:ap-northeast-1:123456789012:table/*"          ← 全テーブル
"arn:aws:dynamodb:ap-northeast-1:123456789012:table/users/index/*"  ← usersテーブルの全GSI
```

---

## 5. 信頼ポリシー（Trust Policy）

ロールには「誰がこのロールを引き受けられるか」を定義する信頼ポリシーがある。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

→ 「Lambdaサービスがこのロールを引き受けることを許可する」

Terraformでは `assume_role_policy` として書く:

```hcl
resource "aws_iam_role" "lambda_sync" {
  name = "lambda-sync-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}
```

---

## 6. 最小権限の原則（Principle of Least Privilege）

**必要最小限の権限だけを付与する。**

```
× 悪い例: Lambda に全権限
  "Action": "dynamodb:*"
  "Resource": "*"
  → 全テーブルに対して何でもできる（DeleteTableも可能）

○ 良い例: 必要な操作だけ、必要なテーブルだけ
  "Action": ["dynamodb:GetItem", "dynamodb:Query"]
  "Resource": "arn:aws:dynamodb:...:table/users"
  → usersテーブルの読み取りのみ
```

今回のプロジェクトでロールを機能単位で分けているのはこの原則に基づく:
- `lambda-sync-role`: DynamoDB読み書き（sync_submissionsに必要）
- `lambda-get-role`: DynamoDB読み取りのみ（get_submissionsに必要）
- `lambda-save-user-role`: usersテーブルのみ読み書き

---

## 7. 今回のプロジェクトでのIAM構成

```
Lambda: save_user
  └── IAMロール: lambda-save-user-role
       ├── 信頼ポリシー: Lambdaサービスが引き受け可能
       ├── 権限ポリシー: usersテーブルのGetItem/PutItem/UpdateItem
       └── 自動付与: AWSLambdaBasicExecutionRole（CloudWatch Logs書き込み）

Lambda: sync_submissions
  └── IAMロール: lambda-sync-role
       ├── 信頼ポリシー: Lambdaサービスが引き受け可能
       ├── 権限ポリシー: users + submissionsテーブルの読み書き
       └── 自動付与: AWSLambdaBasicExecutionRole

Lambda: get_submissions
  └── IAMロール: lambda-get-role
       ├── 信頼ポリシー: Lambdaサービスが引き受け可能
       ├── 権限ポリシー: users + submissions + problemsテーブルの読み取り
       └── 自動付与: AWSLambdaBasicExecutionRole
```

---

## 参考資料

- [IAM roles - AWS公式ドキュメント](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html)
- [Policies and permissions in IAM - AWS公式ドキュメント](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html)
- [IAM Fundamentals — Users, Groups, Roles - OpenExamPrep](https://open-exam-prep.com/exams/aws-solutions-architect/design-secure-architectures/iam-fundamentals)
- [AWS IAM Basics: Users, Roles, and Permissions - Business Compass](https://knowledge.businesscompassllc.com/aws-iam-basics-users-roles-and-permissions/)
