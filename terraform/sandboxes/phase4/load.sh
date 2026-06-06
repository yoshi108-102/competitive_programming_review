#!/usr/bin/env bash
# load.sh — Phase 4 ロード生成スクリプト
# 無入力で動作: 識別子は terraform output から自動取得
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-1}"
ROUNDS="${1:-20}"   # 引数で回数を変えられる

TF_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================================"
echo "  Phase 4 CloudWatch サンドボックス — ロード生成"
echo "============================================================"
echo ""
echo "[事前] terraform output から識別子を取得中..."

PRODUCER="${PRODUCER_FUNCTION:-$(terraform -chdir="${TF_DIR}" output -raw producer_function_name 2>/dev/null)}"
CONSUMER="${CONSUMER_FUNCTION:-$(terraform -chdir="${TF_DIR}" output -raw consumer_function_name 2>/dev/null)}"

if [[ -z "${PRODUCER}" ]] || [[ -z "${CONSUMER}" ]]; then
  echo "[ERROR] 関数名を取得できませんでした。terraform apply 済みか確認してください。" >&2
  exit 1
fi

echo "  Producer : ${PRODUCER}"
echo "  Consumer : ${CONSUMER}"
echo "  Region   : ${REGION}"
echo "  Rounds   : ${ROUNDS} 回（producer が count=10 件/回 書き込み、"
echo "             consumer は約 10% の確率でエラーを発生させます）"
echo ""
echo "------------------------------------------------------------"
echo "  観測ポイント:"
echo "  - producer を 1 回呼ぶごとに DynamoDB に 10 件書き込まれる"
echo "  - consumer は 10% でランダムエラー → ProducerErrorCount / ConsumerErrorCount が上昇"
echo "  - ${ROUNDS} ラウンドで少なくとも 1〜2 回はアラームが ALARM 状態に遷移するはず"
echo "------------------------------------------------------------"
echo ""

TOTAL_WRITTEN=0
TOTAL_CONSUMER_CALLS=0
ERRORS_SEEN=0

for i in $(seq 1 "${ROUNDS}"); do
  printf "[%2d/%2d] producer を呼び出し中... " "${i}" "${ROUNDS}"
  aws lambda invoke \
    --function-name "${PRODUCER}" \
    --payload '{"count":10}' \
    --cli-binary-format raw-in-base64-out \
    --region "${REGION}" \
    /tmp/phase4_resp_producer.json > /dev/null || true

  PROD_RESULT=$(cat /tmp/phase4_resp_producer.json 2>/dev/null || echo '{}')
  ITEMS=$(echo "${PROD_RESULT}" | grep -o '"items_written":[0-9]*' | grep -o '[0-9]*' || echo "?")
  printf "完了 (items_written=%s)\n" "${ITEMS}"
  [[ "${ITEMS}" =~ ^[0-9]+$ ]] && TOTAL_WRITTEN=$(( TOTAL_WRITTEN + ITEMS )) || true

  printf "[%2d/%2d] consumer を呼び出し中... " "${i}" "${ROUNDS}"
  aws lambda invoke \
    --function-name "${CONSUMER}" \
    --payload '{}' \
    --cli-binary-format raw-in-base64-out \
    --region "${REGION}" \
    /tmp/phase4_resp_consumer.json > /dev/null || true

  CONS_RESULT=$(cat /tmp/phase4_resp_consumer.json 2>/dev/null || echo '{}')
  TOTAL_CONSUMER_CALLS=$(( TOTAL_CONSUMER_CALLS + 1 ))

  # consumer 側のエラーレスポンスを検出（FunctionError フィールドまたは "errorMessage"）
  if echo "${CONS_RESULT}" | grep -qi '"errorMessage"'; then
    ERRORS_SEEN=$(( ERRORS_SEEN + 1 ))
    printf "完了 \033[31m[ERROR 検出 #%d]\033[0m\n" "${ERRORS_SEEN}"
  else
    printf "完了 (正常)\n"
  fi

  # consumer は 10% エラー確率なので 20 ラウンドで ~2 件が期待値
  sleep 2
done

echo ""
echo "============================================================"
echo "  ロード完了サマリ"
echo "============================================================"
echo "  Producer 呼出 : ${ROUNDS} 回"
echo "  Consumer 呼出 : ${TOTAL_CONSUMER_CALLS} 回"
echo "  書込み合計(推定): ${TOTAL_WRITTEN} 件"
echo "  Consumer エラー検出: ${ERRORS_SEEN} 件"
echo ""
echo "  [!] メトリクスは CloudWatch に 1〜3 分で反映されます。"
echo "      少し待ってから watch.sh を実行してください。"
echo ""
echo "  次のステップ:"
echo "    make sandbox-watch-phase4"
echo "============================================================"
