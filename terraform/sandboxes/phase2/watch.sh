#!/usr/bin/env bash
set -euo pipefail

REGION=${AWS_DEFAULT_REGION:-ap-northeast-1}
BUCKET=$(terraform -chdir="$(dirname "$0")" output -raw main_bucket_name)
FUNC=$(terraform -chdir="$(dirname "$0")" output -raw lambda_function_name)
NOW=$(date -u +%FT%TZ)
START=$(date -u -d '15 minutes ago' +%FT%TZ 2>/dev/null \
  || date -u -v-15M +%FT%TZ) # macOS 互換

echo "=== Phase2 CloudWatch 観測 ==="
echo "観測時刻: $NOW"
echo "バケット: $BUCKET / Lambda: $FUNC"
echo ""

# ── 0) ダッシュボード存在スモーク ─────────────────────────────────────────────
echo "--- [0] Dashboard smoke check ---"
aws cloudwatch get-dashboard \
  --dashboard-name Phase2-S3 \
  --region "$REGION" \
  --query 'DashboardName' --output text \
  && echo "[OK] Dashboard exists" || echo "[WARN] Dashboard not found"
echo ""

# ── 1) S3 AllRequests (period=60s, メトリクスフィルタ有効後 ~1min 遅延) ──────
echo "--- [1] S3 AllRequests (1min 粒度) ---"
echo "NOTE: load.sh 実行直後は反映に最大 1-2 分かかります"
sleep 90
aws cloudwatch get-metric-statistics \
  --namespace "AWS/S3" \
  --metric-name "AllRequests" \
  --dimensions \
  Name=BucketName,Value="$BUCKET" \
  Name=FilterId,Value=AllRequests \
  --start-time "$START" \
  --end-time "$NOW" \
  --period 60 \
  --statistics Sum \
  --region "$REGION" \
  --output table
echo ""

# ── 2) S3 PutRequests ────────────────────────────────────────────────────────
echo "--- [2] S3 PutRequests ---"
aws cloudwatch get-metric-statistics \
  --namespace "AWS/S3" \
  --metric-name "PutRequests" \
  --dimensions \
  Name=BucketName,Value="$BUCKET" \
  Name=FilterId,Value=AllRequests \
  --start-time "$START" \
  --end-time "$NOW" \
  --period 60 \
  --statistics Sum \
  --region "$REGION" \
  --output table
echo ""

# ── 3) Lambda Invocations & Errors ──────────────────────────────────────────
echo "--- [3] Lambda Invocations ---"
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Lambda" \
  --metric-name "Invocations" \
  --dimensions Name=FunctionName,Value="$FUNC" \
  --start-time "$START" \
  --end-time "$NOW" \
  --period 60 \
  --statistics Sum \
  --region "$REGION" \
  --output table

echo "--- [3b] Lambda Errors ---"
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Lambda" \
  --metric-name "Errors" \
  --dimensions Name=FunctionName,Value="$FUNC" \
  --start-time "$START" \
  --end-time "$NOW" \
  --period 60 \
  --statistics Sum \
  --region "$REGION" \
  --output table
echo ""

# ── 4) 最新 Lambda ログ ──────────────────────────────────────────────────────
echo "--- [4] Lambda 最新ログ (直近 20 件) ---"
LOG_GROUP="/aws/lambda/$FUNC"
STREAM=$(aws logs describe-log-streams \
  --log-group-name "$LOG_GROUP" \
  --order-by LastEventTime \
  --descending \
  --max-items 1 \
  --query 'logStreams[0].logStreamName' \
  --output text \
  --region "$REGION")
aws logs get-log-events \
  --log-group-name "$LOG_GROUP" \
  --log-stream-name "$STREAM" \
  --limit 20 \
  --region "$REGION" \
  --query 'events[*].message' \
  --output text
echo ""

# ── 5) BucketSizeBytes (日次なので今日はまだ出ないことが多い) ────────────────
echo "--- [5] BucketSizeBytes (日次・遅延大) ---"
echo "NOTE: オブジェクト投入当日はまだ 0 のことが多い。翌日に確認を推奨。"
YESTERDAY=$(date -u -d '2 days ago' +%FT%TZ 2>/dev/null \
  || date -u -v-2d +%FT%TZ)
aws cloudwatch get-metric-statistics \
  --namespace "AWS/S3" \
  --metric-name "BucketSizeBytes" \
  --dimensions \
  Name=BucketName,Value="$BUCKET" \
  Name=StorageType,Value=StandardStorage \
  --start-time "$YESTERDAY" \
  --end-time "$NOW" \
  --period 86400 \
  --statistics Average \
  --region "$REGION" \
  --output table
echo ""

# ── コンソール Deep Link ──────────────────────────────────────────────────────
echo "=== コンソール Deep Link ==="
echo "CloudWatch Dashboard :"
echo "  https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=Phase2-S3"
echo "S3 バケット :"
echo "  https://s3.console.aws.amazon.com/s3/buckets/${BUCKET}?region=${REGION}&tab=metrics"
echo "Lambda ログ :"
echo "  https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:log-groups/log-group/\$252Faws\$252Flambda\$252F${FUNC}"
echo ""
echo "=========================================================="
echo "観測が終わったら: make sandbox-down-phase2  を忘れずに！"
echo "=========================================================="
