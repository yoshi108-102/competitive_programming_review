"""Phase 4 producer Lambda handler.

Writes items to DynamoDB and emits EMF metrics via CloudWatch Logs.
"""

import json
import os
import random
import time
from datetime import datetime, timezone

import boto3


def _get_table():
    table_name = os.environ["TABLE_NAME"]
    return boto3.resource("dynamodb").Table(table_name)  # type: ignore[attr-defined]


def handler(event, context):
    ddb = _get_table()
    count = event.get("count", 5)
    items_written = 0
    errors = 0

    for i in range(count):
        try:
            ddb.put_item(
                Item={
                    "pk": f"event#{datetime.now(timezone.utc).isoformat()}",
                    "sk": str(i),
                    "payload": f"item-{random.randint(1, 1000)}",
                }
            )
            items_written += 1
        except Exception as e:
            errors += 1
            print(f"ERROR writing item {i}: {e}")

    # EMF (Embedded Metric Format) — CloudWatch Logs Metrics を直接埋め込む
    # PutMetricData API 呼び出しなしでカスタムメトリクスが作られる
    emf = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": "Phase4/Lambda",
                    "Dimensions": [["FunctionName"]],
                    "Metrics": [
                        {"Name": "ItemsWritten", "Unit": "Count"},
                        {"Name": "ErrorCount", "Unit": "Count"},
                    ],
                }
            ],
        },
        "FunctionName": context.function_name,
        "items_written": items_written,
        "ErrorCount": errors,
    }
    print(json.dumps(emf))

    return {"items_written": items_written, "errors": errors}
