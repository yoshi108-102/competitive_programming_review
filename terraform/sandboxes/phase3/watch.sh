#!/usr/bin/env bash
# watch.sh — Phase 3 SQS メトリクス観測
# 使い方: bash watch.sh
# 前提: load.sh 実行後、最低 5 分待ってから実行すること
set -euo pipefail

REGION="ap-northeast-1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIN_QUEUE=$(terraform -chdir="${SCRIPT_DIR}" output -raw main_queue_url | sed 's|.*/||')
DLQ=$(terraform -chdir="${SCRIPT_DIR}" output -raw dlq_url | sed 's|.*/||')
CONSUMER_FN=$(terraform -chdir="${SCRIPT_DIR}" output -raw consumer_name)
DASHBOARD=$(terraform -chdir="${SCRIPT_DIR}" output -raw dashboard_name)
DASHBOARD_URL=$(terraform -chdir="${SCRIPT_DIR}" output -raw dashboard_url)

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START=$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
        date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)

echo "=== Phase 3 SQS 観測レポート ==="
echo "観測時刻(UTC): ${NOW}"
echo ""

# ── (1) ダッシュボード存在確認 (スモークテスト) ──────────────────────────────
echo "[Smoke] CloudWatch ダッシュボード存在確認..."
aws cloudwatch get-dashboard \
  --region "${REGION}" \
  --dashboard-name "${DASHBOARD}" \
  --query 'DashboardName' --output text \
  && echo "  OK: ${DASHBOARD} が存在します" \
  || echo "  WARN: ダッシュボードが見つかりません"
echo ""

# ── (2) メトリクス反映待ち sleep (SQS は 5 分粒度) ──────────────────────────
echo "SQS メトリクス反映待ち (30秒)..."
sleep 30

# ── (3) SQS キュー系メトリクス (--period 300, SQS は 5 分粒度) ──────────────
echo "[SQS Main] ApproximateNumberOfMessagesVisible (過去15分, 5分粒度)"
aws cloudwatch get-metric-statistics \
  --region "${REGION}" \
  --namespace AWS/SQS \
  --metric-name ApproximateNumberOfMessagesVisible \
  --dimensions Name=QueueName,Value="${MAIN_QUEUE}" \
  --start-time "${START}" --end-time "${NOW}" \
  --period 300 \
  --statistics Maximum \
  --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Max:Maximum}' \
  --output table

echo ""
echo "[SQS DLQ] ApproximateNumberOfMessagesVisible (過去15分, 5分粒度)"
aws cloudwatch get-metric-statistics \
  --region "${REGION}" \
  --namespace AWS/SQS \
  --metric-name ApproximateNumberOfMessagesVisible \
  --dimensions Name=QueueName,Value="${DLQ}" \
  --start-time "${START}" --end-time "${NOW}" \
  --period 300 \
  --statistics Maximum \
  --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Max:Maximum}' \
  --output table

echo ""
echo "[SQS Main] NumberOfMessagesSent / Deleted (5分粒度)"
for metric in NumberOfMessagesSent NumberOfMessagesDeleted; do
  echo "  ${metric}:"
  aws cloudwatch get-metric-statistics \
    --region "${REGION}" \
    --namespace AWS/SQS \
    --metric-name "${metric}" \
    --dimensions Name=QueueName,Value="${MAIN_QUEUE}" \
    --start-time "${START}" --end-time "${NOW}" \
    --period 300 --statistics Sum \
    --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Sum:Sum}' \
    --output table
done

# ── Lambda メトリクス (1分粒度) ──────────────────────────────────────────────
echo ""
echo "[Lambda Consumer] Invocations / Errors (1分粒度)"
for metric in Invocations Errors; do
  echo "  ${metric}:"
  aws cloudwatch get-metric-statistics \
    --region "${REGION}" \
    --namespace AWS/Lambda \
    --metric-name "${metric}" \
    --dimensions Name=FunctionName,Value="${CONSUMER_FN}" \
    --start-time "${START}" --end-time "${NOW}" \
    --period 60 --statistics Sum \
    --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Sum:Sum}' \
    --output table
done

echo ""
echo "[Lambda Consumer] Duration p50/p99 (1分粒度)"
for stat in p50 p99; do
  echo "  ${stat}:"
  aws cloudwatch get-metric-statistics \
    --region "${REGION}" \
    --namespace AWS/Lambda \
    --metric-name Duration \
    --dimensions Name=FunctionName,Value="${CONSUMER_FN}" \
    --start-time "${START}" --end-time "${NOW}" \
    --period 60 --statistics "${stat}" \
    --query "sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,${stat}:${stat}}" \
    --output table 2>/dev/null || true
done

# ── コンソール deep link ──────────────────────────────────────────────────────
echo ""
echo "=== コンソール deep link ==="
echo "CloudWatch ダッシュボード:"
echo "  ${DASHBOARD_URL}"
echo ""
echo "SQS メインキュー:"
MAIN_ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${MAIN_QUEUE}" 2>/dev/null || echo "${MAIN_QUEUE}")
echo "  https://ap-northeast-1.console.aws.amazon.com/sqs/v3/home?region=ap-northeast-1#/queues/${MAIN_ENCODED}"
echo ""
echo "SQS DLQ:"
DLQ_ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${DLQ}" 2>/dev/null || echo "${DLQ}")
echo "  https://ap-northeast-1.console.aws.amazon.com/sqs/v3/home?region=ap-northeast-1#/queues/${DLQ_ENCODED}"
echo ""
echo "Lambda Consumer ログ:"
echo "  https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#logsV2:log-groups/log-group/\$252Faws\$252Flambda\$252F${CONSUMER_FN}"

echo ""
echo "==========================================================="
echo "  観測が終わったら必ず sandbox を teardown してください:"
echo "  make sandbox-down-phase3"
echo "  (放置すると SQS・KMS・Lambda の待機コストが積み上がります)"
echo "==========================================================="
