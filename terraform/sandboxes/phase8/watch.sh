#!/usr/bin/env bash
# watch.sh — Phase8 Step Functions metrics observer
set -euo pipefail

echo "INFO: CloudWatch メトリクスの反映には 1〜5 分かかります。"
echo "INFO: SQS: load.sh 実行後 5 分待ってください (--period 300)"
echo "INFO: EventBridge: rate(1 minute) は初回発火まで最大 60 秒待ってください"

REGION="${AWS_REGION:-ap-northeast-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SFN_ARN="arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:phase8-order-saga"
DASHBOARD_NAME="Phase8-StepFunctions"

echo ""
echo "=== [0] Dashboard smoke test ==="
aws cloudwatch get-dashboard \
  --dashboard-name "$DASHBOARD_NAME" \
  --region "$REGION" \
  --query "DashboardName" \
  --output text \
  | grep -q "$DASHBOARD_NAME" \
  && echo "OK: dashboard exists" \
  || { echo "ERROR: dashboard not found — did you run terraform apply?"; exit 1; }

echo ""
echo "=== [1] メトリクス反映待ち (Step Functions は ~2-3 分遅延) ==="
echo "    60 秒 sleep します..."
sleep 60
echo "    さらに 60 秒..."
sleep 60
echo "    反映待ち完了。以下のメトリクスを取得します。"

# Time window: last 10 minutes, 60s period
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# macOS vs Linux portable date arithmetic
START_TIME=$(date -u -v-10M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -d "-10 minutes" +"%Y-%m-%dT%H:%M:%SZ")

echo ""
echo "=== [2] ExecutionsStarted / Succeeded / Failed / TimedOut ==="
for METRIC in ExecutionsStarted ExecutionsSucceeded ExecutionsFailed ExecutionsTimedOut; do
  VALUE=$(aws cloudwatch get-metric-statistics \
    --namespace "AWS/States" \
    --metric-name "$METRIC" \
    --dimensions "Name=StateMachineArn,Value=${SFN_ARN}" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --period 60 \
    --statistics Sum \
    --region "$REGION" \
    --query "sort_by(Datapoints, &Timestamp)[*].Sum" \
    --output json | python3 -c "import json,sys; data=json.load(sys.stdin); print(sum(data) if data else 0)")
  printf "  %-30s %s\n" "${METRIC}:" "$VALUE"
done

echo ""
echo "=== [3] ExecutionTime P99 (ms) ==="
aws cloudwatch get-metric-statistics \
  --namespace "AWS/States" \
  --metric-name "ExecutionTime" \
  --dimensions "Name=StateMachineArn,Value=${SFN_ARN}" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 300 \
  --extended-statistics p99 \
  --region "$REGION" \
  --query "Datapoints[*].{time:Timestamp,p99:ExtendedStatistics.p99}" \
  --output table

echo ""
echo "=== [4] Lambda Errors 集計 ==="
for FN in validate-order charge-payment update-inventory notify-customer compensate-order; do
  ERR=$(aws cloudwatch get-metric-statistics \
    --namespace "AWS/Lambda" \
    --metric-name "Errors" \
    --dimensions "Name=FunctionName,Value=phase8-${FN}" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --period 300 \
    --statistics Sum \
    --region "$REGION" \
    --query "Datapoints[0].Sum || \`0\`" \
    --output text)
  printf "  phase8-%-25s Errors: %s\n" "${FN}:" "$ERR"
done

echo ""
echo "=== [5] CloudWatch Logs — SFN 実行失敗ログ (直近10分) ==="
START_MS=$(( $(date +%s) * 1000 - 600000 ))
aws logs filter-log-events \
  --log-group-name "/aws/states/phase8-order-saga" \
  --filter-pattern "ExecutionFailed" \
  --start-time "$START_MS" \
  --region "$REGION" \
  --query "events[*].message" \
  --output text \
  | head -20 \
  || echo "(no ExecutionFailed events in log group)"

echo ""
echo "=== [6] Console Deep Links ==="
SM_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${SFN_ARN}'))")
echo "  State Machine:"
echo "  https://${REGION}.console.aws.amazon.com/states/home?region=${REGION}#/statemachines/view/${SM_ENCODED}"
echo ""
echo "  CloudWatch Dashboard:"
echo "  https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${DASHBOARD_NAME}"
echo ""
echo "  X-Ray Service Map:"
echo "  https://${REGION}.console.aws.amazon.com/xray/home?region=${REGION}#/service-map"
echo ""
echo "=== [7] Execution History (直近 20 件) ==="
aws stepfunctions list-executions \
  --state-machine-arn "$SFN_ARN" \
  --region "$REGION" \
  --max-results 20 \
  --query "executions[*].{Name:name,Status:status,Started:startDate}" \
  --output table

echo ""
echo "==================================================="
echo " 観測が終わったら必ず実行:"
echo "   make sandbox-down-phase8"
echo " (放置すると Step Functions 実行履歴・KMS・CloudWatch Logs で課金継続)"
echo "==================================================="
