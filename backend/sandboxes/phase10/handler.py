"""Phase 10 SNS sandbox — Lambda notifier handler.

Receives SNS events (express orders only, via filter policy) and logs each
order as a structured JSON entry.  Intentionally raises ValueError when the
SNS message body is not valid JSON so that the DLQ scenario can be observed.
"""

import json
import logging
import os

logger = logging.getLogger(__name__)
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


def handler(event: dict, context=None) -> dict:
    """Process SNS records delivered by the express-order filter subscription.

    Args:
        event: Lambda invocation payload with "Records" list of SNS records.
        context: Lambda context object (unused).

    Returns:
        dict with statusCode 200 and a processed count on success.

    Raises:
        ValueError: if any SNS message body is not valid JSON (triggers DLQ).
    """
    records = event.get("Records", [])
    processed = 0

    for record in records:
        raw_message = record["Sns"]["Message"]
        try:
            msg = json.loads(raw_message)
        except json.JSONDecodeError as exc:
            logger.error(
                json.dumps({
                    "event": "malformed_message",
                    "raw": raw_message,
                    "error": str(exc),
                })
            )
            raise ValueError(f"Message is not valid JSON: {raw_message!r}") from exc

        logger.info(
            json.dumps({
                "event": "express_order_received",
                "order_id": msg.get("order_id"),
                "amount": msg.get("amount"),
                "subject": record["Sns"].get("Subject"),
            })
        )
        processed += 1

    return {"statusCode": 200, "processed": processed}
