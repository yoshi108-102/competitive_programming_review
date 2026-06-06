#!/usr/bin/env bash
# watch.sh — Phase9 X-Ray 観測スクリプト
# 無入力で動く: 識別子は terraform output から自動取得
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
PERIOD=60
SLEEP_SEC=90
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}"

echo "================================================================"
echo "  Phase9 X-Ray 観測ダッシュボード"
echo "================================================================"
echo ""
echo "  サービス : X-Ray / ServiceLens"
echo "  リージョン: ${REGION}"
echo ""

# ── terraform output から識別子を自動取得 ─────────────────────────────────
echo ">>> terraform output から識別子を取得中..."

PRODUCER_FN="${PRODUCER_FN:-$(terraform -chdir="${TF_DIR}" output -raw producer_function_name)}"
CONSUMER_FN="${CONSUMER_FN:-$(terraform -chdir="${TF_DIR}" output -raw consumer_function_name)}"
DASHBOARD_URL="${DASHBOARD_URL:-$(terraform -chdir="${TF_DIR}" output -raw dashboard_url)}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text --region "${REGION}" 2>/dev/null || echo "UNKNOWN")

DASHBOARD_NAME="phase9-xray-sandbox"
SQS_QUEUE_NAME="phase9-main"

echo ""
echo "  PRODUCER_FN   : ${PRODUCER_FN}"
echo "  CONSUMER_FN   : ${CONSUMER_FN}"
echo "  DASHBOARD     : ${DASHBOARD_NAME}"
echo "  AWS Account   : ${ACCOUNT}"
echo ""

# ── [1] CloudWatch Dashboard 存在スモーク ──────────────────────────────────
echo "── [1] CloudWatch Dashboard スモークテスト ──────────────────────────────"
echo ""
echo "  確認対象: ${DASHBOARD_NAME}"
aws cloudwatch get-dashboard \
  --dashboard-name "${DASHBOARD_NAME}" \
  --region "${REGION}" \
  --query 'DashboardName' \
  --output text 2>/dev/null \
  && echo "  -> Dashboard 存在 OK" \
  || echo "  -> Dashboard が見つかりません (terraform apply 済みか確認)"
echo ""

# ── [1.5] 観察ポイント解説 ────────────────────────────────────────────────
echo "── 【観察ポイント】 このメトリクスがこう動くはず ────────────────────────"
echo ""
echo "  (A) Invocations"
echo "      producer: load.sh の正常系20回 + Lambda直接invoke1回 = 21回前後"
echo "      consumer: SQS 経由で非同期起動 = SQS送信5回 + 正常系から来たメッセージ"
echo ""
echo "  (B) Duration p99"
echo "      コールドスタートがあるので最初のリクエストは 300-800ms 台になりやすい"
echo "      ウォームアップ後は数十ms 台に落ちるはず"
echo ""
echo "  (C) Errors"
echo "      producer: エラー誘発シナリオ(5件)分が計上される"
echo "      consumer: 正常処理なら 0 のはず (DLQ に流れていたら要確認)"
echo ""
echo "  (D) X-Ray Service Map"
echo "      phase9-producer → DynamoDB / phase9-producer → SQS"
echo "      SQS → phase9-consumer → DynamoDB のノード連鎖が可視化されるはず"
echo ""
echo "  (E) X-Ray トレース"
echo "      エラー誘発分は赤/黄色でハイライトされる"
echo "      コールドスタートトレースには 'Init Duration' サブセグメントが出る"
echo ""
echo "  反映遅延: Lambda メトリクス 1-3分 / X-Ray トレース 30-120秒"
echo ""

# ── メトリクス反映待ち ────────────────────────────────────────────────────
echo ">>> メトリクス反映待ち: ${SLEEP_SEC} 秒 ..."
echo "    (CloudWatch Lambda メトリクスは発生から 1-3分 遅延します)"
sleep "${SLEEP_SEC}"
echo ""

# ── 時刻計算 (macOS / Linux 両対応) ─────────────────────────────────────
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_TIME=$(date -u -d "10 minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -v-10M +"%Y-%m-%dT%H:%M:%SZ")

echo "  計測ウィンドウ: ${START_TIME} 〜 ${END_TIME}"
echo ""

# ── [2] Lambda Invocations ─────────────────────────────────────────────────
echo "── [2] Lambda Invocations (過去10分) ────────────────────────────────────"
echo "    期待値: producer=21前後, consumer=SQS送信数前後"
echo ""
for FN in "${PRODUCER_FN}" "${CONSUMER_FN}"; do
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
    --query 'sort_by(Datapoints, &Timestamp)[*].[Timestamp,Sum]' \
    --output table 2>/dev/null || echo "    (データなし — まだ反映されていない可能性あり)"
  echo ""
done

# ── [3] Lambda Duration p99 ───────────────────────────────────────────────
echo "── [3] Lambda Duration p99 ms (過去10分) ────────────────────────────────"
echo "    期待値: コールドスタートで 300-800ms, ウォーム後は数十ms 台"
echo ""
for FN in "${PRODUCER_FN}" "${CONSUMER_FN}"; do
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
    --query 'sort_by(Datapoints, &Timestamp)[*].[Timestamp,ExtendedStatistics.p99]' \
    --output table 2>/dev/null || echo "    (データなし)"
  echo ""
done

# ── [4] Lambda Errors ─────────────────────────────────────────────────────
echo "── [4] Lambda Errors (過去10分) ─────────────────────────────────────────"
echo "    期待値: producer=5前後(エラー誘発分), consumer=0"
echo ""
for FN in "${PRODUCER_FN}" "${CONSUMER_FN}"; do
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
echo ""

# ── [5] SQS キュー深度 (period=300 — SQS の最小粒度) ─────────────────────
echo "── [5] SQS: ${SQS_QUEUE_NAME} キュー深度 (period=300s) ─────────────────"
echo "    期待値: consumer が処理済みなら 0 に近い / DLQ に流れていれば要調査"
echo ""
aws cloudwatch get-metric-statistics \
  --namespace AWS/SQS \
  --metric-name ApproximateNumberOfMessagesVisible \
  --dimensions Name=QueueName,Value="${SQS_QUEUE_NAME}" \
  --start-time "${START_TIME}" \
  --end-time "${END_TIME}" \
  --period 300 \
  --statistics Maximum \
  --region "${REGION}" \
  --query 'sort_by(Datapoints, &Timestamp)[*].[Timestamp,Maximum]' \
  --output table 2>/dev/null || echo "  (データなし — SQS メトリクスは 5分粒度のため遅延することがある)"
echo ""

# ── [6] X-Ray トレース件数 ────────────────────────────────────────────────
echo "── [6] X-Ray トレース件数 (過去10分, サンプリング) ──────────────────────"
echo "    期待値: 数件〜30件前後 (サンプリングルール fixed_rate=10%)"
echo ""
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
echo ""
echo "  エラートレースのみ絞り込む場合:"
echo "  Filter 式 -> responsetime > 1 または error = true"
echo "  コンソール Filter: annotation.aws:function_name = \"${PRODUCER_FN}\""
echo ""

# ── [7] X-Ray / ServiceLens コンソール ディープリンク ─────────────────────
echo "── [7] コンソール ディープリンク ────────────────────────────────────────"
echo ""
echo "  【CloudWatch Dashboard】"
echo "  ${DASHBOARD_URL}"
echo ""
echo "  【ServiceLens Service Map】"
echo "  https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#servicelens:map"
echo ""
echo "  【X-Ray Traces】"
echo "  https://${REGION}.console.aws.amazon.com/xray/home?region=${REGION}#/traces"
echo ""
echo "  【X-Ray Service Map】"
echo "  https://${REGION}.console.aws.amazon.com/xray/home?region=${REGION}#/service-map"
echo ""
echo "  【X-Ray Sampling Rules (fixed_rate=10% を確認)】"
echo "  https://${REGION}.console.aws.amazon.com/xray/home?region=${REGION}#/sampling-rules"
echo ""

# ── [8] 受け入れ条件チェックリスト ──────────────────────────────────────
echo "── [8] 受け入れ条件チェックリスト ──────────────────────────────────────"
echo ""
echo "  [ ] X-Ray Service Map で ${PRODUCER_FN} → DynamoDB/SQS ノードが可視化"
echo "  [ ] ServiceLens でエラーレートが色付き表示 (エラー誘発後)"
echo "  [ ] 個別トレースのタイムラインで DynamoDB/SQS サブセグメントが展開できる"
echo "  [ ] コールドスタートトレースで Init Duration が確認できる"
echo "  [ ] ${CONSUMER_FN} のトレースが SQS 受信後に独立トレースとして出ている"
echo "  [ ] CloudWatch Dashboard (${DASHBOARD_NAME}) にメトリクスが描画されている"
echo "  [ ] X-Ray 暗号化設定で KMS CMK (alias/phase9-xray) が有効"
echo ""

echo "================================================================"
echo ""
echo "  !!! 観測が終わったら必ず以下を実行してください !!!"
echo ""
echo "      make sandbox-down-phase9"
echo ""
echo "  実行しないとリソースが残り続け、課金・セキュリティリスクになります。"
echo ""
echo "================================================================"
