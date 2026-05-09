"""sync_submissions Lambda ハンドラのテスト。

観点:
- 正常系: AtCoder API からの取得結果が submissions テーブルに保存される
- last_sync_epoch が更新され、次回呼び出しは差分のみ取得される
- 異常系: AtCoder ユーザー名未登録 / 認証なし
"""

import json

import boto3
import requests_mock

from lambdas.sync_submissions.handler import lambda_handler

MOCK_SUBMISSIONS = [
    {
        "id": 12345,
        "epoch_second": 1700000000,
        "problem_id": "abc300_a",
        "contest_id": "abc300",
        "user_id": "testuser",
        "language": "Python (CPython 3.11.4)",
        "point": 100.0,
        "length": 150,
        "result": "AC",
        "execution_time": 30,
    },
    {
        "id": 12346,
        "epoch_second": 1700000060,
        "problem_id": "abc300_b",
        "contest_id": "abc300",
        "user_id": "testuser",
        "language": "Python (CPython 3.11.4)",
        "point": 200.0,
        "length": 200,
        "result": "WA",
        "execution_time": 50,
    },
]


def _event(user_id: str) -> dict:
    return {
        "requestContext": {"authorizer": {"claims": {"sub": user_id}}},
        "body": None,
    }


def _seed_user(user_id: str, atcoder_username: str, last_sync_epoch: int = 0):
    table = boto3.resource("dynamodb").Table("test-users")
    table.put_item(Item={
        "user_id": user_id,
        "atcoder_username": atcoder_username,
        "last_sync_epoch": last_sync_epoch,
    })


# --- 正常系 ---------------------------------------------------------


def test_sync_persists_submissions_and_updates_last_sync(dynamodb_tables):
    _seed_user("user-123", "testuser")

    with requests_mock.Mocker() as m:
        m.get(
            "https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions",
            json=MOCK_SUBMISSIONS,
        )
        resp = lambda_handler(_event("user-123"), None)

    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["data"]["synced_count"] == 2
    assert body["data"]["from_second"] == 0

    # submissions テーブルに 2 件保存されていること
    sub_table = boto3.resource("dynamodb").Table("test-submissions")
    items = sub_table.query(
        KeyConditionExpression="user_id = :u",
        ExpressionAttributeValues={":u": "user-123"},
    )["Items"]
    assert len(items) == 2
    assert {i["submission_id"] for i in items} == {"12345", "12346"}

    # users テーブルの last_sync_epoch が最新の epoch に更新されていること
    user_table = boto3.resource("dynamodb").Table("test-users")
    user = user_table.get_item(Key={"user_id": "user-123"})["Item"]
    assert int(user["last_sync_epoch"]) == 1700000060


def test_sync_uses_existing_last_sync_as_from_second(dynamodb_tables):
    """既に last_sync_epoch がある場合、それを from_second として API に渡す。"""
    _seed_user("user-123", "testuser", last_sync_epoch=1700000050)

    with requests_mock.Mocker() as m:
        m.get(
            "https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions",
            json=[MOCK_SUBMISSIONS[1]],  # 2 件目のみ返る
        )
        resp = lambda_handler(_event("user-123"), None)

    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["data"]["synced_count"] == 1
    assert body["data"]["from_second"] == 1700000050

    # API リクエストに正しい from_second が乗っていることを確認
    assert "from_second=1700000050" in m.last_request.url
    assert "user=testuser" in m.last_request.url


def test_sync_no_new_submissions_does_not_change_last_sync(dynamodb_tables):
    """API が空配列を返した場合、last_sync_epoch は更新されない。"""
    _seed_user("user-123", "testuser", last_sync_epoch=1700000060)

    with requests_mock.Mocker() as m:
        m.get(
            "https://kenkoooo.com/atcoder/atcoder-api/v3/user/submissions",
            json=[],
        )
        resp = lambda_handler(_event("user-123"), None)

    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["data"]["synced_count"] == 0

    user_table = boto3.resource("dynamodb").Table("test-users")
    user = user_table.get_item(Key={"user_id": "user-123"})["Item"]
    assert int(user["last_sync_epoch"]) == 1700000060  # 不変


# --- 異常系 ---------------------------------------------------------


def test_sync_returns_400_when_atcoder_username_not_configured(dynamodb_tables):
    """ユーザーが /users/me で AtCoder 名を登録していない場合 400。"""
    resp = lambda_handler(_event("user-123"), None)

    assert resp["statusCode"] == 400
    body = json.loads(resp["body"])
    assert body["error"]["code"] == "USER_NOT_CONFIGURED"


def test_sync_returns_400_when_user_record_exists_but_no_atcoder_username(dynamodb_tables):
    """user レコードはあるが atcoder_username が空のケース。"""
    table = boto3.resource("dynamodb").Table("test-users")
    table.put_item(Item={"user_id": "user-123"})  # atcoder_username なし

    resp = lambda_handler(_event("user-123"), None)

    assert resp["statusCode"] == 400
    assert json.loads(resp["body"])["error"]["code"] == "USER_NOT_CONFIGURED"


def test_sync_returns_401_when_no_cognito_claims(dynamodb_tables):
    resp = lambda_handler({"requestContext": {}}, None)

    assert resp["statusCode"] == 401
    assert json.loads(resp["body"])["error"]["code"] == "UNAUTHORIZED"
