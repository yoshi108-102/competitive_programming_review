#!/usr/bin/env bash
# watch.sh — Phase 4 CloudWatch 観測スクリプト
# 無入力で動作: 識別子は terraform output から自動取得
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-1}"
NAMESPACE="Phase4/Lambda"
STD_NAMESPACE="AWS/Lambda"

TF_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "============================================================"
echo "  Phase 4 CloudWatch サンドボックス — 観測ダッシュボード"
echo "============================================================"
echo ""
echo "[事前] terraform output から識別子を取得中..."

PRODUCER="${PRODUCER_FUNCTION:-$(terraform -chdir="${TF_DIR}" output -raw producer_function_name 2>/dev/null)}"
CONSUMER="${CONSUMER_FUNCTION:-$(terraform -chdir="${TF_DIR}" output -raw consumer_function_name 2>/dev/null)}"
DASHBOARD_URL="${DASHBOARD_URL_VAR:-$(terraform -chdir="${TF_DIR}" output -raw dashboard_url 2>/dev/null)}"

if [[ -z "${PRODUCER}" ]] || [[ -z "${CONSUMER}" ]]; then
  echo "[ERROR] 関数名を取得できませんでした。terraform apply 済みか確認してください。" >&2
  exit 1
fi

DASHBOARD_NAME="phase4-overview"

echo "  Producer  : ${PRODUCER}"
echo "  Consumer  : ${CONSUMER}"
echo "  Dashboard : ${DASHBOARD_NAME}"
echo "  Region    : ${REGION}"
echo ""
echo "------------------------------------------------------------"
echo "  このスクリプトで観測する内容:"
echo ""
echo "  [1] ダッシュボード存在確認 (get-dashboard)"
echo "  [2] 観察ポイントの解説"
echo "  [3] Lambda 標準メトリクス (Invocations / Errors / Duration / Throttles)"
echo "  [4] カスタムメトリクス (ItemsWritten / ProducerErrorCount / ConsumerErrorCount)"
echo "  [5] アラーム状態 (MetricAlarm + CompositeAlarm)"
echo "  [6] Logs Insights: ERROR ログ抽出"
echo "  [7] コンソール Deep Link"
echo "------------------------------------------------------------"
echo ""

# ─── [1] ダッシュボード存在スモーク ──────────────────────────
echo "=== [1] ダッシュボード存在スモーク ==="
aws cloudwatch get-dashboard \
  --dashboard-name "${DASHBOARD_NAME}" \
  --region "${REGION}" \
  --query 'DashboardName' \
  --output text 2>/dev/null && echo "  → dashboard \"${DASHBOARD_NAME}\" が存在します (OK)" \
  || echo "  → [WARN] dashboard が見つかりません — terraform apply 済みか確認してください"

# ─── [2] 観察ポイントの解説 ──────────────────────────────────
echo ""
echo "=== [2] 観察ポイント（このメトリクスがこう動くはず） ==="
echo ""
echo "  CloudWatch メトリクスは標準解像度 (period=60s) のため"
echo "  load.sh 実行後 1〜3 分で反映されます。"
echo ""
echo "  期待される動き:"
echo "  ┌─ AWS/Lambda / Invocations"
echo "  │    producer, consumer ともに ROUNDS 分だけカウントが上がる"
echo "  ├─ AWS/Lambda / Errors"
echo "  │    consumer は ~10% エラー確率なので 20 ラウンドなら 1〜3 程度"
echo "  ├─ Phase4/Lambda / ItemsWritten"
echo "  │    producer 1 回あたり 10 件 → 20 ラウンドで計 ~200 件"
echo "  ├─ Phase4/Lambda / ProducerErrorCount"
echo "  │    producer がエラーログを出力した回数（log metric filter 経由）"
echo "  ├─ Phase4/Lambda / ConsumerErrorCount"
echo "  │    consumer がエラーログを出力した回数（log metric filter 経由）"
echo "  └─ Alarm: phase4-producer-errors"
echo "       ProducerErrorCount >= 1 で ALARM → SNS メール通知"
echo ""

# メトリクス反映を待つ（load.sh 直後に watch.sh を呼んだ場合のバッファ）
echo "  [wait] メトリクス反映バッファとして 30 秒待機..."
sleep 30
echo "  [wait] 完了"
echo ""

# 時間範囲: 過去 15 分
START=$(date -u -v-15M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -d '15 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')
END=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
PERIOD=60

echo "  観測ウィンドウ: ${START} 〜 ${END} (period=${PERIOD}s)"
echo ""

# ─── [3] Lambda 標準メトリクス ───────────────────────────────
echo "=== [3] Lambda 標準メトリクス: Invocations / Errors / Duration / Throttles ==="
echo "    ★ Invocations が ROUNDS 分、Errors が ~10% 出ていれば正常"
echo ""

for FN in "${PRODUCER}" "${CONSUMER}"; do
  echo "  ---- 関数: ${FN} ----"
  for METRIC in Invocations Errors Throttles; do
    printf "  %-15s (Sum)  : " "${METRIC}"
    aws cloudwatch get-metric-statistics \
      --namespace "${STD_NAMESPACE}" \
      --metric-name "${METRIC}" \
      --dimensions Name=FunctionName,Value="${FN}" \
      --start-time "${START}" \
      --end-time "${END}" \
      --period "${PERIOD}" \
      --statistics Sum \
      --region "${REGION}" \
      --query 'sort_by(Datapoints, &Timestamp)[*].{T:Timestamp,V:Sum}' \
      --output table 2>/dev/null || echo "(データなし)"
  done

  printf "  %-15s (p99)  :\n" "Duration"
  aws cloudwatch get-metric-statistics \
    --namespace "${STD_NAMESPACE}" \
    --metric-name "Duration" \
    --dimensions Name=FunctionName,Value="${FN}" \
    --start-time "${START}" \
    --end-time "${END}" \
    --period "${PERIOD}" \
    --extended-statistics p99 \
    --region "${REGION}" \
    --query 'sort_by(Datapoints, &Timestamp)[*].{T:Timestamp,p99:ExtendedStatistics.p99}' \
    --output table 2>/dev/null || echo "  (データなし)"

  echo ""
done

# ─── [4] カスタムメトリクス ──────────────────────────────────
echo "=== [4] カスタムメトリクス: ${NAMESPACE} ==="
echo "    ★ ItemsWritten がラウンド数×10 に近ければ producer が正常動作"
echo "    ★ ProducerErrorCount / ConsumerErrorCount は log metric filter 経由"
echo "       → ログ出力から CloudWatch への反映に追加で ~1 分かかる場合あり"
echo ""

for METRIC in ItemsWritten ProducerErrorCount ConsumerErrorCount; do
  printf "  %-22s (Sum):\n" "${METRIC}"
  aws cloudwatch get-metric-statistics \
    --namespace "${NAMESPACE}" \
    --metric-name "${METRIC}" \
    --start-time "${START}" \
    --end-time "${END}" \
    --period "${PERIOD}" \
    --statistics Sum \
    --region "${REGION}" \
    --query 'sort_by(Datapoints, &Timestamp)[*].{T:Timestamp,Sum:Sum}' \
    --output table 2>/dev/null || echo "  (データなし)"
  echo ""
done

# ─── [5] アラーム状態確認 ────────────────────────────────────
echo "=== [5] Alarm 状態確認 ==="
echo "    ★ ロード後に phase4-producer-errors が ALARM になっていれば成功"
echo "    ★ phase4-critical (Composite) も連動して ALARM になるはず"
echo ""

echo "  -- MetricAlarms (phase4-* prefix) --"
aws cloudwatch describe-alarms \
  --alarm-name-prefix "phase4-" \
  --region "${REGION}" \
  --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue,UpdatedAt:StateUpdatedTimestamp,Reason:StateReason}' \
  --output table 2>/dev/null || echo "  (アラームなし / エラー)"

echo ""
echo "  -- CompositeAlarms (phase4-* prefix) --"
aws cloudwatch describe-alarms \
  --alarm-types CompositeAlarm \
  --alarm-name-prefix "phase4-" \
  --region "${REGION}" \
  --query 'CompositeAlarms[*].{Name:AlarmName,State:StateValue,UpdatedAt:StateUpdatedTimestamp}' \
  --output table 2>/dev/null || echo "  (Composite アラームなし / エラー)"

echo ""

# ─── [6] Logs Insights: ERROR ログ抽出 ───────────────────────
echo "=== [6] Logs Insights: ERROR ログ抽出（過去 15 分） ==="
echo "    ★ consumer のエラーログが表示されれば、アラーム発火の根拠が確認できる"
echo ""

LI_START=$(date -u -v-15M +%s 2>/dev/null || date -u -d '15 minutes ago' +%s)
LI_END=$(date -u +%s)

QUERY_ID=$(aws logs start-query \
  --log-group-names "/aws/lambda/${PRODUCER}" "/aws/lambda/${CONSUMER}" \
  --start-time "${LI_START}" \
  --end-time "${LI_END}" \
  --query-string 'fields @timestamp, @message | filter @message like /ERROR/ | sort @timestamp desc | limit 20' \
  --region "${REGION}" \
  --query 'queryId' --output text 2>/dev/null) || true

if [[ -z "${QUERY_ID}" ]]; then
  echo "  [WARN] Logs Insights クエリの開始に失敗しました。スキップします。"
else
  echo "  Query ID: ${QUERY_ID}"
  echo "  クエリ結果を取得中 (30 秒待機)..."
  sleep 30
  aws logs get-query-results \
    --query-id "${QUERY_ID}" \
    --region "${REGION}" \
    --query 'results' \
    --output json 2>/dev/null || echo "  (結果取得失敗 — 少し後に再実行してください)"
fi

echo ""

# ─── [7] コンソール Deep Link ────────────────────────────────
echo "=== [7] コンソール Deep Link ==="
echo ""
if [[ -n "${DASHBOARD_URL}" ]]; then
  echo "  Dashboard (terraform output):"
  echo "    ${DASHBOARD_URL}"
  echo ""
fi
echo "  Dashboard (直接):"
echo "    https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${DASHBOARD_NAME}"
echo ""
echo "  Alarms:"
echo "    https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#alarmsV2:"
echo ""
echo "  Metrics (Phase4/Lambda カスタム namespace):"
echo "    https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#metricsV2:graph=~();namespace=Phase4/Lambda"
echo ""
echo "  Log Insights:"
echo "    https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:logs-insights"
echo ""
echo "  Producer ログ:"
echo "    https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:log-groups/log-group/\$252Faws\$252Flambda\$252F${PRODUCER}"
echo ""
echo "  Consumer ログ:"
echo "    https://console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:log-groups/log-group/\$252Faws\$252Flambda\$252F${CONSUMER}"

echo ""
echo "################################################################"
echo "#                                                              #"
echo "#  [!!] 観測が終わったら必ず以下を実行してください [!!]       #"
echo "#                                                              #"
echo "#    make sandbox-down-phase4                                  #"
echo "#                                                              #"
echo "#  実行しないと AWS リソースが残り続け課金が発生します         #"
echo "#                                                              #"
echo "################################################################"
echo ""
