# Terraform 既存コード解説

既存の Terraform コードをブロックごとに解説する。
基礎知識は [Terraform基礎リファレンス](reference/terraform-basics.md) を参照。

---

## terraform/main.tf

### terraform ブロック — Terraform自体の設定

```hcl
terraform {
  required_version = ">= 1.5.0"
```
Terraform 1.5.0 以上でないと動かない。チームでバージョン違いによる問題を防ぐ。

```hcl
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
```
AWS用プロバイダ（AWSのAPIを呼ぶプラグイン）を使う。`~> 5.0` は 5.x 系を使い、6.0以上は不可。→ [リファレンス: プロバイダとは](reference/terraform-basics.md)

```hcl
  backend "s3" {
    bucket         = "atcoder-review-tfstate"
    key            = "terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "atcoder-review-tflock"
    encrypt        = true
  }
}
```
Terraformの状態ファイルをS3に保存する設定。`dynamodb_table` は同時実行を防ぐロック。→ [リファレンス: backend "s3" の詳細](reference/terraform-basics.md)

### provider ブロック — AWS接続設定

```hcl
provider "aws" {
  region = var.aws_region
```
どのAWSリージョンにリソースを作るか。`var.aws_region` = `"ap-northeast-1"`（東京）。→ [リファレンス: variableの参照](reference/terraform-basics.md)

```hcl
  default_tags {
    tags = {
      Project     = "atcoder-review"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
```
このproviderで作る全リソースに自動でタグを付与する。AWSコンソールやコスト管理で「何のリソースか」を識別するためのラベル。→ [リファレンス: タグとは](reference/terraform-basics.md)

---

## terraform/variables.tf

```hcl
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}
```
東京リージョン。`main.tf` で `var.aws_region` として参照。→ [リファレンス: variableブロック](reference/terraform-basics.md)

```hcl
variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}
```
環境名。リソース名やタグに使われる。dev/stagingを作る場合はここを変える。

```hcl
variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "atcoder-review"
}
```
リソース名のプレフィックス。`"${var.project_name}-users-${var.environment}"` → `"atcoder-review-users-prod"` になる。

---

## terraform/modules.tf

```hcl
module "cognito" {
  source = "./modules/cognito"

  project_name = var.project_name
  environment  = var.environment
}
```
cognitoモジュールを呼び出し、変数を渡す。→ [リファレンス: モジュール間の連携](reference/terraform-basics.md)

```hcl
module "api_gateway" {
  source = "./modules/api_gateway"

  project_name          = var.project_name
  environment           = var.environment
  cognito_user_pool_arn = module.cognito.user_pool_arn
}
```
api_gatewayモジュールを呼び出し。`module.cognito.user_pool_arn` でcognitoモジュールの出力を参照し、API GatewayのCognito認証に使う。

---

## terraform/outputs.tf

```hcl
output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = module.cognito.user_pool_id
}

output "cognito_user_pool_client_id" {
  description = "Cognito User Pool Client ID"
  value       = module.cognito.user_pool_client_id
}

output "api_gateway_url" {
  description = "API Gateway invoke URL"
  value       = module.api_gateway.api_url
}
```
`terraform apply` 後にターミナルに表示される値。フロントの `.env.local` に設定するCognito IDやAPI URLをここから取得する。`terraform output api_gateway_url` でコマンドからも取得可能。

---

## 質疑応答

### Q1: providerの認証情報はどこにあるのか？どうするのが良いのか？

`provider "aws"` にアクセスキーは書かれていない。Terraformは環境変数 → `~/.aws/credentials` → IAMロール の順で自動検索する。コードに認証情報をハードコードしないのがベストプラクティス。

2026年現在のAWS認証推奨度:

| 方法 | 推奨度 | 認証情報の寿命 |
|---|---|---|
| IAM Identity Center (SSO) | 最推奨 | 一時的（自動期限切れ） |
| IAM ロール | 推奨（EC2/Lambda等） | 一時的（自動ローテーション） |
| IAM ユーザー + アクセスキー | 非推奨 | 永続的（漏洩リスク） |

シナリオ別:
- **ローカル開発**: IAM Identity Center（ブラウザでSSOログイン → 一時認証情報取得）
- **EC2/Lambda**: IAMロールをアタッチ（コードにキーを書かない）
- **CI/CD**: OIDC連携（GitHub Actionsが一時トークンを発行）

「IAMロールが非推奨」ではなく、「IAMユーザーの長期アクセスキーが非推奨」。IAMロール（一時認証情報）は今も推奨。

→ 詳細は [リファレンス: AWS認証のベストプラクティス](reference/aws-authentication.md) 参照
→ IAMの基礎（ユーザー/ロール/ポリシーの違い等）は [リファレンス: IAM概要](reference/iam-overview.md) 参照

### Q2: IAM Identity Center vs IAMロールの違いは？

Identity Center = 「誰がAWSにアクセスできるか」の管理（ログインの仕組み）。IAMロール = 「何ができるか」の定義（権限セット）。この2つは競合せず組み合わせて使う。

→ [リファレンス: IAM Identity Center vs IAMロール](reference/aws-authentication.md)

### Q3: IAMユーザーのキーを短期にすればIdentity Centerは不要では？

IAMユーザーのアクセスキーは仕組み上、永続でしか発行できない（AWS初期設計、後方互換性のため変更不可）。STS AssumeRoleで一時キーは作れるが、それを呼ぶために永続キーが必要（鶏と卵）。Identity Centerは「永続キーを一切使わずにログインする方法」。

### Q4: Identity Centerの役割が結局わからない

**AWSにアクセスするための認証サーバー。** 「永続キーを発行せずに、ブラウザログインで一時キーを渡す仕組み」。IAMユーザー方式は「鍵を渡す」、Identity Center方式は「毎回本人確認して一時的な鍵を作る」。

→ [リファレンス: Identity Centerの役割](reference/aws-authentication.md)

### Q5: ~/.aws/credentials が諸悪の根源か？

ファイル自体が悪いのではなく「永続キーしか発行できないIAMユーザーの設計」が根本原因。Identity Centerでも `~/.aws/sso/cache/` に一時トークンがキャッシュされるが、数時間で無効になるため漏洩リスクが限定的。

→ [リファレンス: なぜIAMユーザーキーの短期化ではダメなのか](reference/aws-authentication.md)

## 関連

- [03-module-design-patterns.md](03-module-design-patterns.md) - モジュール分割の流派（AWSサービス単位 vs 機能単位 vs 階層ハイブリッド）
- [06-dynamodb-module-implementation.md](06-dynamodb-module-implementation.md) - Task 1 DynamoDBモジュール実装時の設計判断
- [reference/terraform-basics.md](reference/terraform-basics.md) - Terraform 基礎リファレンス（HCL構文、variable/output/resource）
- [reference/aws-authentication.md](reference/aws-authentication.md) - AWS認証のベストプラクティス
- [reference/iam-overview.md](reference/iam-overview.md) - IAM概要（ユーザー/ロール/ポリシー/ARN）
