"""Phase 4 consumer Lambda handler.

Reads items from DynamoDB. Randomly raises an exception (~10% of calls)
to exercise CloudWatch Alarms and simulate real error scenarios.
"""

import os
import random

import boto3
from boto3.dynamodb.conditions import Attr


def _get_table():
    table_name = os.environ["TABLE_NAME"]
    return boto3.resource("dynamodb").Table(table_name)  # type: ignore[attr-defined]


def handler(event, context):
    ddb = _get_table()
    # Scan for items whose pk starts with 'event#' (simple consumer pattern)
    resp = ddb.scan(
        FilterExpression=Attr("pk").begins_with("event#"),
        Limit=10,
    )
    count = resp.get("Count", 0)

    # 意図的にたまにエラーを出す(アラームが鳴るか確認用)
    if random.random() < 0.1:
        raise Exception("Simulated consumer error")

    print(f"consumer read {count} items")
    return {"read": count}
