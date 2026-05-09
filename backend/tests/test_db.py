"""shared/db.py のテスト。

主な観点:
- get_table が環境変数経由でテーブル名を解決すること
- query_all が LastEvaluatedKey を自動追従して全件返すこと（1MB 制限相当の状況を Limit=1 で再現）
"""

from decimal import Decimal

import boto3
import pytest

from shared.db import get_table, query_all


# --- get_table -------------------------------------------------------


def test_get_table_resolves_name_from_env(dynamodb_tables):
    table = get_table("SUBMISSIONS_TABLE")
    # conftest.py で SUBMISSIONS_TABLE=test-submissions が注入されている
    assert table.name == "test-submissions"


def test_get_table_raises_when_env_missing(monkeypatch):
    monkeypatch.delenv("MISSING_TABLE", raising=False)
    with pytest.raises(KeyError):
        get_table("MISSING_TABLE")


# --- query_all -------------------------------------------------------


def _put_n_submissions(n: int, user_id: str = "user-A"):
    """テスト用に同一 user_id で n 件 put。"""
    table = boto3.resource("dynamodb").Table("test-submissions")
    for i in range(n):
        table.put_item(
            Item={
                "user_id": user_id,
                "submission_id": f"SUB{i:04d}",
                "score": Decimal(f"{1000 + i}"),
            }
        )


def test_query_all_returns_all_items_in_single_page(dynamodb_tables):
    _put_n_submissions(3)
    items = query_all(
        get_table("SUBMISSIONS_TABLE"),
        KeyConditionExpression="user_id = :uid",
        ExpressionAttributeValues={":uid": "user-A"},
    )
    assert len(items) == 3


def test_query_all_follows_last_evaluated_key_across_pages(dynamodb_tables):
    """Limit=1 を渡して人為的に複数ページに分割し、ループが正しく追えることを確認。

    本番環境では 1MB 超のデータで自然と LastEvaluatedKey が返るが、
    moto + 小データで同じ挙動を引き出すには Limit を使うのが定石。
    """
    _put_n_submissions(5)
    items = query_all(
        get_table("SUBMISSIONS_TABLE"),
        KeyConditionExpression="user_id = :uid",
        ExpressionAttributeValues={":uid": "user-A"},
        Limit=1,  # ← 1 ページ = 1 件、5 ページに分割される
    )
    # ループが LastEvaluatedKey を追わないと 1 件しか返らないので、ここで全件確認
    assert len(items) == 5
    submission_ids = sorted(i["submission_id"] for i in items)
    assert submission_ids == ["SUB0000", "SUB0001", "SUB0002", "SUB0003", "SUB0004"]


def test_query_all_returns_empty_list_for_no_match(dynamodb_tables):
    items = query_all(
        get_table("SUBMISSIONS_TABLE"),
        KeyConditionExpression="user_id = :uid",
        ExpressionAttributeValues={":uid": "ghost-user"},
    )
    assert items == []


def test_query_all_does_not_cross_user_boundary(dynamodb_tables):
    """別ユーザーの submission を混ぜないこと。"""
    _put_n_submissions(3, user_id="user-A")
    _put_n_submissions(2, user_id="user-B")
    items = query_all(
        get_table("SUBMISSIONS_TABLE"),
        KeyConditionExpression="user_id = :uid",
        ExpressionAttributeValues={":uid": "user-A"},
        Limit=1,  # 複数ページに分割しても境界を破らないこと
    )
    assert len(items) == 3
    assert all(i["user_id"] == "user-A" for i in items)
