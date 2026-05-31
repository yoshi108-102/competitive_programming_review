#!/usr/bin/env bash
# Phase 7 load generator
# Usage: ./load.sh [count=10]
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
SANDBOX_DIR="$(cd "$(dirname "$0")" && pwd)"
BUS_NAME=$(terraform -chdir="$SANDBOX_DIR" output -raw bus_name)
FUNC_NAME=$(terraform -chdir="$SANDBOX_DIR" output -raw processor_name)
COUNT="${1:-10}"

echo "=== Phase 7 load.sh: sending $COUNT custom events to $BUS_NAME ==="

# ── 1. put-events: custom events → immediate rule evaluation ──────────────
# put-events is request-priced only; safer than letting rate() rule fire.
for i in $(seq 1 "$COUNT"); do
  ORDER_ID="order-$(date +%s)-$i"
  AMOUNT=$((RANDOM % 10000))
  RESULT=$(aws events put-events \
    --region "$REGION" \
    --entries "[
      {
        \"EventBusName\": \"$BUS_NAME\",
        \"Source\": \"com.example.orders\",
        \"DetailType\": \"order.created\",
        \"Detail\": \"{\\\"orderId\\\": \\\"$ORDER_ID\\\", \\\"amount\\\": $AMOUNT}\",
        \"Resources\": []
      }
    ]" \
    --query 'FailedEntryCount' \
    --output text)
  if [ "$RESULT" = "0" ]; then
    echo "  [$i/$COUNT] $ORDER_ID sent OK (amount=$AMOUNT)"
  else
    echo "  [$i/$COUNT] FAILED (FailedEntryCount=$RESULT)"
  fi
  sleep 0.5
done

# ── 2. Pattern-mismatch events (no rule match, useful to observe MatchedRules=0) ──
echo ""
echo "=== Sending 3 events that won't match any rule (pattern mismatch demo) ==="
for i in 1 2 3; do
  aws events put-events \
    --region "$REGION" \
    --entries "[
      {
        \"EventBusName\": \"$BUS_NAME\",
        \"Source\": \"com.example.inventory\",
        \"DetailType\": \"stock.updated\",
        \"Detail\": \"{\\\"sku\\\": \\\"SKU-$i\\\"}\"
      }
    ]" --query 'FailedEntryCount' --output text > /dev/null
  echo "  [no-match $i] sent"
done

# ── 3. Direct Lambda invoke to observe cold start ─────────────────────────
echo ""
echo "=== Direct invoke (bypass EventBridge) to observe cold start ==="
aws lambda invoke \
  --region "$REGION" \
  --function-name "$FUNC_NAME" \
  --payload '{"source":"load.sh","detail-type":"DirectInvoke","detail":{"test":true}}' \
  --log-type Tail \
  --query 'LogResult' \
  --output text \
  /dev/null | base64 -d | tail -5

echo ""
echo "=== load.sh done. Wait 1-2 min, then run: make sandbox-watch-phase7 ==="
echo "=== REMINDER: rate(1 minute) heartbeat rule is ACTIVE ==="
echo "=== Run 'make sandbox-down-phase7' when you are done observing! ==="
