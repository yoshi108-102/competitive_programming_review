"""POST /users/me — ログイン中ユーザーの AtCoder ユーザー名を保存する Lambda。

Cognito JWT の sub クレームを内部 user_id として、リクエストボディで指定された
atcoder_username を DynamoDB の users テーブルに upsert する。
設計の根拠: docs/learning/phase1/practice/lambda-handler-skeleton.md
"""

import json

from shared.db import get_table
from shared.response import error, success


def lambda_handler(event, context):
    # 1. 認証情報を取り出す
    try:
        user_id = event["requestContext"]["authorizer"]["claims"]["sub"]
    except KeyError:
        return error("UNAUTHORIZED", "認証情報が見つかりません", status_code=401)

    # 2. body を再パース → validate
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return error("INVALID_JSON", "リクエストボディが不正です")

    atcoder_username = body.get("atcoder_username", "").strip()
    if not atcoder_username:
        return error("MISSING_FIELD", "atcoder_username は必須です")

    # 3. DynamoDB に upsert (put_item は同一 PK で上書き)
    table = get_table("USERS_TABLE")
    item = {"user_id": user_id, "atcoder_username": atcoder_username}
    table.put_item(Item=item)

    # 4. response
    return success(data=item)
