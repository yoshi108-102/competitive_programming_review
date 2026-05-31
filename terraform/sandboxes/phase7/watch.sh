#!/usr/bin/env bash
# Phase 7 watch.sh — CloudWatch metrics snapshot for EventBridge sandbox
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
SANDBOX_DIR="$(cd "$(dirname "$0")" && pwd)"
FUNC_NAME=$(terraform -chdir="$SANDBOX_DIR" output -raw processor_name)
DASHBOARD_NAME="${FUNC_NAME%-processor}-dashboard"  # e.g. phase7-dashboard
DASHBOARD=$(terraform -chdir="$SANDBOX_DIR" output -raw dashboard_url 2>/dev/null || echo "")
DLQ_URL=$(terraform -chdir="$SANDBOX_DIR" output -raw dlq_url)

echo "INFO: CloudWatch メトリクスの反映には 1〜5 分かかります。"
echo "INFO: SQS: load.sh 実行後 5 分待ってください (--period 300)"
echo "INFO: EventBridge: rate(1 minute) は初回発火まで最大 60 秒待ってください"
echo ""

echo "============================================"
echo " Phase 7 EventBridge — watch.sh"
echo "============================================"
echo ""

# ── 0. Dashboard smoke test ──────────────────────────────────────────────
echo "[0/5] Checking dashboard exists..."
aws cloudwatch get-dashboard \
  --dashboard-name "$DASHBOARD_NAME" \
  --region "$REGION" \
  --query 'DashboardName' \
  --output text 2>/dev/null \
  && echo "  Dashboard OK" \
  || echo "  Dashboard NOT FOUND — run: make sandbox-up-phase7"
echo ""

# ── 1. Wait for metrics propagation ─────────────────────────────────────
echo "[1/5] Waiting 90s for CloudWatch metrics propagation..."
echo "      (Lambda metrics ~1-3 min delay; EMF custom metrics ~2-5 min)"
sleep 90

# ── 2. Lambda Invocations / Errors / Duration ────────────────────────────
echo ""
echo "[2/5] Lambda Invocations & Errors (last 5 min, period=60s):"
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_TIME=$(date -u -v-5M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -d "5 minutes ago" +"%Y-%m-%dT%H:%M:%SZ")

for metric in Invocations Errors Duration; do
  STAT="Sum"
  [ "$metric" = "Duration" ] && STAT="Average"
  VAL=$(aws cloudwatch get-metric-statistics \
    --region "$REGION" \
    --namespace AWS/Lambda \
    --metric-name "$metric" \
    --dimensions Name=FunctionName,Value="$FUNC_NAME" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --period 300 \
    --statistics "$STAT" \
    --query 'sort_by(Datapoints, &Timestamp)[-1].'"$STAT" \
    --output text 2>/dev/null || echo "N/A")
  echo "  $metric ($STAT): $VAL"
done

# ── 3. EventBridge FailedInvocations ────────────────────────────────────
echo ""
echo "[3/5] EventBridge FailedInvocations (last 5 min):"
aws cloudwatch get-metric-statistics \
  --region "$REGION" \
  --namespace AWS/Events \
  --metric-name FailedInvocations \
  --dimensions Name=RuleName,Value="${FUNC_NAME%-processor}-processor-rule" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 300 \
  --statistics Sum \
  --query 'Datapoints[*].Sum' \
  --output text

# ── 4. DLQ message count ─────────────────────────────────────────────────
echo ""
echo "[4/5] DLQ approximate message count:"
aws sqs get-queue-attributes \
  --region "$REGION" \
  --queue-url "$DLQ_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' \
  --output text

# ── 5. CloudWatch Logs Insights ──────────────────────────────────────────
echo ""
echo "[5/5] Recent Lambda log lines (Insights query):"
EPOCH_START=$(date -u -v-5M +%s 2>/dev/null || date -u -d "5 minutes ago" +%s)
EPOCH_END=$(date -u +%s)
QUERY_ID=$(aws logs start-query \
  --region "$REGION" \
  --log-group-name "/aws/lambda/$FUNC_NAME" \
  --start-time "$EPOCH_START" \
  --end-time "$EPOCH_END" \
  --query-string 'fields @timestamp, @message | filter @message like /EVENT/ | sort @timestamp desc | limit 10' \
  --query 'queryId' --output text)
sleep 5
aws logs get-query-results \
  --region "$REGION" \
  --query-id "$QUERY_ID" \
  --query 'results[*][?field==`@message`].value' \
  --output text

# ── Console deep links ───────────────────────────────────────────────────
echo ""
echo "============================================"
echo " Console deep links:"
echo "  Dashboard : $DASHBOARD"
echo "  EventBridge rules   : https://$REGION.console.aws.amazon.com/events/home?region=$REGION#/rules"
echo "  EventBridge archive : https://$REGION.console.aws.amazon.com/events/home?region=$REGION#/archives"
echo "  Lambda              : https://$REGION.console.aws.amazon.com/lambda/home?region=$REGION#/functions/$FUNC_NAME"
echo "  DLQ (SQS console)   : https://$REGION.console.aws.amazon.com/sqs/v3/home?region=$REGION"
echo "  X-Ray traces        : https://$REGION.console.aws.amazon.com/xray/home?region=$REGION#/traces"
echo "============================================"
echo ""
echo "!!! IMPORTANT: rate(1 minute) heartbeat rule is STILL ACTIVE !!!"
echo "!!! Run 'make sandbox-down-phase7' NOW to avoid continuous Lambda billing !!!"
echo "============================================"
