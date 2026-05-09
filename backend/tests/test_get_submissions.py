"""get_submissions Lambda ハンドラのテスト。

機能:
- 一覧取得: limit + nextToken でページング
- 個別取得: pathParameters.submission_id で 1 件取得
"""

import json
from decimal import Decimal

import boto3

from lambdas.get_submissions.handler import lambda_handler


def _event(
    user_id: str,
    query_params: dict | None = None,
    path_params: dict | None = None,
) -> dict:
    return {
        "requestContext": {"authorizer": {"claims": {"sub": user_id}}},
        "queryStringParameters": query_params,
        "pathParameters": path_params,
    }


def _seed_submissions(user_id: str, n: int):
    table = boto3.resource("dynamodb").Table("test-submissions")
    for i in range(n):
        table.put_item(Item={
            "user_id": user_id,
            "submission_id": f"SUB{i:04d}",
            "score": Decimal(str(1000 + i)),
            "problem_id": f"abc100_{chr(97 + i % 26)}",
        })


# --- 一覧取得: 全件 -------------------------------------------------


def test_list_returns_all_submissions_within_default_limit(dynamodb_tables):
    _seed_submissions("user-A", 3)
    resp = lambda_handler(_event("user-A"), None)

    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert len(body["data"]) == 3
    assert body["meta"]["count"] == 3
    assert body["meta"]["nextToken"] is None


def test_list_returns_empty_for_user_with_no_submissions(dynamodb_tables):
    resp = lambda_handler(_event("ghost"), None)
    body = json.loads(resp["body"])
    assert body["data"] == []
    assert body["meta"]["nextToken"] is None


def test_list_respects_user_boundary(dynamodb_tables):
    _seed_submissions("user-A", 3)
    _seed_submissions("user-B", 2)
    resp = lambda_handler(_event("user-A"), None)
    body = json.loads(resp["body"])
    assert len(body["data"]) == 3


# --- ページング -----------------------------------------------------


def test_list_with_limit_returns_partial_and_next_token(dynamodb_tables):
    _seed_submissions("user-A", 5)
    resp = lambda_handler(_event("user-A", query_params={"limit": "2"}), None)

    body = json.loads(resp["body"])
    assert len(body["data"]) == 2
    assert body["meta"]["nextToken"] is not None  # まだ続きあり


def test_list_pagination_round_trip(dynamodb_tables):
    _seed_submissions("user-A", 5)

    # Page 1 (limit=3)
    resp1 = lambda_handler(_event("user-A", query_params={"limit": "3"}), None)
    body1 = json.loads(resp1["body"])
    assert len(body1["data"]) == 3
    token = body1["meta"]["nextToken"]
    assert token is not None

    # Page 2 (続き)
    resp2 = lambda_handler(
        _event("user-A", query_params={"limit": "3", "nextToken": token}),
        None,
    )
    body2 = json.loads(resp2["body"])
    assert len(body2["data"]) == 2  # 残り 2 件
    assert body2["meta"]["nextToken"] is None  # 終端

    # 重複していないこと
    ids_page1 = {i["submission_id"] for i in body1["data"]}
    ids_page2 = {i["submission_id"] for i in body2["data"]}
    assert ids_page1.isdisjoint(ids_page2)
    assert ids_page1 | ids_page2 == {f"SUB{i:04d}" for i in range(5)}


def test_list_with_invalid_limit_returns_400(dynamodb_tables):
    resp = lambda_handler(_event("user-A", query_params={"limit": "abc"}), None)
    assert resp["statusCode"] == 400
    assert json.loads(resp["body"])["error"]["code"] == "INVALID_LIMIT"


def test_list_with_invalid_next_token_returns_400(dynamodb_tables):
    _seed_submissions("user-A", 1)
    resp = lambda_handler(
        _event("user-A", query_params={"nextToken": "not-base64-or-json"}),
        None,
    )
    assert resp["statusCode"] == 400
    assert json.loads(resp["body"])["error"]["code"] == "INVALID_NEXT_TOKEN"


# --- 個別取得 -------------------------------------------------------


def test_detail_returns_submission_when_exists(dynamodb_tables):
    _seed_submissions("user-A", 3)
    resp = lambda_handler(
        _event("user-A", path_params={"submission_id": "SUB0001"}),
        None,
    )
    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["data"]["submission_id"] == "SUB0001"
    assert body["data"]["problem_id"] == "abc100_b"


def test_detail_returns_404_when_not_found(dynamodb_tables):
    resp = lambda_handler(
        _event("user-A", path_params={"submission_id": "SUB9999"}),
        None,
    )
    assert resp["statusCode"] == 404
    assert json.loads(resp["body"])["error"]["code"] == "NOT_FOUND"


def test_detail_does_not_leak_other_users_data(dynamodb_tables):
    """user-B の submission を user-A が問い合わせても 404 になる。"""
    _seed_submissions("user-B", 1)
    resp = lambda_handler(
        _event("user-A", path_params={"submission_id": "SUB0000"}),
        None,
    )
    assert resp["statusCode"] == 404


# --- 認証 -----------------------------------------------------------


def test_returns_401_when_no_cognito_claims(dynamodb_tables):
    resp = lambda_handler({"requestContext": {}}, None)
    assert resp["statusCode"] == 401


# --- Decimal シリアライズ (Task 3 の確認再掲) -----------------------


def test_decimal_score_is_serialized_as_string(dynamodb_tables):
    _seed_submissions("user-A", 1)
    resp = lambda_handler(_event("user-A"), None)
    body = json.loads(resp["body"])
    # Decimal("1000") → "1000" (default=str 経由)
    assert body["data"][0]["score"] == "1000"
