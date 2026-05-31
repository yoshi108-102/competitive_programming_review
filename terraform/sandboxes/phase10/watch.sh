#!/usr/bin/env bash
# watch.sh — Phase 10 CloudWatch observation
set -euo pipefail

REGION=${AWS_REGION:-ap-northeast-1}
TOPIC_NAME="phase10-orders"
FUNCTION="phase10-notifier"
DASH_NAME="phase10-sns"
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START=$(date -u -v -15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "15 minutes ago" +%Y-%m-%dT%H:%M:%SZ)

echo "=== (1) Dashboard smoke check ==="
DASH_ARN=$(aws cloudwatch get-dashboard \
  --region "$REGION" \
  --dashboard-name "$DASH_NAME" \
  --query 'DashboardArn' --output text 2>/dev/null) \
  && echo "Dashboard $DASH_NAME: OK ($DASH_ARN)" \
  || { echo "Dashboard $DASH_NAME: NOT FOUND (run terraform apply first)"; exit 1; }

echo ""
echo "=== (2) Waiting for metrics to propagate (SNS/SQS lag up to 5 min) ==="
echo "    Sleeping 30 s for demonstration (re-run after 3-5 min for full data)."
sleep 30

get_metric() {
  local ns=$1 metric=$2 dim_name=$3 dim_val=$4
  aws cloudwatch get-metric-statistics \
    --region "$REGION" \
    --namespace "$ns" \
    --metric-name "$metric" \
    --dimensions "Name=$dim_name,Value=$dim_val" \
    --start-time "$START" --end-time "$END" \
    --period 300 --statistics Sum \
    --query 'sort_by(Datapoints, &Timestamp)[*].[Timestamp,Sum]' \
    --output table
}

echo ""
echo "=== (3) SNS Metrics ==="

echo "--- NumberOfMessagesPublished ($TOPIC_NAME) ---"
get_metric AWS/SNS NumberOfMessagesPublished TopicName "$TOPIC_NAME"

echo "--- NumberOfNotificationsDelivered ---"
get_metric AWS/SNS NumberOfNotificationsDelivered TopicName "$TOPIC_NAME"

echo "--- NumberOfNotificationsFailed (check for KMS errors) ---"
get_metric AWS/SNS NumberOfNotificationsFailed TopicName "$TOPIC_NAME"

echo "--- NumberOfNotificationsFilteredOut ---"
get_metric AWS/SNS NumberOfNotificationsFilteredOut TopicName "$TOPIC_NAME"

echo ""
echo "=== SQS Queue Depth ==="
for q in fulfillment analytics wholesale fulfillment-dlq analytics-dlq wholesale-dlq; do
  echo "--- ApproximateNumberOfMessagesVisible (phase10-$q) ---"
  get_metric AWS/SQS ApproximateNumberOfMessagesVisible QueueName "phase10-$q"
done

echo ""
echo "=== Lambda Notifier Metrics ==="
echo "--- Errors ($FUNCTION) ---"
get_metric AWS/Lambda Errors FunctionName "$FUNCTION"

echo "--- Invocations ($FUNCTION) ---"
get_metric AWS/Lambda Invocations FunctionName "$FUNCTION"

TOPIC_ARN=$(terraform -chdir=terraform/sandboxes/phase10 output -raw orders_topic_arn 2>/dev/null || echo "unknown")

echo ""
echo "=== Console deep links ==="
echo "SNS Topic:    https://$REGION.console.aws.amazon.com/sns/v3/home?region=$REGION#/topic/$TOPIC_ARN"
echo "SQS:          https://$REGION.console.aws.amazon.com/sqs/v3/home?region=$REGION"
echo "Lambda logs:  https://$REGION.console.aws.amazon.com/cloudwatch/home?region=$REGION#logsV2:log-groups/log-group/\$252Faws\$252Flambda\$252F$FUNCTION"
echo "CW Dashboard: https://$REGION.console.aws.amazon.com/cloudwatch/home?region=$REGION#dashboards:name=$DASH_NAME"

echo ""
echo "=========================================="
echo "  Observation complete. Run cleanup:"
echo "  make sandbox-down-phase10"
echo "=========================================="
