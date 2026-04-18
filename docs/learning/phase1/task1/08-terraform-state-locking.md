# Terraform の状態ロック機構

## 概要

`terraform apply` を同時に複数人/複数プロセスが実行すると **state drift（tfstate の不整合）**が発生しうる。Terraform はこれを防ぐために **state lock** という排他制御を持つ。S3 backend では歴史的に DynamoDB テーブルでロックを管理してきた（プロジェクト名の `tflock` の正体はこれ）。Terraform 1.10 以降は S3 単独でロックできる `use_lockfile` が追加され、DynamoDB 不要の新方式に移行できる。

## 解説

### なぜロックが必要か — state drift の悪夢

`terraform.tfstate` は「どのリソースを Terraform が管理しているか」の唯一の記録。同時 apply が走ると:

```
Aさん apply 開始 → tfstate読む ─┐
                                 │ ここで同時実行
Bさん apply 開始 → tfstate読む ─┤
                                 │
Aさん リソース変更 → tfstate書く│
Bさん リソース変更 → tfstate書く┘  ← 上書きでAさんの変更が tfstate から消える
```

結果:
- **tfstate と AWS 実在リソースが不一致**
- 次の `plan` で「管理対象外のリソースが見える」「存在しないリソースを消そうとする」挙動
- 手動での tfstate 修復作業（`terraform import` 等）が必要

これが**state drift**。防ぐには「同時に1人しか apply しない」ことを保証する必要がある。

### ロック機構の仕組み

Terraform は `apply` の最初に**排他ロックを取得**する:

```
apply 開始
  ↓
① ロックテーブル/ファイルにレコードを書く（条件付き: 既に存在するなら失敗）
  ↓ 成功 = ロック取得
② tfstate を読む
  ↓
③ AWSリソースを変更
  ↓
④ tfstate を書く
  ↓
⑤ ロックレコードを削除 = ロック解放
```

②〜④ の間に他の apply が走ろうとすると、①で PutItem が失敗 → `Error: Error acquiring the state lock` で落ちる。

### DynamoDB でロックを実現する仕組み

DynamoDB の **Conditional Write** がキー:

```python
# 疑似コード
try:
    dynamodb.put_item(
        TableName="atcoder-review-tflock",
        Item={"LockID": {"S": "atcoder-review-tfstate/terraform.tfstate"}, ...},
        ConditionExpression="attribute_not_exists(LockID)"   # ← 既にあると失敗
    )
    # ロック取得成功
except ConditionalCheckFailedException:
    # 既に他の誰かがロック中
    raise LockError
```

### 実際のロックレコード

`apply` 実行中に DynamoDB を覗くと以下のレコードが見える:

```bash
aws dynamodb scan \
  --table-name atcoder-review-tflock \
  --region ap-northeast-1
```

```json
{
  "Items": [{
    "LockID": { "S": "atcoder-review-tfstate/terraform.tfstate" },
    "Info": { "S": "{\"ID\":\"abc-123\",\"Operation\":\"OperationTypeApply\",\"Who\":\"yoshi@macbook\",\"Created\":\"2026-04-18T...\"}" },
    "Digest": { "S": "..." },
    "Path": { "S": "atcoder-review-tfstate/terraform.tfstate" }
  }]
}
```

| 属性 | 内容 |
|---|---|
| `LockID` (PK) | S3バケット名/state キー = 「どの state に対するロックか」 |
| `Info` | 誰が、いつ、どの操作でロックを取ったか（デバッグ用の JSON） |
| `Digest` | tfstate のハッシュ（整合性チェック用） |
| `Path` | state ファイルのパス |

`apply` が正常終了するとこのレコードは**自動削除される**。

### tflock テーブルの Terraform 定義

Bootstrap で以下のように作られている:

```hcl
resource "aws_dynamodb_table" "tflock" {
  name         = "atcoder-review-tflock"
  billing_mode = "PAY_PER_REQUEST"   # ロック取得時のみ課金、月数セント
  hash_key     = "LockID"            # ← Terraform が要求する固定キー名

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

- **`hash_key = "LockID"` は固定**（Terraform 側が決め打ち）
- `billing_mode = "PAY_PER_REQUEST"` で十分（書き込み頻度は極小）
- 他の設定（暗号化、レプリケーション）は必要なら追加

### なぜ DynamoDB が選ばれたか

ロック基盤の要件:

1. **Conditional Write** — 既にロックがある時だけ失敗する挙動が必要
2. **Strongly Consistent Read** — ロック取得状況が全員から瞬時に同じに見える必要
3. **高可用性** — ロック基盤が落ちるとプロジェクト全体の apply が止まる

S3 は歴史的に:
- 結果整合性が強く、Conditional Write が弱かった
- → 単独では競合状態を完全に防げなかった

DynamoDB はこれらをクリアしていたので、「S3 + DynamoDB」の組み合わせが業界標準になった。

### ロックが解放されないケース（stuck lock）

`apply` 中に強制終了 (`Ctrl+C`、PC クラッシュ、ネットワーク断など) すると、**ロック解放の処理がスキップされる**:

```bash
terraform apply
  → ⚡ PC がフリーズ
  → ロック削除のタイミングを逃す
  → DynamoDB に孤立レコードが残る

# 次の apply:
$ terraform apply
Error: Error acquiring the state lock
  ID: abc-123
  Path: atcoder-review-tfstate/terraform.tfstate
  Created: 2026-04-18T10:00:00
  Who: yoshi@macbook
```

### stuck lock の解除方法

#### 方法1: `terraform force-unlock`（推奨）

```bash
terraform force-unlock abc-123
```

⚠️ **注意**: 他の誰かが本当に apply 実行中でないか必ず確認してから。同時実行中に force-unlock すると state drift が起きる。

#### 方法2: DynamoDB から直接削除（最終手段）

```bash
aws dynamodb delete-item \
  --table-name atcoder-review-tflock \
  --region ap-northeast-1 \
  --key '{"LockID":{"S":"atcoder-review-tfstate/terraform.tfstate"}}'
```

これは「ロック機構を信じない」操作なので、force-unlock で解決できないとき以外は避ける。

### Terraform 1.10+ の `use_lockfile` 方式

Terraform 1.10 以降、**DynamoDB 不要で S3 だけでロックできる**新方式が追加:

```hcl
# 旧（このプロジェクトの現状）
backend "s3" {
  bucket         = "atcoder-review-tfstate"
  dynamodb_table = "atcoder-review-tflock"
  encrypt        = true
}

# 新
backend "s3" {
  bucket       = "atcoder-review-tfstate"
  use_lockfile = true
  encrypt      = true
}
```

#### 新方式の仕組み

S3 が**条件付き PUT**（`If-None-Match: "*"`）に対応したので、DynamoDB の Conditional Write と同等の排他制御が S3 単独で実現可能になった。

- ロックファイル名: `<state-key>.tflock` （例: `terraform.tfstate.tflock`）
- 同じ S3 バケットに置かれる
- apply 中のみ存在、終了で削除

#### 移行のメリット・デメリット

| 観点 | `dynamodb_table`（旧） | `use_lockfile`（新） |
|---|---|---|
| 管理対象リソース | S3 + DynamoDB | S3 のみ |
| コスト | DynamoDB 課金あり（微々たる） | S3 のみ（さらに微々たる） |
| デバッグ情報 | Info JSON で Who/When が豊富 | やや簡素 |
| 実績 | 長年の実運用事例あり | Terraform 1.10+ の新機能 |
| 警告 | deprecation warning が出る | 出ない（将来の標準） |

#### 移行手順（参考）

1. `terraform/main.tf` の backend ブロックを書き換え（`dynamodb_table` → `use_lockfile = true`）
2. `terraform init -migrate-state` で state の移行（実際は state 本体は S3 のまま、メタデータのみ更新）
3. Bootstrap から `aws_dynamodb_table.tflock` を削除
4. `terraform apply`（Bootstrap ディレクトリで）で DynamoDB テーブルを destroy

今すぐやる必要はない。プロジェクトが落ち着いたタイミングで。

### 学びのポイント

| 概念 | 要点 |
|---|---|
| state drift | 同時 apply による tfstate の不整合。復旧が大変 |
| 排他ロック | 「一度に1人しか apply しない」を機械的に保証する仕組み |
| Conditional Write | 「既にある場合は失敗」という原子的書き込み。ロック実装の核 |
| LockID | S3バケット名/keyの組み合わせ。どの state に対するロックかを識別 |
| stuck lock | 異常終了で残ったロック。force-unlock で解除 |
| use_lockfile | DynamoDB 不要の新方式。Terraform 1.10+ |

## Q&A

**Q: tflock って何？**

Terraform の状態ロック用 DynamoDB テーブル。`terraform apply` を複数プロセスが同時実行したときの競合（state drift）を防ぐため、排他ロックを DynamoDB の Conditional Write で実現している。

**Q: ロックを使わないとどうなる？**

2人が同時に apply すると tfstate が上書きされ、AWS の実リソースとの不一致が起きる。復旧には `terraform import` での手動修復が必要で、実質的にプロジェクトのIaC管理が破綻する。

**Q: 個人開発で1人しか触らないなら不要では？**

技術的には最小限で運用可能だが、以下のリスクがあるのでロックは入れておくべき:

- CI/CD から apply することになったとき（GitHub Actions 等）、人が手動で打つ apply と競合しうる
- 複数端末から触る可能性（自宅PC と ラップトップ）
- プロジェクトを将来誰かと共同開発する可能性

「1人でも入れておく」のが無難。コストも微々たる。

**Q: stuck lock になったら？**

1. 本当に他の apply が動いていないか確認（`ps aux | grep terraform`、他の端末、CI 実行履歴）
2. 問題なければ `terraform force-unlock <LOCK_ID>` で解除
3. 同時 apply 中に force-unlock すると state drift するので最終手段

**Q: use_lockfile に今すぐ移行すべき？**

しなくてOK。deprecation 警告は出るが動作は続く。以下のタイミングでまとめて移行が効率的:

- プロジェクトが安定して変更頻度が下がったタイミング
- DynamoDB テーブル管理が煩わしくなった時
- Terraform バージョンを大幅に上げた時

## 関連

- [07-terraform-bootstrap.md](07-terraform-bootstrap.md) - Bootstrap パターンで tflock テーブル自体をどう作るか
- [02-terraform-code-walkthrough.md](02-terraform-code-walkthrough.md) - `backend "s3"` ブロックの設定解説
- [reference/terraform-basics.md](reference/terraform-basics.md) - Terraform 基礎リファレンス

---

_Saved at 2026-04-18 via /learning-flow:topic_
