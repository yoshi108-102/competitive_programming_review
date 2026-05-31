#!/usr/bin/env bash
# load.sh — Phase 10 SNS load generator
set -euo pipefail

TOPIC_ARN=$(terraform -chdir=terraform/sandboxes/phase10 output -raw orders_topic_arn)
AWS_REGION=${AWS_REGION:-ap-northeast-1}

publish() {
  local order_type=$1
  local order_id="ORD-$(date +%s%N | tail -c 8)"
  aws sns publish \
    --region "$AWS_REGION" \
    --topic-arn "$TOPIC_ARN" \
    --message "{\"order_id\":\"$order_id\",\"amount\":$(( RANDOM % 9000 + 1000 ))}" \
    --message-attributes "{
      \"order_type\":{\"DataType\":\"String\",\"StringValue\":\"$order_type\"}
    }" \
    --subject "New Order" \
    --query 'MessageId' --output text
}

echo "=== Publish 10 standard orders ==="
for i in $(seq 1 10); do publish "standard"; sleep 0.2; done

echo "=== Publish 5 express orders (-> Lambda also triggered) ==="
for i in $(seq 1 5); do publish "express"; sleep 0.2; done

echo "=== Publish 3 wholesale orders ==="
for i in $(seq 1 3); do publish "wholesale"; sleep 0.2; done

echo "=== Publish 2 UNKNOWN orders (only analytics queue receives, no filter match) ==="
for i in $(seq 1 2); do publish "unknown_type"; sleep 0.2; done

echo "=== DLQ test: malformed payload -> Lambda error ==="
aws sns publish \
  --region "$AWS_REGION" \
  --topic-arn "$TOPIC_ARN" \
  --message "NOT_JSON" \
  --message-attributes "{
    \"order_type\":{\"DataType\":\"String\",\"StringValue\":\"express\"}
  }" \
  --query 'MessageId' --output text

echo "Done. Wait 3-5 min for CloudWatch metrics to populate."
echo "Run: bash terraform/sandboxes/phase10/watch.sh"
