#!/usr/bin/env bash
# watch.sh — Phase 6 Bedrock metrics observation
# Steps: (0) dashboard smoke check, (1) 観察ポイント解説, (2) 反映待機,
#        (3) メトリクス取得, (4) deep links

set -euo pipefail

SANDBOX_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_CMD="terraform -chdir=${SANDBOX_DIR} output -raw"

# ---------------------------------------------------------------------------
# 識別子の自動取得（env が設定されていれば env を優先）
# ---------------------------------------------------------------------------
echo "=== Phase6 Bedrock watch.sh ==="
echo "[setup] sandbox: ${SANDBOX_DIR}"

echo "[setup] terraform output から識別子を取得中..."
FUNCTION_NAME="${FUNCTION_NAME:-$(${TF_CMD} lambda_function_name 2>/dev/null || echo "bedrock-sandbox-invoker")}"
REGION="${AWS_REGION:-$(${TF_CMD} cloudwatch_dashboard_url 2>/dev/null \
  | grep -oE '[a-z]+-[a-z]+-[0-9]+' | head -1 \
  || echo "us-east-1")}"
MODEL_ID="${MODEL_ID:-anthropic.claude-3-haiku-20240307-v1:0}"
DASHBOARD_NAME="phase6-bedrock"

echo "  Lambda 関数名   : ${FUNCTION_NAME}"
echo "  リージョン      : ${REGION}"
echo "  モデル ID       : ${MODEL_ID}"
echo "  ダッシュボード  : ${DASHBOARD_NAME}"
echo ""

# ---------------------------------------------------------------------------
# [0/5] ダッシュボード存在確認（スモークテスト）
# ---------------------------------------------------------------------------
echo "[0/5] ダッシュボード存在確認..."
DASH_CHECK=$(aws cloudwatch get-dashboard \
  --dashboard-name "${DASHBOARD_NAME}" \
  --region "${REGION}" \
  --query 'DashboardName' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [ "${DASH_CHECK}" = "NOT_FOUND" ]; then
  echo "  WARNING: ダッシュボード '${DASHBOARD_NAME}' が見つかりません。"
  echo "           先に 'make sandbox-up-phase6' を実行してください。"
else
  echo "  OK: ダッシュボード '${DASHBOARD_NAME}' を確認しました"
fi
echo ""

# ---------------------------------------------------------------------------
# [1/5] 観察ポイントの解説
# ---------------------------------------------------------------------------
echo "[1/5] 観察ポイント（このメトリクスがどう動くか）"
echo "----------------------------------------------------------------"
echo "  AWS/Bedrock - InvocationCount  [Sum]"
echo "    load.sh で送信した件数（3件）が 1 分足に積み上がるはず。"
echo "    → 数値が 3 に近ければ全呼び出しが届いている証拠。"
echo ""
echo "  AWS/Bedrock - InvocationLatency [Average ms]"
echo "    モデルが応答を生成するまでの時間。"
echo "    Claude Haiku の短いプロンプトなら 500〜2000 ms 程度が目安。"
echo "    → 異常に高い場合は再試行スロットリングを疑う。"
echo ""
echo "  AWS/Bedrock - InputTokenCount / OutputTokenCount [Sum]"
echo "    実際に課金対象となったトークン数。"
echo "    → InputTokenCount > OutputTokenCount になるのが典型的。"
echo ""
echo "  AWS/Lambda - Duration / Errors / Invocations [Sum]"
echo "    Lambda 自体の実行時間とエラー率。"
echo "    → Errors > 0 なら Lambda のログを確認（PermissionError 等）。"
echo "----------------------------------------------------------------"
echo ""

# ---------------------------------------------------------------------------
# [2/5] メトリクス反映待機（2〜3 分）
# ---------------------------------------------------------------------------
echo "[2/5] Bedrock メトリクス反映を待機中..."
echo "      CloudWatch への反映には 2〜3 分かかります（120 秒待機）。"
echo "      Ctrl+C で中断し、後で手動実行することも可能です。"
for i in $(seq 120 -10 10); do
  printf "\r      残り %3d 秒..." "${i}"
  sleep 10 || true
done
printf "\r      待機完了。                  \n"
echo ""

# 計測ウィンドウ（直近 15 分）
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_TIME=$(date -u -v -15M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -d '-15 minutes' +"%Y-%m-%dT%H:%M:%SZ")
echo "  計測ウィンドウ: ${START_TIME} 〜 ${END_TIME}"
echo ""

# ---------------------------------------------------------------------------
# [3/5] Bedrock メトリクス取得
# ---------------------------------------------------------------------------
echo "[3/5] Bedrock メトリクス取得（period=60s）..."
echo ""

echo "  ── InvocationCount (Sum) ──"
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Bedrock" \
  --metric-name "InvocationCount" \
  --dimensions Name=ModelId,Value="${MODEL_ID}" \
  --start-time "${START_TIME}" \
  --end-time "${END_TIME}" \
  --period 60 \
  --statistics Sum \
  --region "${REGION}" \
  --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Sum:Sum}' \
  --output table || true
echo ""

echo "  ── InvocationLatency (Average ms) ──"
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Bedrock" \
  --metric-name "InvocationLatency" \
  --dimensions Name=ModelId,Value="${MODEL_ID}" \
  --start-time "${START_TIME}" \
  --end-time "${END_TIME}" \
  --period 60 \
  --statistics Average \
  --region "${REGION}" \
  --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Avg_ms:Average}' \
  --output table || true
echo ""

echo "  ── InputTokenCount / OutputTokenCount (Sum) ──"
for METRIC in InputTokenCount OutputTokenCount; do
  echo "    ${METRIC}:"
  aws cloudwatch get-metric-statistics \
    --namespace "AWS/Bedrock" \
    --metric-name "${METRIC}" \
    --dimensions Name=ModelId,Value="${MODEL_ID}" \
    --start-time "${START_TIME}" \
    --end-time "${END_TIME}" \
    --period 60 \
    --statistics Sum \
    --region "${REGION}" \
    --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Sum:Sum}' \
    --output table || true
  echo ""
done

# ---------------------------------------------------------------------------
# [4/5] Lambda メトリクス取得
# ---------------------------------------------------------------------------
echo "[4/5] Lambda メトリクス取得（period=60s）..."
echo ""
for METRIC in Invocations Errors Duration; do
  echo "  ── Lambda ${METRIC} (Sum) ──"
  aws cloudwatch get-metric-statistics \
    --namespace "AWS/Lambda" \
    --metric-name "${METRIC}" \
    --dimensions Name=FunctionName,Value="${FUNCTION_NAME}" \
    --start-time "${START_TIME}" \
    --end-time "${END_TIME}" \
    --period 60 \
    --statistics Sum \
    --region "${REGION}" \
    --query 'sort_by(Datapoints, &Timestamp)[*].{Time:Timestamp,Value:Sum}' \
    --output table || true
  echo ""
done

# ---------------------------------------------------------------------------
# [5/5] コンソール Deep Links
# ---------------------------------------------------------------------------
echo "[5/5] CloudWatch コンソール Deep Links"
echo "================================================================"
DASHBOARD_URL=$(${TF_CMD} cloudwatch_dashboard_url 2>/dev/null \
  || echo "https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${DASHBOARD_NAME}")

echo "  ダッシュボード:"
echo "    ${DASHBOARD_URL}"
echo ""
echo "  Bedrock メトリクス:"
echo "    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#metricsV2:graph=~();namespace=AWS/Bedrock"
echo ""
echo "  Lambda ログ:"
echo "    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:log-groups/log-group/\$252Faws\$252Flambda\$252F${FUNCTION_NAME}"
echo ""
echo "  Bedrock 呼び出しログ:"
echo "    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:log-groups/log-group/\$252Faws\$252Fbedrock\$252Finvocations"
echo "================================================================"
echo ""

# ---------------------------------------------------------------------------
# 終了リマインダー（目立つ警告）
# ---------------------------------------------------------------------------
echo ""
echo "###############################################################"
echo "#                                                             #"
echo "#   観測が終わったら必ず以下を実行してください:               #"
echo "#                                                             #"
echo "#       make sandbox-down-phase6                             #"
echo "#                                                             #"
echo "#   S3 / KMS の課金は destroy するまで継続します。           #"
echo "#                                                             #"
echo "###############################################################"
