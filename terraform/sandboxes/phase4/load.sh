#!/usr/bin/env bash
# load.sh — Phase 4 ロード生成スクリプト
# 事前: terraform output で関数名を確認済みであること
set -euo pipefail

PRODUCER="phase4-producer"
CONSUMER="phase4-consumer"
REGION="${AWS_REGION:-ap-northeast-1}"
ROUNDS="${1:-20}"   # 引数で回数を変えられる

echo "=== Phase 4 load generation: ${ROUNDS} rounds ==="

for i in $(seq 1 "${ROUNDS}"); do
  echo "[${i}/${ROUNDS}] Invoking producer (count=10)..."
  aws lambda invoke \
    --function-name "${PRODUCER}" \
    --payload '{"count":10}' \
    --cli-binary-format raw-in-base64-out \
    --region "${REGION}" \
    /tmp/resp_producer.json > /dev/null
  cat /tmp/resp_producer.json

  echo "[${i}/${ROUNDS}] Invoking consumer..."
  aws lambda invoke \
    --function-name "${CONSUMER}" \
    --payload '{}' \
    --cli-binary-format raw-in-base64-out \
    --region "${REGION}" \
    /tmp/resp_consumer.json > /dev/null
  cat /tmp/resp_consumer.json

  # consumer は 10% でエラーを投げるため ROUNDS>=10 で少なくとも 1 回はアラームが鳴る
  sleep 2
done

echo ""
echo "=== ロード完了。メトリクス反映まで 2〜3 分待ちます... ==="
echo "watch.sh を実行してください。"
