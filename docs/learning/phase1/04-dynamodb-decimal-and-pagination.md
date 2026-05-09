# 02. DynamoDB の 1MB 制限 / LastEvaluatedKey / Boto3 Paginators

> 出典:
> - [Paginating table query results in DynamoDB - AWS Docs](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Query.Pagination.html)（閲覧日 2026-05-09）
> - [Paginators - Boto3 documentation](https://docs.aws.amazon.com/boto3/latest/guide/paginators.html)（閲覧日 2026-05-09）
>
> このノートは公式ドキュメントの「Query Pagination」と「Boto3 Paginators」を起点に、Claude が自動生成した教材です。

## 概要

DynamoDB の `Query` / `Scan` は **1 リクエストあたり 1 MB** までしか結果を返さない。
これを超える結果がある場合、レスポンスに `LastEvaluatedKey` が含まれ、それを次のリクエストの `ExclusiveStartKey` に渡して続きを取得する。

この仕組みを「**手で書く**」のは間違えやすいので、`shared/db.py` の `query_all(table, **kwargs)` でループを 1 箇所に隔離する。
Boto3 には Client API 用の **Paginator** という抽象化機構があるが、**Resource API では使えない**ため、このプロジェクトでは手書きループ方式を採る。

## 公式 docs に沿った解説

### A. なぜ pagination が必要か — 1 MB 制限

公式 docs より（DynamoDB Query Pagination）:

> DynamoDB *paginates* the results from `Query` operations. With pagination, the `Query` results are divided into "pages" of data that are 1 MB in size (or less).
>
> A single `Query` only returns a result set that fits within the 1 MB size limit.

つまり:

- DynamoDB の Query は **1 リクエストで 1 MB まで** しか返さない
- それを超える結果がある場合、**「ここまで読んだ位置」を表す `LastEvaluatedKey`** がレスポンスに入る
- アプリケーション側はそれを **`ExclusiveStartKey`** として次リクエストに渡し、続きを取得する

このプロジェクト（AtCoder の submission 一覧）では、ユーザーが数千件の submission を持つ可能性があるため、放置すると **結果が途中で切れる事故**が起きる。

### B. LastEvaluatedKey の正しい解釈

公式 docs（重要、ハマりポイント）:

> If `LastEvaluatedKey` is not empty, it does not necessarily mean that there is more data in the result set. The only way to know when you have reached the end of the result set is when `LastEvaluatedKey` is empty.

**`LastEvaluatedKey` が空になるまでループせよ**ということ。「なんとなく終わってそう」での早期離脱はダメ。

具体的には:
- レスポンスに `LastEvaluatedKey` が含まれていない / `None` → **終端**
- 含まれている → **次がある可能性が高い**（実際 0 件かもしれないが、確認するには次リクエストが必要）

### C. ExclusiveStartKey で続きを取得する手順

公式 docs の手順を整形:

1. 初回 `Query` を発行（`ExclusiveStartKey` なし）
2. レスポンスから `LastEvaluatedKey` を取り出す
3. `LastEvaluatedKey` が無ければ終了
4. あれば、それを `ExclusiveStartKey` にセットして同じ `KeyConditionExpression` で再 `Query`
5. 2 に戻る

### D. AWS CLI でのデバッグ例

公式 docs より、実際の通信を見る例:

```bash
aws dynamodb query --table-name Movies \
    --projection-expression "title" \
    --key-condition-expression "#y = :yyyy" \
    --expression-attribute-names '{"#y":"year"}' \
    --expression-attribute-values '{":yyyy":{"N":"1993"}}' \
    --page-size 5 \
    --debug
```

第 1 回レスポンス（途中）:

```json
{
  "Count": 5,
  "Items": [
    {"title": {"S": "A Bronx Tale"}},
    {"title": {"S": "A Perfect World"}},
    ...
  ],
  "LastEvaluatedKey": {"year": {"N": "1993"}, "title": {"S": "Benny & Joon"}},
  "ScannedCount": 5
}
```

最終レスポンス（`LastEvaluatedKey` が無い）:

```json
{
  "Count": 1,
  "Items": [{"title": {"S": "What's Eating Gilbert Grape"}}],
  "ScannedCount": 1
}
```

`LastEvaluatedKey` の **有無** で「もう続きがあるか」を判断する。

### E. Limit パラメータ

公式 docs より:

> You can also reduce page size by limiting the number of items in the result set, with the `Limit` parameter of the `Query` operation.

`Limit` は **1 ページあたりの最大件数**を指定するパラメータ。`LastEvaluatedKey` の挙動は変わらない（`Limit` で打ち切られたら `LastEvaluatedKey` が返り、続きが取れる）。

「全件欲しい」用途では `Limit` は使わない方が良い（無意味にラウンドトリップが増える）。
「先頭 N 件だけ取りたい」用途では使う。

### F. Boto3 Paginators

ここから Boto3 側の話。公式 docs より:

> Some AWS operations return results that are incomplete and require subsequent requests in order to attain the entire result set. The process of sending subsequent requests to continue where a previous request left off is called *pagination*.
>
> *Paginators* are a feature of boto3 that act as an abstraction over the process of iterating over an entire result set of a truncated API operation.

つまり Paginators は **`LastEvaluatedKey` ループを Boto3 側でやってくれる仕組み**。

#### 使い方

```python
import boto3

client = boto3.client("dynamodb")          # ← Client API のみ
paginator = client.get_paginator("query")
page_iterator = paginator.paginate(
    TableName="users",
    KeyConditionExpression="user_id = :uid",
    ExpressionAttributeValues={":uid": {"S": "user-A"}},
)

for page in page_iterator:
    for item in page["Items"]:
        # item は {"user_id": {"S": "user-A"}, ...} 形式（Client なので）
        ...
```

#### PaginationConfig

`paginate()` に渡せるオプション:

- **`MaxItems`**: 全体で取得する最大アイテム数
- **`PageSize`**: 1 ページあたりの最大件数（DynamoDB の `Limit` 相当）
- **`StartingToken`**: 前回の続きから再開するためのトークン

```python
page_iterator = paginator.paginate(
    TableName="users",
    KeyConditionExpression="...",
    PaginationConfig={"MaxItems": 1000, "PageSize": 100},
)
```

### G. Paginator の落とし穴 — Resource API では使えない

> 補足（公式 docs には記載なし）: 公式 docs の Paginator ガイドは **Client API 前提**で書かれている。実際に試すと:
>
> ```python
> table = boto3.resource("dynamodb").Table("users")
> table.get_paginator(...)  # ← AttributeError: 'dynamodb.Table' object has no attribute 'get_paginator'
> ```
>
> つまり **`get_paginator` は Client にしか生えていない**。Resource API でクエリしている場合は paginator を使えない。

このプロジェクトでは Resource API を採用しているので（教材 01 参照）、**`shared/db.py` では手書きの while ループで `LastEvaluatedKey` を処理する**。Paginator を使う場合は Client API への切り替えとセットになる。

## 重要ポイント

- DynamoDB の Query は **1 リクエスト 1 MB まで**。それ以上は分割される
- レスポンスの **`LastEvaluatedKey` が空になるまでループ**して全件取る必要がある（途中で `LastEvaluatedKey` がある状態で止めるとデータ取りこぼし）
- 次リクエストの **`ExclusiveStartKey`** に前回の `LastEvaluatedKey` を渡す
- Boto3 Paginator は `LastEvaluatedKey` ループを抽象化してくれるが、**Client API 専用**で Resource API では使えない
- このプロジェクトでは Resource を使うため、`shared/db.py` 内で手書き while ループを 1 か所だけ書く（再利用してハンドラ側からは隠す）

## コード例

### 手書きの pagination ループ（Resource API、`shared/db.py` の本体イメージ）

```python
def query_all(table, **kwargs):
    """LastEvaluatedKey を自動で追って全件返す。"""
    items = []
    while True:
        resp = table.query(**kwargs)
        items.extend(resp.get("Items", []))

        # LastEvaluatedKey が無ければ終端
        last_key = resp.get("LastEvaluatedKey")
        if not last_key:
            break

        # 次リクエストの ExclusiveStartKey に渡して続きを取る
        kwargs["ExclusiveStartKey"] = last_key

    return items
```

呼び出し側:

```python
items = query_all(
    table,
    KeyConditionExpression="user_id = :uid",
    ExpressionAttributeValues={":uid": "user-A"},
)
# 1MB 超えていても全件返ってくる
```

### Paginator 版（参考、Client API）

```python
client = boto3.client("dynamodb")
paginator = client.get_paginator("query")
items = []
for page in paginator.paginate(
    TableName="users",
    KeyConditionExpression="user_id = :uid",
    ExpressionAttributeValues={":uid": {"S": "user-A"}},
):
    items.extend(page.get("Items", []))
```

→ ただし戻りは Client 形式（`{"S": "user-A"}` 等のラップが付く）になり、`Decimal` への自動変換も無い。Resource 採用の Lambda コード全体に paginator のためだけに Client を混ぜるのはコストが見合わない。

## 関連

- 議論・Q&A: （`lesson` 中に発生したら `reference/` 配下にリンクが追加されます）
- 前の教材: [01-boto3-resource-vs-client.md](01-boto3-resource-vs-client.md) — Resource API vs Client API
- 関連 Task: [Phase 1 / Task 3 / 02 (Decimal 問題)](../task3/02-json-dumps-default-and-decimal.md)

---

_Auto-generated at 2026-05-09 via /learning-flow:material（公式 docs 駆動）_
