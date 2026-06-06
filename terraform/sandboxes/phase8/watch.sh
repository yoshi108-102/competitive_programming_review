#!/usr/bin/env bash
# watch.sh — Phase8 Step Functions metrics observer
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-1}"
TF_DIR="/Users/yoshi/competitive_programming_review/terraform/sandboxes/phase8"

echo "===================================================================="
echo " Phase8 Step Functions — Metrics Observer"
echo "===================================================================="
echo ""
echo "INFO: CloudWatch メトリクスの反映には 1〜2 分かかります。"
echo "INFO: load.sh 実行後に本スクリプトを起動してください。"
echo ""

# ---------------------------------------------------------------------------
# 識別子の自動取得（env 優先、なければ terraform output から取得）
# ---------------------------------------------------------------------------
echo ">>> 識別子の取得（terraform output）..."
SFN_ARN="${SFN_ARN:-$(terraform -chdir="$TF_DIR" output -raw state_machine_arn 2>/dev/null)}"
DASHBOARD_URL="${DASHBOARD_URL:-$(terraform -chdir="$TF_DIR" output -raw dashboard_url 2>/dev/null)}"
SM_NAME=$(terraform -chdir="$TF_DIR" output -raw state_machine_name 2>/dev/null || echo "phase8-order-saga")
DASHBOARD_NAME="Phase8-StepFunctions"

if [[ -z "$SFN_ARN" ]]; then
  echo "ERROR: state_machine_arn を取得できませんでした。terraform apply が完了しているか確認してください。" >&2
  exit 1
fi

echo "    State Machine : $SM_NAME"
echo "    ARN           : $SFN_ARN"
echo "    Region        : $REGION"
echo ""

# ---------------------------------------------------------------------------
# [0] Dashboard smoke test
# ---------------------------------------------------------------------------
echo "===================================================================="
echo "[0] Dashboard 存在確認"
echo "===================================================================="
aws cloudwatch get-dashboard \
  --dashboard-name "$DASHBOARD_NAME" \
  --region "$REGION" \
  --query "DashboardName" \
  --output text 2>/dev/null \
  | grep -q "$DASHBOARD_NAME" \
  && echo "    OK: ダッシュボード '$DASHBOARD_NAME' が存在します。" \
  || { echo "    ERROR: ダッシュボードが見つかりません。make sandbox-up-phase8 を確認してください。" >&2; exit 1; }
echo ""

# ---------------------------------------------------------------------------
# [1] 観察ポイントの明示
# ---------------------------------------------------------------------------
echo "===================================================================="
echo "[1] 観察ポイント — 何がどう動くか"
echo "===================================================================="
echo ""
echo "  メトリクス名 (namespace: AWS/States)"
echo "  ┌─────────────────────────────────────────────────────────────────"
echo "  │ ExecutionsStarted  : load.sh が送信した 15 件が反映されるはず"
echo "  │ ExecutionsSucceeded: Happy path 10 件が SUCCEEDED になるはず"
echo "  │ ExecutionsFailed   : Comp/Inv 5 件が FAILED になるはず"
echo "  │ ExecutionTime      : STANDARD ワークフローの実際の所要時間 (ms)"
echo "  │                       → P99 が数秒以内なら Lambda 連鎖は健全"
echo "  └─────────────────────────────────────────────────────────────────"
echo ""
echo "  Lambda Errors (namespace: AWS/Lambda)"
echo "  ┌─────────────────────────────────────────────────────────────────"
echo "  │ validate-order  : Scenario2 (amount=0) で意図的エラーが出るはず"
echo "  │ update-inventory: Scenario3 (qty=9999) で意図的エラーが出るはず"
echo "  │ compensate-order: 上記 5 件の補償トランザクションが呼ばれるはず"
echo "  │ charge-payment  : Happy path のみ呼ばれ、エラー 0 が期待値"
echo "  │ notify-customer : Happy path のみ呼ばれ、エラー 0 が期待値"
echo "  └─────────────────────────────────────────────────────────────────"
echo ""
echo "  CloudWatch Alarm"
echo "  ┌─────────────────────────────────────────────────────────────────"
echo "  │ phase8-sfn-execution-failures: 1 分間で 3 件以上 FAILED → ALARM"
echo "  │  → 今回 5 件失敗させているため ALARM 状態になっている可能性あり"
echo "  └─────────────────────────────────────────────────────────────────"
echo ""

# ---------------------------------------------------------------------------
# [2] メトリクス反映待ち
# ---------------------------------------------------------------------------
echo "===================================================================="
echo "[2] メトリクス反映待ち（Step Functions は 1〜2 分遅延）"
echo "===================================================================="
echo "    60 秒 sleep します..."
sleep 60
echo "    さらに 60 秒..."
sleep 60
echo "    反映待ち完了。メトリクスを取得します。"
echo ""

# 時間窓: 直近 15 分 / period 60s
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_TIME=$(date -u -v-15M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -d "-15 minutes" +"%Y-%m-%dT%H:%M:%SZ")
START_MS=$(( $(date +%s) * 1000 - 900000 ))

# ---------------------------------------------------------------------------
# [3] SFN 実行カウント スナップショット
# ---------------------------------------------------------------------------
echo "===================================================================="
echo "[3] SFN 実行カウント（直近 15 分 / 60s period）"
echo "===================================================================="
printf "  %-30s %s\n" "Metric" "Sum"
printf "  %-30s %s\n" "------------------------------" "-----"
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
    --output json 2>/dev/null \
    | python3 -c "import json,sys; data=json.load(sys.stdin); print(int(sum(data)) if data else 0)" \
    || echo "N/A")
  printf "  %-30s %s\n" "${METRIC}:" "$VALUE"
done
echo ""

# ---------------------------------------------------------------------------
# [4] ExecutionTime P99
# ---------------------------------------------------------------------------
echo "===================================================================="
echo "[4] ExecutionTime P99 (ms) — 直近 15 分"
echo "===================================================================="
echo "    期待値: Happy path (Lambda x4連鎖) で数秒〜数十秒以内"
echo ""
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
  --output table 2>/dev/null || echo "    (データなし — まだ反映されていない可能性があります)"
echo ""

# ---------------------------------------------------------------------------
# [5] Lambda Errors 集計
# ---------------------------------------------------------------------------
echo "===================================================================="
echo "[5] Lambda Errors — 各 Function の直近 15 分"
echo "===================================================================="
echo "    validate-order / update-inventory にエラーが出るのは意図的動作です。"
echo "    charge-payment / notify-customer / compensate-order は 0 が期待値。"
echo ""
printf "  %-32s %s\n" "FunctionName" "Errors (Sum)"
printf "  %-32s %s\n" "--------------------------------" "------------"
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
    --output text 2>/dev/null || echo "N/A")
  printf "  %-32s %s\n" "phase8-${FN}:" "$ERR"
done
echo ""

# ---------------------------------------------------------------------------
# [6] CloudWatch Alarm 状態確認
# ---------------------------------------------------------------------------
echo "===================================================================="
echo "[6] CloudWatch Alarm — 失敗件数アラーム状態"
echo "===================================================================="
aws cloudwatch describe-alarms \
  --alarm-names "phase8-sfn-execution-failures" \
  --region "$REGION" \
  --query "MetricAlarms[*].{Name:AlarmName,State:StateValue,Reason:StateReason}" \
  --output table 2>/dev/null || echo "    (アラーム情報取得に失敗)"
echo ""

# ---------------------------------------------------------------------------
# [7] CloudWatch Logs — SFN 実行失敗ログ
# ---------------------------------------------------------------------------
echo "===================================================================="
echo "[7] CloudWatch Logs — SFN 実行失敗イベント（直近 15 分）"
echo "===================================================================="
echo "    CompensateOrder が呼ばれた証跡がここに残るはず。"
echo ""
aws logs filter-log-events \
  --log-group-name "/aws/states/phase8-order-saga" \
  --filter-pattern "ExecutionFailed" \
  --start-time "$START_MS" \
  --region "$REGION" \
  --query "events[*].message" \
  --output text 2>/dev/null \
  | head -20 \
  || echo "    (ExecutionFailed イベントなし、またはロググループ未作成)"
echo ""

# ---------------------------------------------------------------------------
# [8] Execution History — 直近 20 件
# ---------------------------------------------------------------------------
echo "===================================================================="
echo "[8] Execution History — 直近 20 件（SFN API 直接）"
echo "===================================================================="
aws stepfunctions list-executions \
  --state-machine-arn "$SFN_ARN" \
  --region "$REGION" \
  --max-results 20 \
  --query "executions[*].{Name:name,Status:status,Started:startDate}" \
  --output table 2>/dev/null || echo "    (取得に失敗)"
echo ""

# ---------------------------------------------------------------------------
# [9] Console Deep Links
# ---------------------------------------------------------------------------
echo "===================================================================="
echo "[9] Console Deep Links"
echo "===================================================================="
SM_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${SFN_ARN}'))" 2>/dev/null \
  || echo "(encoding failed)")
echo ""
echo "  State Machine 実行一覧:"
echo "  https://${REGION}.console.aws.amazon.com/states/home?region=${REGION}#/statemachines/view/${SM_ENCODED}"
echo ""
echo "  CloudWatch Dashboard:"
if [[ -n "$DASHBOARD_URL" ]]; then
  echo "  ${DASHBOARD_URL}"
else
  echo "  https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${DASHBOARD_NAME}"
fi
echo ""
echo "  X-Ray Service Map (Lambda 連鎖のトレース):"
echo "  https://${REGION}.console.aws.amazon.com/xray/home?region=${REGION}#/service-map"
echo ""
echo "  CloudWatch Alarm:"
echo "  https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#alarmsV2:name=phase8-sfn-execution-failures"
echo ""

# ---------------------------------------------------------------------------
# 終了リマインダ
# ---------------------------------------------------------------------------
echo "===================================================================="
echo ""
echo "  !! 観測が終わったら必ず実行してください !!"
echo ""
echo "      make sandbox-down-phase8"
echo ""
echo "  放置すると以下の課金が継続します:"
echo "    - Step Functions 実行履歴 (STANDARD は 90 日保存)"
echo "    - KMS CMK (月 $1 + API コール)"
echo "    - CloudWatch Logs / Metrics"
echo ""
echo "===================================================================="
