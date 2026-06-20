# 05. Lambda 実行ロールとデプロイパッケージ

> 出典:
> - [Terraform aws_lambda_function](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function)
> - [AWS Lambda - Permissions for AWS Lambda functions](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html)
> - [aws_lambda_permission - Terraform](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission)
> - [AWS Lambda - Working with .zip file archives for Python](https://docs.aws.amazon.com/lambda/latest/dg/python-package.html)
>
> 閲覧日 2026-05-09

## 概要

Lambda 関数を AWS にデプロイして動かすために必要な要素は大きく 2 つの軸に分かれる:

- **権限 (IAM)**: 「誰が呼べるか」「呼ばれた関数は何にアクセスできるか」を定義
- **コード (デプロイパッケージ)**: 関数本体 + 依存ライブラリを 1 つの ZIP として配備

このノートは両方をカバーする。Terraform の `aws_lambda_function` を 1 つ書くだけでも、裏側にこの 2 軸の知識が必要になる。

## 1. IAM 実行ロール (Trust + Permission)

Lambda 関数には **「誰の権限で動くか」を定義する IAM ロール (Execution Role)** が必須。
このロールは 2 つの policy を持つ:

### A. Trust Policy (`assume_role_policy`) — 「誰がこのロールを引き受けられるか」

```hcl
resource "aws_iam_role" "lambda_exec" {
  name = "..."
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}
```

`Principal.Service = "lambda.amazonaws.com"` の宣言で「**Lambda サービスがこのロールを名乗れる**」。これがないと Lambda 関数を作っても `AccessDenied` で起動しない。

### B. Permission Policy — 「このロールが何を出来るか」

ロールに直接 inline policy を貼るか、独立 policy を attach する。最小権限例:

```hcl
resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "dynamodb-access"
  role = aws_iam_role.lambda_exec.id
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:Query"]
      Resource = [var.users_table_arn, var.submissions_table_arn]
    }]
  })
}
```

最小権限のコツ:
- **Action は必要なものだけ**（read 系なら `GetItem`, `Query` のみ。`*` は避ける）
- **Resource はテーブル ARN まで絞る**（`"*"` を避ける）
- GSI を使うなら `<table_arn>/index/*` も必要

### C. CloudWatch Logs 用ポリシー (必須)

Lambda がログを CloudWatch に書くには `logs:CreateLogStream` / `logs:PutLogEvents` が必要。AWS マネージドポリシーを attach するのが定石:

```hcl
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
```

これがないと Lambda 自体は動くが**ログが出ない** → デバッグ不能で詰む。必須。

## 2. CloudWatch Log Group の事前作成

Lambda は初回実行時に `/aws/lambda/<関数名>` という Log Group を**自動作成**する。
ただし保持期間がデフォルト「無期限」で課金が無限に蓄積するため、**Terraform で事前に作って `retention_in_days` を指定**するのがベストプラクティス:

```hcl
resource "aws_cloudwatch_log_group" "lambda_save_user" {
  name              = "/aws/lambda/${aws_lambda_function.save_user.function_name}"
  retention_in_days = 14
}
```

## 3. `aws_lambda_function` 本体

```hcl
resource "aws_lambda_function" "save_user" {
  function_name    = "${var.project_name}-save-user-${var.environment}"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.12"
  handler          = "lambdas.save_user.handler.lambda_handler"
  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      USERS_TABLE = var.users_table_name
    }
  }
}
```

注目ポイント:

- **`handler`** は `<モジュールパス>.<関数名>` 形式。Python なら **dotted path**。`lambdas.save_user.handler.lambda_handler` = ZIP ルートからの `lambdas/save_user/handler.py` 内の `lambda_handler` 関数を指す
- **`source_code_hash`**: `filename` の中身が変わったら Terraform が再デプロイを自動でトリガーする。これがないと **同名 ZIP を差し替えても Lambda が更新されない**事故が起きる（次回 apply で「変更なし」とスキップされる）
- **`environment.variables`** で実行時の環境変数を注入。ハンドラ側で `os.environ["USERS_TABLE"]` で読む

## 4. `aws_lambda_permission` — 呼び出し元の招待状

Lambda は **resource-based policy** で「誰が私を invoke してよいか」を制御する。API Gateway が Lambda を呼ぶには明示的な許可が必要:

```hcl
resource "aws_lambda_permission" "api_gw_save_user" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.save_user.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${var.api_gateway_execution_arn}/*/*"
}
```

`source_arn` のフォーマット: `<execution_arn>/<stage>/<method>/<path>`。`*/*` で全 stage / 全メソッドからの invoke を許可（最小化したいならパスまで絞る）。

これがないと API Gateway が 5xx で「Lambda invoke 失敗」と返してくる。**地味だが必須**。
EventBridge / S3 / SNS など他のサービスから呼ぶ場合もそれぞれの `principal` で同様の permission が必要。

## 5. デプロイパッケージ (ZIP) の構造

ハンドラ識別子 `lambdas.save_user.handler.lambda_handler` (`.` 区切り) は **ZIP ルートからのパス**に対応する。

このプロジェクトの ZIP 構造（複数ハンドラ + 共有コード + 依存ライブラリを 1 ZIP に詰める運用）:

```
lambda.zip
├── shared/                         ← 共有コード
│   ├── __init__.py
│   ├── response.py
│   ├── db.py
│   └── atcoder_client.py
├── lambdas/
│   ├── __init__.py
│   ├── save_user/
│   │   ├── __init__.py
│   │   └── handler.py              ← lambdas.save_user.handler.lambda_handler
│   ├── sync_submissions/
│   │   └── handler.py
│   └── get_submissions/
│       └── handler.py
├── boto3/                          ← 依存ライブラリ
├── botocore/
├── requests/
├── certifi/
└── ...
```

複数ハンドラごとに別 ZIP を作る選択肢もあるが、共有コード (`shared/*`) を重複させる必要がある。**1 ZIP 共有**の方が運用効率が良い。Terraform では `for_each` で各関数が同じ ZIP を参照する。

## 6. 依存ライブラリの含め方

`pip install --target` で**指定ディレクトリに平坦に**インストールする:

```bash
# uv 使用時の流れ (このプロジェクト)
uv export --no-hashes --no-dev --format requirements-txt > build/requirements.txt
uv pip install --target ./build -r build/requirements.txt
# → ./build/{boto3,botocore,requests,...}/  が生まれる
```

その後アプリコードを `cp -r shared lambdas ./build/` でコピーして、`build/` を ZIP 化。
詳細は `Makefile` の `build` ターゲット参照（[practice/terraform-apply-walkthrough.md](../practice/terraform-apply-walkthrough.md) も）。

## 7. Boto3 同梱の判断

AWS Lambda Python ランタイムには **boto3 が事前インストール済み**。だがバージョンが Lambda runtime 側都合で変わるため、**自前で含めて固定する**のが定石。

| 方針 | メリット | デメリット |
|---|---|---|
| 自前で含める | バージョン固定、新機能を即使える、ローカルテスト (moto) との整合 | ZIP サイズが ~10MB 増える |
| 同梱版を使う | ZIP 軽量 | バージョン変動の不確実性 |

このプロジェクトは **自前で含める** を採用。

## 8. プラットフォーム差の注意

`requests` のような pure Python なら問題ないが、**C 拡張を含むパッケージ**（`numpy` 等）は Lambda の実行環境 (Amazon Linux 2023, x86_64) と一致するビルドが必要:

```bash
pip install --platform manylinux2014_x86_64 --only-binary=:all: --target ./build numpy
```

このプロジェクトの依存 (`boto3`, `requests`) はいずれも pure Python なので、ローカル (macOS) で普通にビルドして OK。

## 重要ポイント

- IAM 実行ロールは **Trust (誰が引き受けるか) + Permission (何が出来るか)** の 2 段。`Principal.Service = "lambda.amazonaws.com"` で Lambda サービスを信頼
- 権限は **最小限**: Action / Resource を絞る、`"*"` を避ける
- **CloudWatch Logs 用ポリシー (`AWSLambdaBasicExecutionRole`)** を必ず attach。さもなくばログが出ない
- Log Group を **Terraform で事前作成**して `retention_in_days` を指定（無期限は課金事故）
- `source_code_hash = filebase64sha256(...)` で ZIP 差し替え時の再デプロイを担保
- **resource-based policy (`aws_lambda_permission`)** で API Gateway 等からの invoke を明示許可
- ハンドラ識別子の `.` 区切り = ZIP 内のパス区切り
- 依存は `pip install --target` で平坦インストール → 1 ZIP に全ハンドラ + 全依存を同梱
- C 拡張なしの依存だけなら macOS でビルドして OK

## 関連

- 実装パターン: [practice/lambda-handler-skeleton.md](../practice/lambda-handler-skeleton.md)
- デプロイ手順: [practice/terraform-apply-walkthrough.md](../practice/terraform-apply-walkthrough.md)
- 関連トピック: [03-boto3-resource-vs-client.md](03-boto3-resource-vs-client.md), [06-api-gateway-rest-api-structure.md](06-api-gateway-rest-api-structure.md)
