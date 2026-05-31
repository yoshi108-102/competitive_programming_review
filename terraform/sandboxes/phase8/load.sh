#!/usr/bin/env bash
# load.sh — Phase8 Step Functions load generator
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-1}"

echo "INFO: Looking up state machine ARN..."
SFN_ARN=$(aws stepfunctions list-state-machines \
  --region "$REGION" \
  --query "stateMachines[?name=='phase8-order-saga'].stateMachineArn" \
  --output text)

if [[ -z "$SFN_ARN" ]]; then
  echo "ERROR: state machine phase8-order-saga not found in region $REGION" >&2
  echo "       Run: make sandbox-up-phase8 first" >&2
  exit 1
fi

echo "Target SFN: $SFN_ARN"

# --- Scenario 1: Happy path (10 executions)
echo ""
echo "=== Scenario 1: Happy path (10 executions) ==="
for i in $(seq 1 10); do
  ORDER_ID="order-$(date +%s)-${i}"
  AMOUNT=$(( (RANDOM % 9000) + 1000 ))
  INPUT=$(printf '{"order_id":"%s","amount":%d,"customer_id":"cust-001","items":[{"sku":"SKU-A","qty":2}]}' \
    "$ORDER_ID" "$AMOUNT")
  aws stepfunctions start-execution \
    --state-machine-arn "$SFN_ARN" \
    --name "happy-${ORDER_ID}" \
    --input "$INPUT" \
    --region "$REGION" \
    --query "executionArn" \
    --output text
  sleep 0.3
done

# --- Scenario 2: Compensation path (amount=0 triggers validate_order failure)
echo ""
echo "=== Scenario 2: Compensation path — amount=0 (3 executions) ==="
for i in $(seq 1 3); do
  ORDER_ID="fail-$(date +%s)-${i}"
  INPUT=$(printf '{"order_id":"%s","amount":0,"customer_id":"cust-bad","items":[]}' "$ORDER_ID")
  aws stepfunctions start-execution \
    --state-machine-arn "$SFN_ARN" \
    --name "fail-${ORDER_ID}" \
    --input "$INPUT" \
    --region "$REGION" \
    --query "executionArn" \
    --output text
  sleep 0.3
done

# --- Scenario 3: Inventory failure (qty=9999 triggers update_inventory failure)
echo ""
echo "=== Scenario 3: Inventory shortage path (2 executions) ==="
for i in $(seq 1 2); do
  ORDER_ID="inv-$(date +%s)-${i}"
  INPUT=$(printf '{"order_id":"%s","amount":5000,"customer_id":"cust-002","items":[{"sku":"SKU-RARE","qty":9999}]}' \
    "$ORDER_ID")
  aws stepfunctions start-execution \
    --state-machine-arn "$SFN_ARN" \
    --name "inv-${ORDER_ID}" \
    --input "$INPUT" \
    --region "$REGION" \
    --query "executionArn" \
    --output text
  sleep 0.3
done

echo ""
echo "All executions submitted. Wait ~30s then run: make sandbox-watch-phase8"

# Show recent executions immediately
echo ""
echo "=== Recent executions (direct API) ==="
aws stepfunctions list-executions \
  --state-machine-arn "$SFN_ARN" \
  --region "$REGION" \
  --max-results 15 \
  --query "executions[*].{name:name,status:status,start:startDate}" \
  --output table
