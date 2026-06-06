#!/usr/bin/env bash
# watch.sh — Phase 10 CloudWatch observation (SNS / SQS / Lambda)
set -euo pipefail

REGION=${AWS_REGION:-ap-northeast-1}
TF_DIR=/Users/yoshi/competitive_programming_review/terraform/sandboxes/phase10

# 識別子を terraform output から自動取得（env があれば優先）
TOPIC_ARN=${TOPIC_ARN:-$(terraform -chdir="$TF_DIR" output -raw orders_topic_arn)}
FUNCTION=${FUNCTION_NAME:-$(terraform -chdir="$TF_DIR" output -raw notifier_function_name)}
TOPIC_NAME="phase10-orders"
DASH_NAME="phase10-sns"

# 時刻ウィンドウ: 過去 20 分（SNS メトリクスは最低 1 分粒度、最大 5 分遅延）
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START=$(date -u -v -20M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "20 minutes ago" +%Y-%m-%dT%H:%M:%SZ)

echo "============================================================"
echo "  Phase 10 CloudWatch Observer"
echo "============================================================"
echo "  Region    : $REGION"
echo "  Topic     : $TOPIC_NAME"
echo "  Function  : $FUNCTION"
echo "  Window    : $START → $END"
echo "============================================================"
echo ""

# ------------------------------------------------------------------
# (1) Dashboard 存在スモーク
# ------------------------------------------------------------------
echo "[1/5] Dashboard smoke check"
DASH_ARN=$(aws cloudwatch get-dashboard \
  --region "$REGION" \
  --dashboard-name "$DASH_NAME" \
  --query 'DashboardArn' --output text 2>/dev/null) \
  && echo "  [OK] $DASH_NAME は存在します ($DASH_ARN)" \
  || { echo "  [ERROR] Dashboard $DASH_NAME が見つかりません。terraform apply を先に実行してください。"; exit 1; }
echo ""

# ------------------------------------------------------------------
# (2) 観察ポイント解説
# ------------------------------------------------------------------
echo "[2/5] 観察ポイント（メトリクスが何を意味するか）"
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ SNS                                                         │"
echo "  │  NumberOfMessagesPublished   : load.sh で送った総件数(21件想定) │"
echo "  │  NumberOfNotificationsDelivered : サブスクリプションへの配信成功数 │"
echo "  │    → 1メッセージが複数サブスクに届くと件数が増える            │"
echo "  │  NumberOfNotificationsFailed : 配信失敗数（DLQ 行きの根拠）    │"
echo "  │  NumberOfNotificationsFilteredOut : フィルタで弾かれた件数     │"
echo "  │    → unknown_type の2件は fulfilment/wholesale フィルタで弾かれる │"
echo "  ├─────────────────────────────────────────────────────────────┤"
echo "  │ SQS (ApproximateNumberOfMessagesVisible)                    │"
echo "  │  fulfillment : standard(10) + express(5) = 15 件想定        │"
echo "  │  analytics   : フィルタなし = 全20件（unknown含む）想定       │"
echo "  │  wholesale   : wholesale(3) のみ = 3 件想定                 │"
echo "  │  *-dlq       : malformed express が Lambda エラー → DLQ へ   │"
echo "  ├─────────────────────────────────────────────────────────────┤"
echo "  │ Lambda                                                      │"
echo "  │  Invocations : express(5) + malformed(1) = 6 件想定         │"
echo "  │  Errors      : malformed 1 件が JSON parse 失敗 → 1 件想定    │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""

# ------------------------------------------------------------------
# (3) メトリクス反映待ち案内
# ------------------------------------------------------------------
echo "[3/5] メトリクス取得"
echo "  ※ SNS/SQS は反映まで最大 5 分かかります。"
echo "  ※ load.sh 直後の場合は数字が 0 のことがあります。"
echo "  ※ 数分後に再実行: make sandbox-watch-phase10"
echo ""

get_metric() {
  local label=$1 ns=$2 metric=$3 dim_name=$4 dim_val=$5
  echo "  --- $label ---"
  aws cloudwatch get-metric-statistics \
    --region "$REGION" \
    --namespace "$ns" \
    --metric-name "$metric" \
    --dimensions "Name=$dim_name,Value=$dim_val" \
    --start-time "$START" --end-time "$END" \
    --period 300 --statistics Sum \
    --query 'sort_by(Datapoints, &Timestamp)[*].[Timestamp,Sum]' \
    --output table 2>/dev/null || echo "  (データなし — まだ反映待ちの可能性があります)"
  echo ""
}

echo "  [ SNS メトリクス: $TOPIC_NAME ]"
get_metric "NumberOfMessagesPublished (送信数)" \
  AWS/SNS NumberOfMessagesPublished TopicName "$TOPIC_NAME"
get_metric "NumberOfNotificationsDelivered (配信成功数)" \
  AWS/SNS NumberOfNotificationsDelivered TopicName "$TOPIC_NAME"
get_metric "NumberOfNotificationsFailed (配信失敗数)" \
  AWS/SNS NumberOfNotificationsFailed TopicName "$TOPIC_NAME"
get_metric "NumberOfNotificationsFilteredOut (フィルタ除外数)" \
  AWS/SNS NumberOfNotificationsFilteredOut TopicName "$TOPIC_NAME"

echo "  [ SQS キュー深さ: ApproximateNumberOfMessagesVisible ]"
for q in fulfillment analytics wholesale fulfillment-dlq analytics-dlq wholesale-dlq; do
  get_metric "phase10-$q" \
    AWS/SQS ApproximateNumberOfMessagesVisible QueueName "phase10-$q"
done

echo "  [ Lambda Notifier: $FUNCTION ]"
get_metric "Invocations (呼び出し数)" \
  AWS/Lambda Invocations FunctionName "$FUNCTION"
get_metric "Errors (エラー数)" \
  AWS/Lambda Errors FunctionName "$FUNCTION"

# ------------------------------------------------------------------
# (4) コンソール deep links
# ------------------------------------------------------------------
echo "[4/5] コンソール deep links"
echo ""
echo "  SNS Topic:"
echo "    https://${REGION}.console.aws.amazon.com/sns/v3/home?region=${REGION}#/topic/${TOPIC_ARN}"
echo ""
echo "  SQS キュー一覧:"
echo "    https://${REGION}.console.aws.amazon.com/sqs/v3/home?region=${REGION}"
echo ""
echo "  Lambda ログ (${FUNCTION}):"
ENCODED_LG="\$252Faws\$252Flambda\$252F${FUNCTION}"
echo "    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:log-groups/log-group/${ENCODED_LG}"
echo ""
echo "  CloudWatch Dashboard (${DASH_NAME}):"
echo "    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${DASH_NAME}"
echo ""

# ------------------------------------------------------------------
# (5) リマインダー
# ------------------------------------------------------------------
echo "============================================================"
echo ""
echo "  [5/5] 観測が終わったら必ずリソースを削除してください"
echo ""
echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "  !!                                                      !!"
echo "  !!   make sandbox-down-phase10                         !!"
echo "  !!                                                      !!"
echo "  !!  実行しないと SNS / SQS / Lambda / KMS の課金が続きます !!"
echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo ""
echo "============================================================"
