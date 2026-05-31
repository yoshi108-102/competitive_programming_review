"""Phase 9 X-Ray sandbox — Consumer Lambda handler.

Triggered by SQS event source mapping. Reads each record,
extracts the upstream trace-ID, updates DynamoDB status to "processed".
"""

import json
import logging
import os

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# ── X-Ray SDK — graceful fallback for test environments ─────────────────────
try:
    from aws_xray_sdk.core import patch_all, xray_recorder

    patch_all()
    _XRAY_AVAILABLE = True
except ImportError:  # pragma: no cover

    class _NoOpSegment:  # noqa: D101
        def put_annotation(self, key, value):  # noqa: D102
            pass

    class _NoOpRecorder:  # noqa: D101
        def current_segment(self):  # noqa: D102
            return _NoOpSegment()

    xray_recorder = _NoOpRecorder()
    _XRAY_AVAILABLE = False

# ── AWS clients ───────────────────────────────────────────────────────────
dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ.get("TABLE_NAME", "phase9-items")


def handler(event, context):
    """Consumer handler: process SQS records and update DynamoDB."""
    records = event.get("Records", [])
    processed = []

    for record in records:
        body = json.loads(record["body"])
        item_id = body["item_id"]

        # Extract upstream trace-ID propagated from producer via SQS attributes
        trace_id = (
            record.get("messageAttributes", {})
            .get("X-Amzn-Trace-Id", {})
            .get("stringValue", "unknown")
        )

        seg = xray_recorder.current_segment()
        seg.put_annotation("upstream_trace_id", trace_id)
        seg.put_annotation("item_id", item_id)

        table = dynamodb.Table(TABLE_NAME)
        table.update_item(
            Key={"id": item_id},
            UpdateExpression="SET #s = :s",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": "processed"},
        )
        logger.info("Item processed: %s upstream_trace=%s", item_id, trace_id)
        processed.append(item_id)

    return {"processed": processed}
