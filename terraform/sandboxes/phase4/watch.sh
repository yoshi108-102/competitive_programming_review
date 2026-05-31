#!/usr/bin/env bash
# watch.sh — Phase 4 観測スクリプト
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-1}"
NAMESPACE="Phase4/Lambda"
STD_NAMESPACE="AWS/Lambda"
PRODUCER="phase4-producer"
CONSUMER="phase4-consumer"

echo ""
echo "=== [1] ダッシュボード存在スモーク ==="
aws cloudwatch get-dashboard \
  --dashboard-name "phase4-overview" \
  --region "${REGION}" \
  --query 'DashboardName' \
  --output text && echo "dashboard OK" || echo "dashboard not found"

# メトリクスは数分遅延するため待機
echo ""
echo "メトリクスは最大 2〜3 分遅延します。load.sh 実行後に待ってから watch.sh を実行してください。"
echo "(高解像度メトリクスなら 1 分以内だが、今回は標準解像度=60s)"
echo ""
sleep 30

START=$(date -u -v-10M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '10 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')
END=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
PERIOD=60

echo "=== [2] Lambda 標準メトリクス: Invocations / Errors (過去 10 分) ==="
for FN in "${PRODUCER}" "${CONSUMER}"; do
  for METRIC in Invocations Errors Duration Throttles; do
    STAT="Sum"
    [[ "${METRIC}" == "Duration" ]] && STAT="p99"
    echo "--- ${FN} / ${METRIC} (${STAT}) ---"
    aws cloudwatch get-metric-statistics \
      --namespace "${STD_NAMESPACE}" \
      --metric-name "${METRIC}" \
      --dimensions Name=FunctionName,Value="${FN}" \
      --start-time "${START}" \
      --end-time "${END}" \
      --period "${PERIOD}" \
      --statistics "${STAT}" \
      --region "${REGION}" \
      --output table 2>/dev/null || echo "(データなし)"
  done
done

echo ""
echo "=== [3] カスタムメトリクス: Phase4/Lambda ==="
for METRIC in ItemsWritten ProducerErrorCount ConsumerErrorCount; do
  echo "--- ${METRIC} ---"
  aws cloudwatch get-metric-statistics \
    --namespace "${NAMESPACE}" \
    --metric-name "${METRIC}" \
    --start-time "${START}" \
    --end-time "${END}" \
    --period "${PERIOD}" \
    --statistics Sum \
    --region "${REGION}" \
    --output table 2>/dev/null || echo "(データなし)"
done

echo ""
echo "=== [4] Alarm 状態確認 ==="
aws cloudwatch describe-alarms \
  --alarm-name-prefix "phase4-" \
  --region "${REGION}" \
  --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue,Reason:StateReason}' \
  --output table

aws cloudwatch describe-alarms \
  --alarm-types CompositeAlarm \
  --alarm-name-prefix "phase4-" \
  --region "${REGION}" \
  --query 'CompositeAlarms[*].{Name:AlarmName,State:StateValue}' \
  --output table

echo ""
echo "=== [5] Logs Insights クエリ(エラーログ抽出) ==="
QUERY_ID=$(aws logs start-query \
  --log-group-names "/aws/lambda/${PRODUCER}" "/aws/lambda/${CONSUMER}" \
  --start-time "$(date -v-10M +%s 2>/dev/null || date -d '10 minutes ago' +%s)" \
  --end-time "$(date +%s)" \
  --query-string 'fields @timestamp, @message | filter @message like /ERROR/ | sort @timestamp desc | limit 20' \
  --region "${REGION}" \
  --query 'queryId' --output text)

echo "  Query ID: ${QUERY_ID} (30 秒後に結果取得)..."
sleep 30
aws logs get-query-results \
  --query-id "${QUERY_ID}" \
  --region "${REGION}" \
  --query 'results' \
  --output json

echo ""
echo "=== [6] コンソール Deep Link ==="
echo "  Dashboard:    https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=phase4-overview"
echo "  Log Insights: https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:logs-insights"
echo "  Alarms:       https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#alarmsV2:"
echo "  Metrics:      https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#metricsV2:graph=~()"

echo ""
echo "========================================================"
echo "観測が終わったら: make sandbox-down-phase4  を忘れずに！"
echo "========================================================"
