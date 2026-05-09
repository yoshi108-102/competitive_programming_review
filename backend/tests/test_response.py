"""shared/response.py の不変条件テスト。

設計教材: docs/learning/phase1/task3/03-shared-response-helper-design.md
テスト観点表: 同上 §テスト観点
"""

import json
from datetime import datetime
from decimal import Decimal

from shared.response import _CORS_HEADERS, error, success


# --- success() の不変条件 -----------------------------------------------------


def test_success_default_status_code_is_200():
    resp = success({"foo": 1})
    assert resp["statusCode"] == 200


def test_success_status_code_can_be_overridden():
    resp = success({"foo": 1}, status_code=201)
    assert resp["statusCode"] == 201


def test_success_body_has_data_and_null_meta_by_default():
    resp = success({"foo": 1})
    body = json.loads(resp["body"])
    assert body == {"data": {"foo": 1}, "meta": None}


def test_success_body_includes_meta_when_provided():
    resp = success({"foo": 1}, meta={"page": 2})
    body = json.loads(resp["body"])
    assert body == {"data": {"foo": 1}, "meta": {"page": 2}}


def test_success_serializes_decimal_via_default_str():
    """DynamoDB から返ってきた Decimal を含む dict を渡しても落ちず、文字列化される。

    教材 02 の構造的衝突（Boto3 → Decimal、json.dumps → 標準では非対応）を
    helper が吸収していることの確認。
    """
    item = {"score": Decimal("1500.5"), "id": "SUB001"}
    resp = success(item)
    body = json.loads(resp["body"])
    # Decimal は str 化される（フロント側で parseFloat する想定）
    assert body["data"]["score"] == "1500.5"
    assert body["data"]["id"] == "SUB001"


def test_success_serializes_datetime_via_default_str():
    resp = success({"ts": datetime(2026, 5, 9, 12, 0, 0)})
    body = json.loads(resp["body"])
    # datetime の str() は空白区切り（ISO ではない点に注意 → 教材 02 §G）
    assert body["data"]["ts"] == "2026-05-09 12:00:00"


# --- error() の不変条件 ------------------------------------------------------


def test_error_default_status_code_is_400():
    resp = error("VALIDATION_ERROR", "入力が不正です")
    assert resp["statusCode"] == 400


def test_error_status_code_can_be_overridden():
    resp = error("NOT_FOUND", "存在しません", status_code=404)
    assert resp["statusCode"] == 404


def test_error_body_has_code_and_message():
    resp = error("VALIDATION_ERROR", "入力が不正です")
    body = json.loads(resp["body"])
    assert body == {"error": {"code": "VALIDATION_ERROR", "message": "入力が不正です"}}


# --- CORS ヘッダ周り ---------------------------------------------------------


def test_success_includes_all_cors_headers():
    resp = success({"foo": 1})
    headers = resp["headers"]
    assert headers["Access-Control-Allow-Origin"] == "*"
    assert "Content-Type" in headers["Access-Control-Allow-Headers"]
    assert "Authorization" in headers["Access-Control-Allow-Headers"]
    assert "POST" in headers["Access-Control-Allow-Methods"]
    assert headers["Content-Type"] == "application/json"


def test_error_includes_all_cors_headers():
    resp = error("X", "y")
    assert resp["headers"]["Access-Control-Allow-Origin"] == "*"
    assert resp["headers"]["Content-Type"] == "application/json"


def test_helper_is_stateless_no_mutation_of_module_constant():
    """ヘルパー呼び出しで _CORS_HEADERS が変化しないこと。

    将来 helper 内で headers を update してしまうと、
    複数リクエスト間で状態漏洩の事故が起きるためガード。
    """
    snapshot = dict(_CORS_HEADERS)
    success({"foo": 1})
    error("X", "y")
    assert _CORS_HEADERS == snapshot
