"""Phase 6 Bedrock invoker Lambda handler.

Invokes Amazon Bedrock (Claude) with a short prompt.
Token cost is minimized: max_tokens=64, 3 fixed invocations via load.sh.
"""

import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    """Invoke Bedrock Claude model and return the response text."""
    region = os.environ.get("REGION", "us-east-1")
    model_id = os.environ.get("MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0")

    client = boto3.client("bedrock-runtime", region_name=region)
    prompt = event.get("prompt", "Say hello in one sentence.")

    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 64,
        "messages": [{"role": "user", "content": prompt}],
    })

    resp = client.invoke_model(
        modelId=model_id,
        body=body,
        contentType="application/json",
        accept="application/json",
    )
    result = json.loads(resp["body"].read())

    logger.info(json.dumps({
        "input_tokens": result["usage"]["input_tokens"],
        "output_tokens": result["usage"]["output_tokens"],
    }))

    return {
        "statusCode": 200,
        "body": result["content"][0]["text"],
    }
