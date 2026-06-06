# 01. Lambda ハンドラの構造パターン

> 出典:
> - [Lambda - Working with the request and response payloads](https://docs.aws.amazon.com/lambda/latest/dg/services-apigateway.html#apigateway-example-event)（閲覧日 2026-05-09）
> - [API Gateway Lambda Proxy Integration - Input format](https://docs.aws.amazon.com/apigateway/latest/developerguide/set-up-lambda-proxy-integrations.html#api-gateway-simple-proxy-for-lambda-input-format)（閲覧日 2026-05-09）
>
> このノートは公式ドキュメントの「Lambda Proxy Integration の入出力形式」を起点に、Claude が自動生成した教材です。Task 6/7/8 で共通参照する設計ノート。

## 概要

API Gateway Proxy Integration 経由で呼ばれる Lambda ハンドラは、概ね以下の 4 段階で書ける:

```
1. event から認証・入力を取り出す
2. 入力を validate（不正なら error() で 400 系を返す）
3. business logic（DynamoDB / 外部 API 呼び出し）
4. success() / error() で API Gateway 形式に整形して返す
```

このプロジェクトの全ハンドラ（`save_user` / `sync_submissions` / `get_submissions`）はこの骨格を共有する。本ノートはその骨格を 1 枚にまとめた**設計パターン教材**。

## 公式 docs に沿った解説

### A. API Gateway Proxy Integration の event 構造

API Gateway → Lambda の event は以下のような形（要点抜粋、HTTP API v1.0 互換）:

```json
{
  "resource": "/users/me",
  "path": "/users/me",
  "httpMethod": "POST",
  "headers": { "Content-Type": "application/json", ... },
  "queryStringParameters": null,
  "pathParameters": null,
  "requestContext": {
    "authorizer": {
      "claims": {
        "sub": "user-uuid",      ← Cognito JWT の sub クレーム = 内部 user_id
        "email": "...",
        ...
      }
    },
    "requestId": "...",
    ...
  },
  "body": "{\"atcoder_username\": \"chokudai\"}",   ← ★ 文字列！
  "isBase64Encoded": false
}
```

**重要**: `body` は **JSON 文字列**として渡る。dict ではない。Lambda 側で `json.loads(event["body"])` で再パースする必要がある。

これは Task 3 で扱った「**戻り値の `body` も文字列**」と対称関係（入も出も文字列で渡される）。

### B. ステップ 1: 認証情報を取り出す

Cognito Authorizer 経由なら `event["requestContext"]["authorizer"]["claims"]["sub"]` に内部 user_id が入る。

```python
try:
    user_id = event["requestContext"]["authorizer"]["claims"]["sub"]
except KeyError:
    return error("UNAUTHORIZED", "認証情報が見つかりません", status_code=401)
```

`KeyError` でガードする理由:
- Authorizer が機能していない / route が認証不要設定 / テストで省略 などのケースで `KeyError`
- ハンドラ側で 401 を返すことで「認証がそもそも通ってない」と「認証は通ったが別エラー」を区別できる

### C. ステップ 2: ボディを再パース → validation

```python
try:
    body = json.loads(event.get("body") or "{}")
except json.JSONDecodeError:
    return error("INVALID_JSON", "リクエストボディが不正です")

atcoder_username = body.get("atcoder_username", "").strip()
if not atcoder_username:
    return error("MISSING_FIELD", "atcoder_username は必須です")
```

ポイント:

- `event.get("body") or "{}"` — `body` が `None` のケース（GET リクエストや空ボディ POST）を空 dict に倒す
- `json.JSONDecodeError` を捕まえて 400 を返す（500 で死なせない）
- `.strip()` で空白だけの文字列も弾く
- **validation は早期リターン**で書く（成功パスのインデントを浅く保つ）

### D. ステップ 3: business logic

ここはハンドラごとに違う。`save_user` の場合は DynamoDB の `put_item`:

```python
table = get_table("USERS_TABLE")
table.put_item(Item={
    "user_id": user_id,
    "atcoder_username": atcoder_username,
})
```

**`put_item` は upsert** — 同じ PK の item があれば**上書き**。新規なら作成。「`atcoder_username` を更新する」と「初回登録」を 1 つの操作で扱える。

> 補足（公式 docs には記載なし）: 厳密に「新規のみ」「既存のみ」を区別したい場合は `ConditionExpression="attribute_not_exists(user_id)"` 等で制御する。MVP ではそこまで必要ない。

### E. ステップ 4: レスポンスを返す

```python
return success(data={"user_id": user_id, "atcoder_username": atcoder_username})
```

`shared/response.py` の `success()` が以下を吸収（Task 3 で実装済み）:

- 戻り値の `{statusCode, headers, body}` 化
- CORS ヘッダ付与
- `body` の `json.dumps(default=str)` 化

### F. 全体テンプレート

上の 4 ステップを組み合わせると、ハンドラはおおむねこの形に収束する:

```python
import json
from shared.db import get_table
from shared.response import success, error


def handler(event, context):
    # 1. 認証
    try:
        user_id = event["requestContext"]["authorizer"]["claims"]["sub"]
    except KeyError:
        return error("UNAUTHORIZED", "認証情報が見つかりません", status_code=401)

    # 2. 入力 parse + validate
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return error("INVALID_JSON", "リクエストボディが不正です")

    field = body.get("some_field", "").strip()
    if not field:
        return error("MISSING_FIELD", "some_field は必須です")

    # 3. business logic
    table = get_table("SOME_TABLE")
    table.put_item(Item={"user_id": user_id, "some_field": field})

    # 4. response
    return success(data={"user_id": user_id, "some_field": field})
```

GET 系（読み取り）の場合は 2 が不要で、3 が `query_all(...)` になる。

## 重要ポイント

- API Gateway Proxy Integration の **`event["body"]` は文字列**。`json.loads` で再パースする必要あり
- 認証情報は **`requestContext.authorizer.claims.sub`** から取り出す（Cognito 規約）
- validation は **早期リターン + `error()`** で書く。成功パスを浅く保つ
- DynamoDB の `put_item` は **upsert**（同一 PK 上書き）。新規／更新を区別したい場合のみ `ConditionExpression`
- `success()` / `error()` 経由で必ずレスポンスを組み立てる（CORS ヘッダ漏れを構造的に防ぐ）

## コード例 — Task 6 で書く `save_user` ハンドラ

```python
# backend/lambdas/save_user/handler.py
import json

from shared.db import get_table
from shared.response import error, success


def lambda_handler(event, context):
    try:
        user_id = event["requestContext"]["authorizer"]["claims"]["sub"]
    except KeyError:
        return error("UNAUTHORIZED", "認証情報が見つかりません", status_code=401)

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return error("INVALID_JSON", "リクエストボディが不正です")

    atcoder_username = body.get("atcoder_username", "").strip()
    if not atcoder_username:
        return error("MISSING_FIELD", "atcoder_username は必須です")

    table = get_table("USERS_TABLE")
    table.put_item(Item={
        "user_id": user_id,
        "atcoder_username": atcoder_username,
    })

    return success(data={"user_id": user_id, "atcoder_username": atcoder_username})
```

## 関連

- 議論・Q&A: （`lesson` 中に発生したら `reference/` 配下にリンクが追加されます）
- 関連教材: [Task 3 / 01 - Lambda Proxy Integration](../02-lambda-proxy-integration-and-cors.md), [Task 3 / 03 - shared/response.py 設計](shared-response-helper-design.md), [Task 4 - shared/db.py](../03-boto3-resource-vs-client.md)

---

_Auto-generated at 2026-05-09 via /learning-flow:material（公式 docs 駆動 + 設計ノート）_
