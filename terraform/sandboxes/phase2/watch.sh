#!/usr/bin/env bash
set -euo pipefail

# ── 識別子の自動取得（env があれば env を優先）────────────────────────────────
SANDBOX_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_CMD="terraform -chdir=${SANDBOX_DIR}"

REGION=${AWS_DEFAULT_REGION:-$(${TF_CMD} output -raw aws_region 2>/dev/null || echo "ap-northeast-1")}
BUCKET=${PHASE2_BUCKET:-$(${TF_CMD} output -raw main_bucket_name)}
FUNC=${PHASE2_LAMBDA:-$(${TF_CMD} output -raw lambda_function_name)}
DASHBOARD=${PHASE2_DASHBOARD:-$(${TF_CMD} output -raw dashboard_name 2>/dev/null || echo "Phase2-S3")}

NOW=$(date -u +%FT%TZ)
START=$(date -u -d '15 minutes ago' +%FT%TZ 2>/dev/null \
  || date -u -v-15M +%FT%TZ)  # macOS 互換
YESTERDAY=$(date -u -d '2 days ago' +%FT%TZ 2>/dev/null \
  || date -u -v-2d +%FT%TZ)

echo "============================================================"
echo "  Phase 2 watch.sh — CloudWatch 観測スナップショット"
echo "============================================================"
echo "  バケット  : $BUCKET"
echo "  Lambda    : $FUNC"
echo "  Dashboard : $DASHBOARD"
echo "  観測時刻  : $NOW"
echo "  集計開始  : $START"
echo ""

# ── [0] ダッシュボード存在スモーク ───────────────────────────────────────────
echo "--- [0] Dashboard smoke check ---"
aws cloudwatch get-dashboard \
  --dashboard-name "$DASHBOARD" \
  --region "$REGION" \
  --query 'DashboardName' --output text 2>/dev/null \
  && echo "    [OK] Dashboard '$DASHBOARD' が存在します" \
  || echo "    [WARN] Dashboard が見つかりません (terraform apply 済か確認)"
echo ""

# ── 観察ポイントの明示 ────────────────────────────────────────────────────────
echo "============================================================"
echo "  観察ポイント（このスクリプトで何を見るか）"
echo ""
echo "  [1] Lambda Invocations — load.sh の PutObject 1 件ごとに"
echo "      S3 ObjectCreated イベントが発火し Lambda が呼ばれる。"
echo "      → 期待値: PutObject 31 件分 ≒ 31 invocations"
echo "      → 反映: 即時（1-2 分で出現）"
echo ""
echo "  [2] Lambda Errors — 異常終了があれば Errors > 0 になる。"
echo "      → 期待値: 0（正常なら Errors = 0）"
echo ""
echo "  [3] S3 AllRequests — Put + Get + その他すべてを合算。"
echo "      → 期待値: ~42 件以上（Put 31 + Get 10 + 404 1 + Presign curl 1）"
echo "      → 反映: ~1-2 分（S3 リクエストメトリクスフィルタ）"
echo ""
echo "  [4] S3 PutRequests — Put に絞ったカウント。"
echo "      → 期待値: ~31 件"
echo ""
echo "  [5] BucketSizeBytes — 日次集計。当日は 0 のことが多い。"
echo "      → 翌日に再確認推奨"
echo "============================================================"
echo ""

# ── Lambda 反映待ち ───────────────────────────────────────────────────────────
echo "NOTE: Lambda メトリクスは通常 1-2 分で反映されます。"
echo "      load.sh 直後に実行した場合は 90 秒待機します..."
echo ""
sleep 90
echo "    [待機完了] メトリクスを取得します"
echo ""

# ── [1] Lambda Invocations ────────────────────────────────────────────────────
echo "--- [1] Lambda Invocations (1 min 粒度) ---"
echo "    期待: load.sh の PutObject 件数ぶん (≒ 31) が計上される"
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Lambda" \
  --metric-name "Invocations" \
  --dimensions Name=FunctionName,Value="$FUNC" \
  --start-time "$START" \
  --end-time "$NOW" \
  --period 60 \
  --statistics Sum \
  --region "$REGION" \
  --output table || true
echo ""

# ── [2] Lambda Errors ────────────────────────────────────────────────────────
echo "--- [2] Lambda Errors (1 min 粒度) ---"
echo "    期待: 0（エラーがあれば Lambda ハンドラかポリシーを確認）"
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Lambda" \
  --metric-name "Errors" \
  --dimensions Name=FunctionName,Value="$FUNC" \
  --start-time "$START" \
  --end-time "$NOW" \
  --period 60 \
  --statistics Sum \
  --region "$REGION" \
  --output table || true
echo ""

# ── [3] S3 AllRequests ────────────────────────────────────────────────────────
echo "--- [3] S3 AllRequests (1 min 粒度) ---"
echo "    期待: ~42 件以上（Put 31 + Get 10 + 404 1 + Presign curl 1）"
echo "    NOTE: S3 リクエストメトリクスはさらに 1-2 分遅延することがあります"
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
  --output table || true
echo ""

# ── [4] S3 PutRequests ───────────────────────────────────────────────────────
echo "--- [4] S3 PutRequests (1 min 粒度) ---"
echo "    期待: ~31 件（小オブジェクト 30 + 大オブジェクト 1）"
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
  --output table || true
echo ""

# ── [5] BucketSizeBytes（日次・遅延大）───────────────────────────────────────
echo "--- [5] BucketSizeBytes (日次・period=86400) ---"
echo "    期待: 当日はまだ 0 のことが多い。翌日に値が出る。"
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
  --output table || true
echo ""

# ── [6] 最新 Lambda ログ ─────────────────────────────────────────────────────
echo "--- [6] Lambda 最新ログ (直近 20 件) ---"
LOG_GROUP="/aws/lambda/$FUNC"
STREAM=$(aws logs describe-log-streams \
  --log-group-name "$LOG_GROUP" \
  --order-by LastEventTime \
  --descending \
  --max-items 1 \
  --query 'logStreams[0].logStreamName' \
  --output text \
  --region "$REGION" 2>/dev/null || echo "")
if [ -n "$STREAM" ] && [ "$STREAM" != "None" ]; then
  aws logs get-log-events \
    --log-group-name "$LOG_GROUP" \
    --log-stream-name "$STREAM" \
    --limit 20 \
    --region "$REGION" \
    --query 'events[*].message' \
    --output text || true
else
  echo "    [SKIP] ログストリームが見つかりません（まだ Lambda が呼ばれていないか確認）"
fi
echo ""

# ── コンソール Deep Link ──────────────────────────────────────────────────────
echo "============================================================"
echo "  コンソール Deep Link"
echo ""
echo "  CloudWatch Dashboard:"
echo "    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${DASHBOARD}"
echo ""
echo "  S3 バケット (Metrics タブ):"
echo "    https://s3.console.aws.amazon.com/s3/buckets/${BUCKET}?region=${REGION}&tab=metrics"
echo ""
echo "  Lambda ログ (CloudWatch Logs):"
# URL エンコード: / → %252F（コンソール URL の仕様）
ENCODED_LOG_GROUP=$(echo "/aws/lambda/$FUNC" | sed 's|/|%252F|g')
echo "    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:log-groups/log-group/${ENCODED_LOG_GROUP}"
echo "============================================================"
echo ""
echo "############################################################"
echo "#                                                          #"
echo "#  観測が終わったら必ず以下を実行してください:              #"
echo "#                                                          #"
echo "#       make sandbox-down-phase2                          #"
echo "#                                                          #"
echo "#  （忘れると S3 / Lambda / KMS の課金が継続します）       #"
echo "#                                                          #"
echo "############################################################"
