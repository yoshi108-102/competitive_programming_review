"""Phase 2 S3 sandbox — Lambda handler for ObjectCreated events.

Logs the bucket name, object key, and size for each S3 record received.
Optionally publishes a custom CloudWatch metric (ObjectSizeBytes) when
CLOUDWATCH_NAMESPACE env var is set.
"""

import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

CLOUDWATCH_NAMESPACE = os.environ.get("CLOUDWATCH_NAMESPACE", "")


def _put_custom_metric(bucket: str, key: str, size: int) -> None:
    """Publish object size as a custom CloudWatch metric (optional)."""
    if not CLOUDWATCH_NAMESPACE:
        return
    cw = boto3.client("cloudwatch", region_name=os.environ.get("AWS_DEFAULT_REGION", "ap-northeast-1"))
    cw.put_metric_data(
        Namespace=CLOUDWATCH_NAMESPACE,
        MetricData=[{
            "MetricName": "ObjectSizeBytes",
            "Value": float(size),
            "Unit": "Bytes",
            "Dimensions": [
                {"Name": "BucketName", "Value": bucket},
            ],
        }],
    )


def lambda_handler(event: dict, context=None) -> dict:
    """Process S3 ObjectCreated events.

    Logs each record and optionally emits a custom CloudWatch metric.
    Returns {"statusCode": 200} on success.
    """
    records = event.get("Records", [])
    for record in records:
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]
        size = record["s3"]["object"].get("size", 0)
        logger.info(
            json.dumps({"bucket": bucket, "key": key, "size_bytes": size})
        )
        _put_custom_metric(bucket, key, size)
    return {"statusCode": 200, "processed": len(records)}
