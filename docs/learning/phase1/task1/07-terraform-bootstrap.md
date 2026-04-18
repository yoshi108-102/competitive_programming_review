# Terraform Bootstrap の鶏と卵問題

## 概要

`terraform init` を実行したとき「S3バケットが存在しない」エラーで失敗した事例と解決策。Terraform の state を S3 に保存する運用には **Bootstrap パターン**が必要になる。最初に一度だけ、ローカル state で S3 バケット本体を作る段取り。

## 解説

### 発生した問題

`terraform init` を実行すると以下のエラー:

```
Error: Failed to get existing workspaces: S3 bucket "atcoder-review-tfstate" does not exist.
NoSuchBucket
```

### 根本原因: 鶏と卵問題

`terraform/main.tf`:
```hcl
backend "s3" {
  bucket         = "atcoder-review-tfstate"   # ← 状態ファイル保存先
  dynamodb_table = "atcoder-review-tflock"    # ← ロック管理
}
```

- Terraform は **起動時にまずバックエンドへ繋ぎに行く** → バケットが無いとエラー
- 一方、**S3バケット自体も Terraform で作りたい**（IaCの思想）
- 結果: バケットを作るために Terraform が必要、Terraform を使うためにバケットが必要 → **鶏と卵**

### 解決: Bootstrap パターン

別ディレクトリ `terraform/bootstrap/` に、**`backend "s3"` を書かない**Terraform 設定を用意する。

```
terraform/
├── main.tf              ← backend "s3" あり（本体）
├── modules.tf
├── modules/...
└── bootstrap/
    └── main.tf          ← backend なし = ローカル state
```

Bootstrap は S3 バケットと DynamoDB ロックテーブルのみを定義:

```hcl
resource "aws_s3_bucket" "tfstate" {
  bucket = "atcoder-review-tfstate"
  lifecycle { prevent_destroy = true }  # 誤削除防止
}
# バージョニング、暗号化、パブリックアクセスブロックも定義

resource "aws_dynamodb_table" "tflock" {
  name         = "atcoder-review-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"   # ← ロック用の固定キー名
  attribute {
    name = "LockID"
    type = "S"
  }
}
```

**Bootstrap は `backend "s3"` を書かない → stateは `bootstrap/terraform.tfstate` にローカル保存** → バケットがなくても動く。

### 実行手順

```bash
# 1. Bootstrap: S3バケット + ロックテーブルを作る（一度だけ）
cd terraform/bootstrap
terraform init        # ローカルstate初期化
terraform apply       # AWS に S3 + DynamoDB を作成

# 2. ルート: これで backend "s3" が使える
cd ..
terraform init        # S3 backend を初期化、OK
terraform apply       # 実際のアプリリソースを作成
```

### なぜ `prevent_destroy = true` か

S3バケットを誤って `terraform destroy` で消すと、**全ての terraform.tfstate が消滅**。つまりプロジェクト全体のIaC履歴が飛ぶ。Bootstrap のバケットには `lifecycle.prevent_destroy = true` を付けて、destroyコマンドが走ってもこのリソースだけは保護する。

削除が必要なときは Terraform 外で手動削除するか、一時的に `prevent_destroy` を `false` にする必要がある。

### なぜ `terraform state` を S3 に置く？

ローカル state のままでもTerraform自体は動く。しかし:

- **共同作業ができない**: 他の開発者と state を共有できない
- **CI/CD が動かない**: GitHub Actions 等が state を読めない
- **ローカルマシンが死ぬと state 喪失** → AWS上のリソースが「管理外」になる

S3 バックエンド + DynamoDB ロックにすると:

- チームで同じ state を参照できる
- CI/CD から state にアクセス可能
- DynamoDB ロックで **同時 apply を防止**（レースコンディション回避）
- S3 バージョニングで state の履歴が残る（ロールバック可）

### 付随して出た警告: `dynamodb_table` 非推奨

```
Warning: dynamodb_table parameter is deprecated. Use use_lockfile instead.
```

Terraform 1.10 以降、ロック機構が**ネイティブ化**され、DynamoDBテーブルが不要に:

```hcl
# 旧（今の設定）
backend "s3" {
  bucket         = "atcoder-review-tfstate"
  dynamodb_table = "atcoder-review-tflock"
  encrypt        = true
}

# 新（Terraform 1.10+）
backend "s3" {
  bucket       = "atcoder-review-tfstate"
  use_lockfile = true   # ← S3上にロックファイルを置く仕組み
  encrypt      = true
}
```

警告だけで動作は続くので、今すぐ直す必要はない。移行するなら:

1. `use_lockfile = true` に変更
2. `terraform init -migrate-state` で state 移行
3. Bootstrap から `aws_dynamodb_table.tflock` を削除して destroy

### 学びのポイント

| 概念 | 要点 |
|---|---|
| Bootstrap パターン | バックエンドを Terraform で作るが、Bootstrap 自身はローカル state |
| 鶏と卵問題 | IaCで「IaC自身の基盤」を作るときの典型的ジレンマ |
| `prevent_destroy` | 削除で連鎖的被害が出るリソースに付ける保険 |
| ローカル state のリスク | 1人開発でも喪失リスクあり、早めに S3 バックエンド化 |
| deprecation 警告 | 動作には影響しないが、将来バージョンで動かなくなる予兆 |

## Q&A

**Q: `terraform init` でエラーが出た。何が起きた？**

`backend "s3"` で指定した S3 バケット（`atcoder-review-tfstate`）が AWS 上に存在しないため、Terraform が state を読み書きできずに失敗した。解決するには先に Bootstrap を apply してバケットを作る必要がある。

**Q: Bootstrap 自身の state はどこに保存される？ S3 がまだないのに？**

Bootstrap の `main.tf` には `backend "s3"` を書いていない。そのため Terraform の既定動作で**ローカルのディレクトリ（`bootstrap/terraform.tfstate`）に state が保存**される。鶏と卵を回避する仕組み。

**Q: 警告の `use_lockfile` には今すぐ移行すべき？**

必須ではない。動作は続く。ただし将来の Terraform バージョンで廃止される可能性があるので、プロジェクトが落ち着いたタイミングで移行するのが良い。移行するとDynamoDBテーブルも不要になるため管理対象が減るメリット有。

## 関連

- [02-terraform-code-walkthrough.md](02-terraform-code-walkthrough.md) - `main.tf` の `backend "s3"` ブロック解説
- [reference/terraform-basics.md](reference/terraform-basics.md) - Terraform backend の基礎

---

_Saved at 2026-04-18 via /learning-flow:topic_
