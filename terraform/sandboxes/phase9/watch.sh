#!/usr/bin/env bash
# watch.sh — Phase9 X-Ray 観測スクリプト
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
PERIOD=60
SLEEP_SEC=90

echo "=== Phase9 X-Ray 観測 ==="
echo ""

# ── [1] CloudWatch Dashboard 存在スモーク ──────────────────────────────────
echo "── [1] CloudWatch Dashboard スモークテスト ─────────────────────────────"
aws cloudwatch get-dashboard \
  --dashboard-name phase9-xray-sandbox \
  --region "${REGION}" \
  --query 'DashboardName' \
  --output text && echo "  -> Dashboard 存在確認 OK" || echo "  -> Dashboard が見つかりません(要確認)"

echo ""
echo "メトリクス反映待ち: ${SLEEP_SEC}秒 ..."
echo "(CloudWatch Lambda メトリクスは発生から 1-3分 遅延します)"
sleep ${SLEEP_SEC}

END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_TIME=$(date -u -d "10 minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -v-10M +"%Y-%m-%dT%H:%M:%SZ")  # macOS 対応

# ── [2] Lambda Invocations ────────────────────────────────────────────────
echo ""
echo "── [2] Lambda Invocations (過去10分) ──────────────────────────────────"
for FN in phase9-producer phase9-consumer; do
  echo "  ${FN}:"
  aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name Invocations \
    --dimensions Name=FunctionName,Value="${FN}" \
    --start-time "${START_TIME}" \
    --end-time "${END_TIME}" \
    --period ${PERIOD} \
    --statistics Sum \
    --region "${REGION}" \
    --query 'Datapoints[*].[Timestamp,Sum]' \
    --output table
done

# ── [3] Lambda Duration p99 ───────────────────────────────────────────────
echo ""
echo "── [3] Lambda Duration p99 (過去10分) ──────────────────────────────────"
for FN in phase9-producer phase9-consumer; do
  echo "  ${FN}:"
  aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name Duration \
    --dimensions Name=FunctionName,Value="${FN}" \
    --start-time "${START_TIME}" \
    --end-time "${END_TIME}" \
    --period ${PERIOD} \
    --extended-statistics p99 \
    --region "${REGION}" \
    --query 'Datapoints[*].[Timestamp,ExtendedStatistics.p99]' \
    --output table
done

# ── [4] Lambda Errors ─────────────────────────────────────────────────────
echo ""
echo "── [4] Lambda Errors (過去10分) ───────────────────────────────────────"
for FN in phase9-producer phase9-consumer; do
  ERR=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name Errors \
    --dimensions Name=FunctionName,Value="${FN}" \
    --start-time "${START_TIME}" \
    --end-time "${END_TIME}" \
    --period ${PERIOD} \
    --statistics Sum \
    --region "${REGION}" \
    --query 'sum(Datapoints[*].Sum)' \
    --output text 2>/dev/null || echo "N/A")
  echo "  ${FN}: Errors = ${ERR}"
done

# ── [5] SQS キュー深度 (period=300 — SQS キュー系の最小粒度) ─────────────
echo ""
echo "── [5] SQS: phase9-main キュー深度 ────────────────────────────────────"
aws cloudwatch get-metric-statistics \
  --namespace AWS/SQS \
  --metric-name ApproximateNumberOfMessagesVisible \
  --dimensions Name=QueueName,Value=phase9-main \
  --start-time "${START_TIME}" \
  --end-time "${END_TIME}" \
  --period 300 \
  --statistics Maximum \
  --region "${REGION}" \
  --query 'Datapoints[*].[Timestamp,Maximum]' \
  --output table

# ── [6] X-Ray / ServiceLens コンソール ディープリンク ─────────────────────
echo ""
echo "── [6] X-Ray / ServiceLens コンソール ディープリンク ──────────────────"
echo ""
echo "  【Service Map (CloudWatch ServiceLens)】"
echo "  https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#servicelens:map"
echo ""
echo "  【X-Ray Traces】"
echo "  https://console.aws.amazon.com/xray/home?region=${REGION}#/traces"
echo ""
echo "  【X-Ray Service Map】"
echo "  https://console.aws.amazon.com/xray/home?region=${REGION}#/service-map"
echo ""
echo "  【X-Ray Sampling Rules】"
echo "  https://console.aws.amazon.com/xray/home?region=${REGION}#/sampling-rules"

# ── [7] X-Ray トレース件数を CLI で確認 ──────────────────────────────────
echo ""
echo "── [7] X-Ray トレース件数 (過去10分) ──────────────────────────────────"
EPOCH_END=$(date +%s)
EPOCH_START=$((EPOCH_END - 600))
TRACE_COUNT=$(aws xray get-trace-summaries \
  --start-time "${EPOCH_START}" \
  --end-time "${EPOCH_END}" \
  --sampling \
  --region "${REGION}" \
  --query 'length(TraceSummaries)' \
  --output text 2>/dev/null || echo "0")
echo "  過去10分のトレース件数(サンプリング): ${TRACE_COUNT} 件"
echo "  ※ コンソールで Filter: annotation.function = \"producer\" など試してください"

# ── [8] 受け入れ条件チェックリスト ──────────────────────────────────────
echo ""
echo "── [8] 受け入れ条件チェックリスト ──────────────────────────────────────"
echo "  [ ] X-Ray Service Map で phase9-producer → DynamoDB/SQS ノードが可視化"
echo "  [ ] ServiceLens でエラーレートが色付き表示(エラー誘発後)"
echo "  [ ] 個別トレースのタイムラインで DynamoDB/SQS サブセグメントが展開できる"
echo "  [ ] コールドスタートトレースで Init Duration が確認できる"
echo "  [ ] consumer Lambda のトレースが SQS 受信後に独立したトレースとして出ている"
echo "  [ ] CloudWatch Dashboard (phase9-xray-sandbox) にメトリクスが描画されている"

echo ""
echo "============================================================"
echo "観測が完了したら:"
echo "  make sandbox-down-phase9"
echo "を実行してリソースを破棄してください(課金・残留防止)。"
echo "============================================================"
