"""Phase 8 Step Functions sandbox — Lambda handlers for Order Saga.

Five functions share this module, dispatched by function name at test time.
Each handler is importable as a standalone function for moto testing.
"""

import json
import logging
import os

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

ORDERS_TABLE = os.environ.get("ORDERS_TABLE", "phase8-orders")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")


# ---------------------------------------------------------------------------
# validate_order — step 1
# ---------------------------------------------------------------------------

def validate_order(event: dict, context=None) -> dict:
    """Validate order input.

    Raises ValueError if amount <= 0 or order_id is missing.
    Returns the event unchanged on success.
    """
    order_id = event.get("order_id")
    amount = event.get("amount", 0)
    items = event.get("items", [])

    if not order_id:
        raise ValueError("INVALID_ORDER: order_id is required")
    if amount <= 0:
        raise ValueError("INVALID_ORDER: amount must be positive")
    if not items:
        raise ValueError("INVALID_ORDER: items must not be empty")

    dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_DEFAULT_REGION", "ap-northeast-1"))
    table = dynamodb.Table(ORDERS_TABLE)
    table.put_item(Item={
        "order_id": order_id,
        "status": "VALIDATED",
        "amount": str(amount),
        "customer_id": event.get("customer_id", ""),
    })

    logger.info("Order validated: %s", order_id)
    return {**event, "validation_status": "OK"}


def validate_order_handler(event: dict, context=None) -> dict:
    return validate_order(event, context)


# ---------------------------------------------------------------------------
# charge_payment — step 2
# ---------------------------------------------------------------------------

def charge_payment(event: dict, context=None) -> dict:
    """Charge payment for the order.

    Raises RuntimeError for high-risk amounts (simulate payment failure).
    """
    order_id = event.get("order_id")
    amount = event.get("amount", 0)

    # Simulate payment gateway decline for very large amounts
    if amount > 50000:
        raise RuntimeError(f"PAYMENT_DECLINED: amount {amount} exceeds limit")

    dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_DEFAULT_REGION", "ap-northeast-1"))
    table = dynamodb.Table(ORDERS_TABLE)
    table.update_item(
        Key={"order_id": order_id},
        UpdateExpression="SET #s = :s",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":s": "PAYMENT_CHARGED"},
    )

    logger.info("Payment charged for order: %s amount: %s", order_id, amount)
    return {**event, "payment_status": "CHARGED"}


def charge_payment_handler(event: dict, context=None) -> dict:
    return charge_payment(event, context)


# ---------------------------------------------------------------------------
# update_inventory — step 3
# ---------------------------------------------------------------------------

def update_inventory(event: dict, context=None) -> dict:
    """Update inventory for ordered items.

    Raises RuntimeError if any item has qty > 100 (simulate out-of-stock).
    """
    order_id = event.get("order_id")
    items = event.get("items", [])

    for item in items:
        qty = item.get("qty", 0)
        sku = item.get("sku", "UNKNOWN")
        if qty > 100:
            raise RuntimeError(f"INVENTORY_SHORTAGE: sku={sku} qty={qty} exceeds stock")

    dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_DEFAULT_REGION", "ap-northeast-1"))
    table = dynamodb.Table(ORDERS_TABLE)
    table.update_item(
        Key={"order_id": order_id},
        UpdateExpression="SET #s = :s",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={":s": "INVENTORY_UPDATED"},
    )

    logger.info("Inventory updated for order: %s", order_id)
    return {**event, "inventory_status": "UPDATED"}


def update_inventory_handler(event: dict, context=None) -> dict:
    return update_inventory(event, context)


# ---------------------------------------------------------------------------
# notify_customer — step 4
# ---------------------------------------------------------------------------

def notify_customer(event: dict, context=None) -> dict:
    """Send SNS notification to customer."""
    order_id = event.get("order_id")
    customer_id = event.get("customer_id", "unknown")

    if SNS_TOPIC_ARN:
        sns = boto3.client("sns", region_name=os.environ.get("AWS_DEFAULT_REGION", "ap-northeast-1"))
        message = json.dumps({
            "order_id": order_id,
            "customer_id": customer_id,
            "status": "ORDER_CONFIRMED",
        })
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Message=message,
            Subject=f"Order Confirmed: {order_id}",
        )

    logger.info("Customer notified for order: %s customer: %s", order_id, customer_id)
    return {**event, "notification_status": "SENT"}


def notify_customer_handler(event: dict, context=None) -> dict:
    return notify_customer(event, context)


# ---------------------------------------------------------------------------
# compensate_order — compensation step (saga rollback)
# ---------------------------------------------------------------------------

def compensate_order(event: dict, context=None) -> dict:
    """Compensate / rollback the order (saga compensation step)."""
    order_id = event.get("order_id")
    error_info = event.get("error", {})

    dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_DEFAULT_REGION", "ap-northeast-1"))
    table = dynamodb.Table(ORDERS_TABLE)
    table.update_item(
        Key={"order_id": order_id},
        UpdateExpression="SET #s = :s, error_info = :e",
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s": "COMPENSATED",
            ":e": json.dumps(error_info),
        },
    )

    logger.info("Order compensated: %s error: %s", order_id, error_info)
    return {**event, "compensation_status": "DONE"}


def compensate_order_handler(event: dict, context=None) -> dict:
    return compensate_order(event, context)


# ---------------------------------------------------------------------------
# Default Lambda entry point (routes by FUNCTION_NAME env var)
# ---------------------------------------------------------------------------

_DISPATCH = {
    "phase8-validate-order": validate_order,
    "phase8-charge-payment": charge_payment,
    "phase8-update-inventory": update_inventory,
    "phase8-notify-customer": notify_customer,
    "phase8-compensate-order": compensate_order,
}


def lambda_handler(event: dict, context=None) -> dict:
    """Generic dispatcher — each Lambda function has its own entry point,
    but they all share this module via different handler= values in Terraform."""
    fn = os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "")
    handler_fn = _DISPATCH.get(fn)
    if handler_fn is None:
        raise RuntimeError(f"Unknown function name: {fn}")
    return handler_fn(event, context)
