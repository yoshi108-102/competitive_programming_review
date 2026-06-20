# 01. Boto3 Resource API vs Client API

> 出典: [Resources - Boto3 documentation](https://docs.aws.amazon.com/boto3/latest/guide/resources.html)（閲覧日 2026-05-09）
>
> このノートは公式ドキュメントの「Resources」を起点に、Claude が自動生成した教材です。

## 概要

Boto3 には AWS にアクセスする 2 つの API がある:

- **Client API**: AWS API そのままの低レベルインターフェース。`boto3.client("dynamodb").query(...)` のように、AWS API のシグネチャを忠実にラップ
- **Resource API**: より Python 的なオブジェクト指向のインターフェース。`boto3.resource("dynamodb").Table("foo").query(...)` のようにオブジェクト経由で操作

公式 docs から読み取れる **重要な事実**:

> The AWS Python SDK team does not intend to add new features to the resources interface in boto3. Existing interfaces will continue to operate during boto3's lifecycle. Customers can find access to newer service features through the client interface.

**Resource API は新機能追加が止まっている (= メンテナンスモード)**。新しい AWS サービスの機能は Client 経由でしか使えない。
ただし DynamoDB の Resource API は既に十分に成熟しており、シンプルな CRUD なら Resource の方が読みやすい。

このプロジェクトでは:
- **Resource API を採用** (Task 3 で既に採用済み)
- ページネーションなど Resource では扱いにくい部分が出てきたら、その箇所だけ Client API を使う

## 公式 docs に沿った解説

### A. Resources vs Clients

公式 docs より:

> Resources represent an object-oriented interface to AWS, providing a higher-level abstraction than the raw, low-level calls made by service clients.

つまり:

| | Client API | Resource API |
|---|---|---|
| 抽象度 | 低レベル（AWS API そのまま） | 高レベル（オブジェクト指向） |
| 例 | `client.put_item(TableName="foo", Item={...})` | `resource.Table("foo").put_item(Item={...})` |
| 戻り値の型 | dict（DynamoDB 型 `{"S": "..."}` 形式） | dict（Python ネイティブ型に自動変換） |
| 新サービス対応 | あり | **メンテナンスモード**（新機能なし） |
| カバー範囲 | 全 AWS サービス | 限定的（DynamoDB / S3 / SQS / EC2 など） |

具体的な違い（DynamoDB の例）:

```python
# Client API: DynamoDB 型を明示的に書く必要がある
client = boto3.client("dynamodb")
client.put_item(
    TableName="users",
    Item={"user_id": {"S": "user-A"}, "score": {"N": "1500"}},
)
# → 戻り値 Item も {"user_id": {"S": "user-A"}, ...} の形

# Resource API: Python の dict そのまま
table = boto3.resource("dynamodb").Table("users")
table.put_item(Item={"user_id": "user-A", "score": Decimal("1500")})
# → 戻り値 Item も {"user_id": "user-A", "score": Decimal("1500")}
```

### B. Resource を作る

`boto3.resource("service-name")` で取得する。サービスリソース自体は識別子不要だが、その下のリソース（Table 等）には識別子が必要。

```python
import boto3

dynamodb = boto3.resource("dynamodb")        # サービスリソース（識別子なし）
table = dynamodb.Table("users")              # 個別リソース（テーブル名 = 識別子）
```

### C. Resource の主要概念

公式 docs が紹介する Resource の中核概念:

#### Identifiers（識別子）

リソースインスタンスを一意に特定する値。インスタンス生成時に必須。

```python
# S3 Object には bucket_name と key の 2 つが識別子
obj = s3.Object(bucket_name="my-bucket", key="test.txt")

# 識別子が欠けると例外
obj = s3.Object(bucket_name="my-bucket")  # ← key が無い → 例外
```

公式 docs より:
> Resource instance equality is based solely on identifiers.

つまり「region や account が違っても、識別子が同じなら同一リソース扱い」。

#### Attributes（属性）

リソースのプロパティ。**初回アクセス時に AWS API を呼んで遅延ロードされる**ことがある（パフォーマンスに影響）。

```python
obj = s3.Object(bucket_name="my-bucket", key="test.txt")
print(obj.last_modified)   # ← この行で HEAD リクエストが飛ぶかも
```

レイテンシが気になる場合は `obj.load()` で明示的にロードタイミングを制御できる。

#### Actions（アクション）

リソースに対する操作メソッド。識別子は自動的に渡される。

```python
table.put_item(Item={...})        # TableName は table の識別子から自動
table.query(KeyConditionExpression="...")
```

公式 docs の重要な制約:

> Parameters **must** be passed as keyword arguments. They will not work as positional arguments.

→ `table.put_item({...})` のような位置引数渡しは不可。必ず `Item=...` のキーワードで。

#### Sub-resources / References

リソース間の関係を表現する仕組み:

- **Sub-resource**: 親と識別子を共有する子（例: `bucket.Object(key="...")`）
- **Reference**: 識別子を共有しない関連リソース（例: `instance.subnet`）

DynamoDB ではあまり使わないが、S3 では `bucket.Object(...)` が頻出。

#### Waiters

リソースが特定状態になるまでポーリングする仕組み:

```python
bucket.wait_until_exists()
instance.wait_until_running()
```

DynamoDB では Table 作成後の `ACTIVE` 状態待ちで使うことがある（このプロジェクトでは Terraform が責任を持つので Lambda 内では不要）。

### D. スレッドセーフティ — 重要な制約

公式 docs より:

> Resource instances are **not** thread safe and should not be shared across threads or processes.

**Resource インスタンスはスレッド間で共有してはいけない**。マルチスレッドで使う場合は各スレッドで個別に作成する。

```python
# ダメな例: モジュールトップで作って複数スレッドから使う
table = boto3.resource("dynamodb").Table("users")  # 共有は NG

# OK: スレッドごとに作る
def worker():
    session = boto3.session.Session()
    table = session.resource("dynamodb").Table("users")
    # ...
```

> 補足（公式 docs には記載なし）: AWS Lambda は **1 リクエスト = 1 実行環境**で動くため、Lambda 内ではこの制約は通常問題にならない（並列リクエストは別 Lambda インスタンスで処理される）。ただし Lambda の内部で `concurrent.futures` 等を使う場合は注意。

### E. メンテナンスモードの含意

冒頭の警告を再掲:

> The AWS Python SDK team does not intend to add new features to the resources interface in boto3.

これが意味するのは:

- **既存サービス（DynamoDB / S3 / SQS / EC2）の Resource API は維持される**
- **新サービスは Client のみ提供される**（例: Bedrock, EventBridge など新しめのサービスは Resource 無し）
- DynamoDB の **新機能** が出ても Resource には反映されない可能性がある

このプロジェクト的には:
- DynamoDB の基本 CRUD は Resource で書く（読みやすさ優先）
- Resource にない機能（例: paginator）が必要になったら Client を併用する
- 将来的に Resource 全体が deprecated になる可能性は念頭に置いておく

## 重要ポイント

- **Resource API は メンテナンスモード**。新機能は来ないが、DynamoDB の既存機能は十分使える
- Resource は **オブジェクト指向で書きやすい**。`{"S": "..."}` のような DynamoDB 型表現を意識せずに済む
- **Identifiers**（テーブル名など）はインスタンス生成時に必須
- **Attributes** は遅延ロードでレイテンシが発生し得る（DynamoDB Table ではあまり遭遇しない）
- **Actions** はキーワード引数のみ受け付ける
- **スレッド非安全**: Resource インスタンスをスレッド間共有しない
- 一部機能（**paginator**）は Resource にない → Client を併用する判断は次の教材へ

## コード例

### Client API と Resource API の同じ操作

```python
import boto3
from decimal import Decimal

# === Client API ===
client = boto3.client("dynamodb")
client.put_item(
    TableName="users",
    Item={
        "user_id": {"S": "user-A"},
        "score": {"N": "1500.5"},
    },
)
resp = client.get_item(
    TableName="users",
    Key={"user_id": {"S": "user-A"}},
)
# resp["Item"] == {"user_id": {"S": "user-A"}, "score": {"N": "1500.5"}}


# === Resource API（このプロジェクトで使う方）===
table = boto3.resource("dynamodb").Table("users")
table.put_item(
    Item={
        "user_id": "user-A",
        "score": Decimal("1500.5"),
    },
)
resp = table.get_item(Key={"user_id": "user-A"})
# resp["Item"] == {"user_id": "user-A", "score": Decimal("1500.5")}
```

Resource 版は **Python の dict をそのまま渡せる**点と、**Decimal で受け取れる**（教材 Task 3 / 02 参照）点で読みやすい。

## 関連

- 議論・Q&A: （`lesson` 中に発生したら `reference/` 配下にリンクが追加されます）
- 次の教材: [02-dynamodb-pagination-and-paginators.md](02-dynamodb-pagination-and-paginators.md) — DynamoDB の 1 MB 制限、LastEvaluatedKey、Boto3 Paginators
- 関連 Task: [Phase 1 / Task 3 / 02 (Decimal 問題)](../practice/json-dumps-default-str.md)

---

_Auto-generated at 2026-05-09 via /learning-flow:material（公式 docs 駆動）_
