"""Phase 9 X-Ray sandbox — Producer Lambda handler.

Receives HTTP POST /items via API Gateway, writes to DynamoDB,
then sends a message to SQS with trace-ID propagation.

aws-xray-sdk is available in the Lambda Layer at runtime.
In test environments (moto), the xray_recorder is replaced with a no-op shim.
"""

import json
import logging
import os
import uuid

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# ── X-Ray SDK — graceful fallback for test environments ─────────────────────
try:
    from aws_xray_sdk.core import patch_all, xray_recorder

    patch_all()
    _XRAY_AVAILABLE = True
except ImportError:  # pragma: no cover — sdk absent in unit-test venv

    class _NoOpSegment:  # noqa: D101
        trace_id = "1-00000000-000000000000000000000000"

        def put_annotation(self, key, value):  # noqa: D102
            pass

        def put_metadata(self, key, value):  # noqa: D102
            pass

    class _NoOpRecorder:  # noqa: D101
        def current_segment(self):  # noqa: D102
            return _NoOpSegment()

    xray_recorder = _NoOpRecorder()
    _XRAY_AVAILABLE = False

# ── AWS clients (module-level for connection reuse) ──────────────────────────
dynamodb = boto3.resource("dynamodb")
sqs = boto3.client("sqs")

TABLE_NAME = os.environ.get("TABLE_NAME", "phase9-items")
QUEUE_URL = os.environ.get("QUEUE_URL", "")


def handler(event, context):
    """Producer handler: DynamoDB put + SQS send with X-Ray tracing."""
    item_id = str(uuid.uuid4())

    # X-Ray annotations (searchable in Insights/filter)
    seg = xray_recorder.current_segment()
    seg.put_annotation("item_id", item_id)
    seg.put_annotation("function", "producer")
    seg.put_metadata("event", event)

    # DynamoDB write
    table = dynamodb.Table(TABLE_NAME)
    table.put_item(Item={"id": item_id, "status": "pending"})
    logger.info("DynamoDB put_item succeeded: %s", item_id)

    # SQS send with manual trace-ID propagation
    trace_id = seg.trace_id
    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps({"item_id": item_id}),
        MessageAttributes={
            "X-Amzn-Trace-Id": {
                "DataType": "String",
                "StringValue": trace_id,
            }
        },
    )
    logger.info("SQS send_message succeeded: %s", item_id)

    return {
        "statusCode": 202,
        "body": json.dumps({"item_id": item_id}),
    }
