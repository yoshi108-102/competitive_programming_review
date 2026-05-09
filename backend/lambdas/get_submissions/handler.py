"""GET /submissions と GET /submissions/{submission_id}

機能:
- 一覧取得: query string の limit / nextToken でページング
- 個別取得: pathParameters の submission_id を使って 1 件取得
設計の根拠: docs/learning/phase1/task6/01-lambda-handler-skeleton.md
"""

import base64
import json

from shared.db import get_table
from shared.response import error, success

DEFAULT_LIMIT = 50
MAX_LIMIT = 100


def _encode_token(last_key: dict) -> str:
    """DynamoDB の LastEvaluatedKey (dict) を URL 安全な文字列にする。

    base64(JSON) 形式。クライアントは中身を知らないトークンとして扱う。
    """
    raw = json.dumps(last_key, default=str)
    return base64.urlsafe_b64encode(raw.encode()).decode()


def _decode_token(token: str) -> dict:
    raw = base64.urlsafe_b64decode(token.encode()).decode()
    return json.loads(raw)


def lambda_handler(event, context):
    # 1. 認証
    try:
        user_id = event["requestContext"]["authorizer"]["claims"]["sub"]
    except KeyError:
        return error("UNAUTHORIZED", "認証情報が見つかりません", status_code=401)

    table = get_table("SUBMISSIONS_TABLE")

    # 2. 個別取得 (pathParameters に submission_id がある場合)
    path_params = event.get("pathParameters") or {}
    submission_id = path_params.get("submission_id")
    if submission_id:
        item = table.get_item(
            Key={"user_id": user_id, "submission_id": submission_id}
        ).get("Item")
        if not item:
            return error("NOT_FOUND", "提出が見つかりません", status_code=404)
        return success(data=item)

    # 3. 一覧取得 (limit + nextToken でページング)
    qs = event.get("queryStringParameters") or {}
    try:
        limit = min(int(qs.get("limit", DEFAULT_LIMIT)), MAX_LIMIT)
    except (TypeError, ValueError):
        return error("INVALID_LIMIT", "limit は整数で指定してください")

    query_kwargs = {
        "KeyConditionExpression": "user_id = :uid",
        "ExpressionAttributeValues": {":uid": user_id},
        "Limit": limit,
    }

    if "nextToken" in qs and qs["nextToken"]:
        try:
            query_kwargs["ExclusiveStartKey"] = _decode_token(qs["nextToken"])
        except Exception:
            return error("INVALID_NEXT_TOKEN", "nextToken が不正です")

    resp = table.query(**query_kwargs)
    items = resp.get("Items", [])
    last_key = resp.get("LastEvaluatedKey")
    next_token = _encode_token(last_key) if last_key else None

    return success(
        data=items,
        meta={"count": len(items), "nextToken": next_token},
    )
