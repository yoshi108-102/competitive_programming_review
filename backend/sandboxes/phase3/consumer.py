"""Phase 3 SQS — Consumer Lambda.

SQS のイベントソースマッピング経由で呼び出される。
index が 7 の倍数のメッセージは意図的に例外を投げ DLQ 流入を体験する。
"""
import json
import time


def handler(event, context):
    for record in event["Records"]:
        body = json.loads(record["body"])
        print(f"Processing index={body['index']}")
        # 疑似失敗: index が 7 の倍数は例外を投げて DLQ を試す
        if body["index"] % 7 == 0:
            raise ValueError(f"Intentional failure for index {body['index']}")
        time.sleep(0.1)
