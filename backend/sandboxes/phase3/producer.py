"""Phase 3 SQS — Producer Lambda.

メッセージを SQS メインキューに送信する。
event["count"] 件送信する(デフォルト 10)。
"""
import json
import os
import time

import boto3

sqs = boto3.client("sqs")
QUEUE_URL = os.environ["QUEUE_URL"]


def handler(event, context):
    count = event.get("count", 10)
    for i in range(count):
        sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps({"index": i, "ts": time.time()}),
        )
    return {"sent": count}
