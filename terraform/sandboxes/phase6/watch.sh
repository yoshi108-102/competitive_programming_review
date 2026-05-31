#!/usr/bin/env bash
# watch.sh — Phase 6 Bedrock metrics observation
# Steps: (0) dashboard smoke check, (1) wait for metrics, (2-5) get metrics

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
MODEL_ID="${MODEL_ID:-anthropic.claude-3-haiku-20240307-v1:0}"
FUNCTION_NAME="bedrock-sandbox-invoker"
DASHBOARD_NAME="phase6-bedrock"

echo "=== Phase6 Bedrock watch.sh ==="

# --- (0) Dashboard existence smoke check ---
echo "[0/5] Checking dashboard existence..."
aws cloudwatch get-dashboard \
  --dashboard-name "$DASHBOARD_NAME" \
  --region "$REGION" \
  --query 'DashboardName' \
  --output text > /dev/null \
  && echo "  Dashboard '${DASHBOARD_NAME}' exists" \
  || echo "  WARNING: Dashboard not found. Run 'make sandbox-up-phase6' first."

# --- (1) Wait for metrics propagation ---
echo "[1/5] Waiting 120 seconds for Bedrock metrics to propagate..."
echo "      Bedrock metrics can take 2-5 minutes after invocation."
sleep 120

# Compute time window (last 10 minutes)
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_TIME=$(date -u -v -10M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -d '-10 minutes' +"%Y-%m-%dT%H:%M:%SZ")

# --- (2) Bedrock InvocationCount ---
echo "[2/5] Bedrock InvocationCount (last 10 min, period=60s)..."
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Bedrock" \
  --metric-name "InvocationCount" \
  --dimensions Name=ModelId,Value="$MODEL_ID" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 60 \
  --statistics Sum \
  --region "$REGION" \
  --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Sum:Sum}' \
  --output table

# --- (3) Token counts ---
echo "[3/5] Bedrock InputTokenCount / OutputTokenCount..."
for METRIC in InputTokenCount OutputTokenCount; do
  echo "  ${METRIC}:"
  aws cloudwatch get-metric-statistics \
    --namespace "AWS/Bedrock" \
    --metric-name "$METRIC" \
    --dimensions Name=ModelId,Value="$MODEL_ID" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --period 60 \
    --statistics Sum \
    --region "$REGION" \
    --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Sum:Sum}' \
    --output table
done

# --- (4) InvocationLatency ---
echo "[4/5] Bedrock InvocationLatency (avg ms)..."
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Bedrock" \
  --metric-name "InvocationLatency" \
  --dimensions Name=ModelId,Value="$MODEL_ID" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 60 \
  --statistics Average \
  --region "$REGION" \
  --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Avg:Average}' \
  --output table

# --- (5) Lambda metrics ---
echo "[5/5] Lambda Errors / Duration / Invocations..."
for METRIC in Errors Duration Invocations; do
  echo "  Lambda ${METRIC}:"
  aws cloudwatch get-metric-statistics \
    --namespace "AWS/Lambda" \
    --metric-name "$METRIC" \
    --dimensions Name=FunctionName,Value="$FUNCTION_NAME" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --period 60 \
    --statistics Sum \
    --region "$REGION" \
    --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Value:Sum}' \
    --output table
done

echo ""
echo "=== CloudWatch Console Deep Links ==="
echo "Dashboard:"
echo "  https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${DASHBOARD_NAME}"
echo "Bedrock metrics:"
echo "  https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#metricsV2:graph=~();namespace=AWS/Bedrock"
echo "Lambda logs:"
echo "  https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:log-groups/log-group/\$252Faws\$252Flambda\$252F${FUNCTION_NAME}"
echo "Bedrock invocation logs:"
echo "  https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:log-groups/log-group/\$252Faws\$252Fbedrock\$252Finvocations"

echo ""
echo "WARNING: When you are done observing, run:"
echo "    make sandbox-down-phase6"
echo "    (S3/KMS charges continue until destroyed)"
