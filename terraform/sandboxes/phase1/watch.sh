#!/usr/bin/env bash
# watch.sh — Phase 1 metric observation (Cognito / API GW / Lambda / DynamoDB)
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
DASHBOARD_NAME="phase1-sandbox"
STAGE="${API_GW_STAGE:-prod}"
# 既定は本番命名規則 (${project_name}-...-${environment} = atcoder-review / prod) に一致。
# 本番を別名でデプロイした場合だけ env で上書きすればよい (無入力で動く)。
API_GW_ID="${API_GW_ID:-atcoder-review-api-prod}"
LAMBDA_FUNCTION_NAMES="${LAMBDA_FUNCTION_NAMES:-atcoder-review-save-user-prod atcoder-review-sync-submissions-prod atcoder-review-get-submissions-prod}"
DYNAMODB_TABLE_NAME="${DYNAMODB_TABLE_NAME:-atcoder-review-submissions-prod}"
# Cognito の UserPool ディメンションは Pool ID。本番 output から取得し、無ければ名前にフォールバック。
PROD_TF="$(cd "$(dirname "$0")/../../.." && pwd)/terraform"
USER_POOL_ID="${USER_POOL_ID:-$(terraform -chdir="$PROD_TF" output -raw cognito_user_pool_id 2>/dev/null || echo atcoder-review-prod)}"

echo "INFO: CloudWatch メトリクスの反映には 1〜5 分かかります。"
echo "INFO: SQS: load.sh 実行後 5 分待ってください (--period 300)"
echo "INFO: EventBridge: rate(1 minute) は初回発火まで最大 60 秒待ってください"

# --- [0] Dashboard smoke check ---
echo ""
echo "=== [0] Dashboard 存在確認 ==="
aws cloudwatch get-dashboard \
  --dashboard-name "${DASHBOARD_NAME}" \
  --region "${REGION}" \
  --query 'DashboardName' --output text
echo "Dashboard OK"

# Metrics can take up to 5 minutes to appear after load.sh.
echo ""
echo "メトリクス反映まで最大 5 分かかります。60 秒待機します..."
sleep 60

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FIVE_MIN_AGO=$(date -u -v-5M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -d '5 minutes ago' +"%Y-%m-%dT%H:%M:%SZ")

echo ""
echo "=== [1] API Gateway: 5XX / 4XX / Count / Latency ==="
for metric in 5XXError 4XXError Count Latency; do
  echo "--- ${metric} ---"
  aws cloudwatch get-metric-statistics \
    --namespace "AWS/ApiGateway" \
    --metric-name "${metric}" \
    --dimensions \
      "Name=ApiName,Value=${API_GW_ID}" \
      "Name=Stage,Value=${STAGE}" \
    --start-time "${FIVE_MIN_AGO}" \
    --end-time "${NOW}" \
    --period 60 \
    --statistics Sum Average Maximum \
    --region "${REGION}" \
    --output table
done

echo ""
echo "=== [2] Lambda: Invocations / Errors / Duration / Throttles ==="
for fn in ${LAMBDA_FUNCTION_NAMES}; do
  echo "--- Lambda: ${fn} ---"
  for metric in Invocations Errors Duration Throttles ConcurrentExecutions; do
    aws cloudwatch get-metric-statistics \
      --namespace "AWS/Lambda" \
      --metric-name "${metric}" \
      --dimensions "Name=FunctionName,Value=${fn}" \
      --start-time "${FIVE_MIN_AGO}" \
      --end-time "${NOW}" \
      --period 60 \
      --statistics Sum Average Maximum \
      --region "${REGION}" \
      --output table 2>/dev/null || true
  done
done

echo ""
echo "=== [3] DynamoDB: ConsumedReadCapacityUnits / ConsumedWriteCapacityUnits / SystemErrors ==="
for metric in ConsumedReadCapacityUnits ConsumedWriteCapacityUnits SystemErrors UserErrors SuccessfulRequestLatency; do
  aws cloudwatch get-metric-statistics \
    --namespace "AWS/DynamoDB" \
    --metric-name "${metric}" \
    --dimensions "Name=TableName,Value=${DYNAMODB_TABLE_NAME}" \
    --start-time "${FIVE_MIN_AGO}" \
    --end-time "${NOW}" \
    --period 60 \
    --statistics Sum Average Maximum \
    --region "${REGION}" \
    --output table 2>/dev/null || true
done

echo ""
echo "=== [4] Cognito: SignInSuccesses / TokenRefreshSuccesses ==="
for metric in SignInSuccesses TokenRefreshSuccesses; do
  aws cloudwatch get-metric-statistics \
    --namespace "AWS/Cognito" \
    --metric-name "${metric}" \
    --dimensions "Name=UserPool,Value=${USER_POOL_ID}" \
    --start-time "${FIVE_MIN_AGO}" \
    --end-time "${NOW}" \
    --period 60 \
    --statistics Sum \
    --region "${REGION}" \
    --output table 2>/dev/null \
    || echo "${metric}: no data (Advanced Security may not be enabled)"
done

echo ""
echo "=== Console Deep Links ==="
BASE="https://${REGION}.console.aws.amazon.com"
echo "CloudWatch Dashboard : ${BASE}/cloudwatch/home?region=${REGION}#dashboards:name=${DASHBOARD_NAME}"
echo "API GW Metrics       : ${BASE}/apigateway/main/apis/${API_GW_ID}/stages/${STAGE}/metrics"
echo "Lambda Monitoring    : ${BASE}/lambda/home?region=${REGION}#/functions"
echo "DynamoDB Metrics     : ${BASE}/dynamodb/home?region=${REGION}#tables:selected=${DYNAMODB_TABLE_NAME};tab=monitoring"
echo "Log Insights         : ${BASE}/cloudwatch/home?region=${REGION}#logsV2:logs-insights"

echo ""
echo "=========================================="
echo "観測が終わったら必ず: make sandbox-down-phase1"
echo "=========================================="
