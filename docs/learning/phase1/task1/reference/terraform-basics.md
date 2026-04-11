# Terraform 基礎

## 解説

### Terraform とは

AWSのリソース（DynamoDBテーブル、Lambda関数、API Gateway等）をコードで定義し、コマンド一発で作成・変更・削除するツール。IaC（Infrastructure as Code）。

手動（AWSコンソールでポチポチ）との違い:
- コードなのでGit管理できる（変更履歴、レビュー）
- 同じコードから同じ環境を何度でも作れる（再現性）
- `terraform plan` で事前に差分を確認できる

### ファイル構造

```
terraform/
├── main.tf          ← プロバイダ設定（AWS接続情報）
├── variables.tf     ← 変数の定義
├── outputs.tf       ← 外部に公開する値
├── modules.tf       ← モジュールの呼び出し・接続
├── bootstrap/       ← Terraform状態管理用（初回のみ）
└── modules/
    ├── cognito/
    ├── api_gateway/
    └── dynamodb/    ← Task 1 で作成
```

### 各ファイルの役割

| ファイル | 役割 |
|---|---|
| `main.tf` | リソースの定義（「何を作るか」） |
| `variables.tf` | 外から渡すパラメータ（「変えられる部分」） |
| `outputs.tf` | 他に渡す値（「作った結果の情報」） |

### モジュール分離の理由

全部1ファイルに書くと影響範囲が不明確になる。モジュールに分けることで:
- DynamoDBの変更はdynamodbモジュール内で完結
- outputs でテーブル名やARNを公開し、他モジュールから参照できる

### HCLの基本構文

```hcl
resource "aws_dynamodb_table" "users" { ... }
# → resource "リソースの種類" "Terraform内の名前" { 設定項目 }

variable "project_name" { type = string; default = "atcoder-review" }
# → 外部から渡せるパラメータ。var.project_name で参照

output "users_table_name" { value = aws_dynamodb_table.users.name }
# → モジュールの外に値を公開

module "cognito" { source = "./modules/cognito"; project_name = var.project_name }
# → モジュールの呼び出し。module.cognito.user_pool_id で出力を参照
```

### Terraformのコマンド

| コマンド | やること |
|---|---|
| `terraform init` | 初期化（プロバイダのダウンロード等） |
| `terraform plan` | 差分のプレビュー（変更しない） |
| `terraform apply` | 実際にAWSリソースを作成・変更 |
| `terraform validate` | コードの構文チェック |

---

## 質疑応答

### Q1: variableブロックのプロパティは自由に設定可能か？

variable ブロックのプロパティ（description, type, default 等）はTerraformが定めた固定のものだけ。自由に追加はできない。

使えるプロパティ: `description`, `type`, `default`, `nullable`, `sensitive`, `validation`。
実際によく使うのは `description`, `type`, `default` の3つ。

一方、変数の「名前」は自由。型のバリエーションは string, number, bool, list, map, object。

resource ブロックのプロパティはリソースの種類ごとにAWSの仕様で決まる（aws_dynamodb_table なら name, billing_mode, hash_key 等）。

### Q2: backend "s3" とは何か？

**Terraformの「状態ファイル（terraform.tfstate）」をS3に保存する設定。**

状態ファイル = 「今AWSに何が存在しているか」の記録。Terraformはコード（.tf）と状態ファイルを比較して差分を検知する。状態ファイルがないと毎回全部作り直そうとする。

```hcl
backend "s3" {
  bucket         = "atcoder-review-tfstate"     # 保存先S3バケット
  key            = "terraform.tfstate"           # ファイルパス
  region         = "ap-northeast-1"              # リージョン
  dynamodb_table = "atcoder-review-tflock"       # ロック用テーブル
  encrypt        = true                          # 暗号化
}
```

**dynamodb_table（ロック）**: 複数人が同時に `terraform apply` しても状態ファイルが壊れないようにするための排他制御。個人開発では恩恵薄いが、チーム開発では必須。

**bootstrapとの関係**: このS3バケットとロック用DynamoDBテーブルは `terraform/bootstrap/main.tf` で事前に作成したもの。「Terraformで管理するインフラの状態を保存するために、Terraformの外で先に作るインフラ」= bootstrap。鶏と卵の問題の解決策。
