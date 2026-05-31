"""Phase 7 EventBridge sandbox — Lambda processor handler.

Handles events arriving from:
  - EventBridge custom bus (order.created events via put-events)
  - Heartbeat rate(1 minute) rule on default bus
  - EventBridge Scheduler one-shot invocation
  - Direct Lambda invocations (load.sh test)

Emits a custom EMF metric so Phase7/EventBridge/EventsProcessed
appears in CloudWatch without a PutMetricData API call.
"""

import json
import logging
import os
import time

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


def lambda_handler(event: dict, context) -> dict:  # type: ignore[type-arg]
    logger.info("EVENT: %s", json.dumps(event))

    source = event.get("source", "scheduled")
    detail_type = event.get("detail-type", "unknown")
    detail = event.get("detail", {})

    logger.info(
        "source=%s detail-type=%s detail=%s",
        source,
        detail_type,
        detail,
    )

    # Emit custom metric via Embedded Metric Format (EMF).
    # CloudWatch Logs agent parses the JSON and publishes the metric
    # without a PutMetricData API call.
    emf_record = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": "Phase7/EventBridge",
                    "Dimensions": [["Source"]],
                    "Metrics": [{"Name": "EventsProcessed", "Unit": "Count"}],
                }
            ],
        },
        "Source": source,
        "EventsProcessed": 1,
    }
    print(json.dumps(emf_record))

    return {"statusCode": 200, "source": source, "detail-type": detail_type}
