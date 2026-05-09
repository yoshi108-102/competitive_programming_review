"""save_user Lambda ハンドラのテスト。

観点:
- 正常系: AtCoder ユーザー名が users テーブルに保存される
- 異常系: 認証なし / body 不正 / 必須フィールド欠落
- upsert: 同じ user_id で 2 回呼ぶと上書きされる
"""

import json

import boto3

from lambdas.save_user.handler import lambda_handler


def _make_event(user_id: str, body: dict | None) -> dict:
    raw_body = json.dumps(body) if body is not None else None
    return {
        "requestContext": {"authorizer": {"claims": {"sub": user_id}}},
        "body": raw_body,
    }


# --- 正常系 ---------------------------------------------------------


def test_save_user_persists_atcoder_username(dynamodb_tables):
    event = _make_event("user-123", {"atcoder_username": "chokudai"})
    resp = lambda_handler(event, None)

    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["data"]["user_id"] == "user-123"
    assert body["data"]["atcoder_username"] == "chokudai"

    # DynamoDB に実際に書かれていることを直接確認
    table = boto3.resource("dynamodb").Table("test-users")
    item = table.get_item(Key={"user_id": "user-123"})["Item"]
    assert item["atcoder_username"] == "chokudai"


def test_save_user_is_upsert_overwrites_existing(dynamodb_tables):
    """同じ user_id で 2 回呼ぶと後者で上書きされる (put_item の upsert 性質)。"""
    lambda_handler(_make_event("user-123", {"atcoder_username": "chokudai"}), None)
    resp = lambda_handler(_make_event("user-123", {"atcoder_username": "tourist"}), None)

    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["data"]["atcoder_username"] == "tourist"

    table = boto3.resource("dynamodb").Table("test-users")
    item = table.get_item(Key={"user_id": "user-123"})["Item"]
    assert item["atcoder_username"] == "tourist"


# --- 異常系 ---------------------------------------------------------


def test_save_user_returns_401_when_no_cognito_claims(dynamodb_tables):
    resp = lambda_handler({"requestContext": {}}, None)

    assert resp["statusCode"] == 401
    assert json.loads(resp["body"])["error"]["code"] == "UNAUTHORIZED"


def test_save_user_returns_400_for_invalid_json(dynamodb_tables):
    event = {
        "requestContext": {"authorizer": {"claims": {"sub": "user-123"}}},
        "body": "not-a-json{{",
    }
    resp = lambda_handler(event, None)

    assert resp["statusCode"] == 400
    assert json.loads(resp["body"])["error"]["code"] == "INVALID_JSON"


def test_save_user_returns_400_when_username_missing(dynamodb_tables):
    resp = lambda_handler(_make_event("user-123", {}), None)

    assert resp["statusCode"] == 400
    assert json.loads(resp["body"])["error"]["code"] == "MISSING_FIELD"


def test_save_user_returns_400_when_username_is_empty_or_whitespace(dynamodb_tables):
    for empty in ["", "   ", "\t\n"]:
        resp = lambda_handler(_make_event("user-123", {"atcoder_username": empty}), None)
        assert resp["statusCode"] == 400, f"empty value {empty!r} not rejected"


def test_save_user_handles_missing_body_gracefully(dynamodb_tables):
    """body が None (GET 風の event) でも 500 にならず 400 を返す。"""
    resp = lambda_handler(_make_event("user-123", None), None)

    assert resp["statusCode"] == 400
    assert json.loads(resp["body"])["error"]["code"] == "MISSING_FIELD"
