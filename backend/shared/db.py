"""DynamoDB 操作の共通ヘルパー。

Lambda ハンドラから DynamoDB を操作するボイラープレートを集約する。
設計の根拠: docs/learning/phase1/task4/01-boto3-resource-vs-client.md,
            docs/learning/phase1/task4/02-dynamodb-pagination-and-paginators.md
"""

import os
from typing import Any

import boto3


def get_table(table_name_env: str):
    """環境変数からテーブル名を解決して boto3 Resource の Table を返す。

    本番では Terraform / CDK が、テストでは monkeypatch.setenv (conftest.py) が
    環境変数をセットする想定。ハードコードしないことで本番/テスト両対応になる。

    例: get_table("SUBMISSIONS_TABLE") → boto3.resource(...).Table("test-submissions")
    """
    table_name = os.environ[table_name_env]
    return boto3.resource("dynamodb").Table(table_name)


def query_all(table, **kwargs) -> list[dict[str, Any]]:
    """LastEvaluatedKey を自動で追って query 結果を全件返す。

    DynamoDB の Query は 1 リクエストあたり 1MB 上限。それを超える結果がある場合、
    レスポンスに LastEvaluatedKey が含まれる。これを ExclusiveStartKey に渡して
    続きを取得するループをここに集約する。
    → docs/learning/phase1/task4/02-dynamodb-pagination-and-paginators.md
    """
    items: list[dict[str, Any]] = []
    while True:
        resp = table.query(**kwargs)
        items.extend(resp.get("Items", []))

        last_key = resp.get("LastEvaluatedKey")
        if not last_key:
            break

        kwargs["ExclusiveStartKey"] = last_key

    return items
