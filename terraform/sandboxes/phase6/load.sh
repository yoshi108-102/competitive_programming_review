#!/usr/bin/env bash
# load.sh — Phase 6 Bedrock sandbox load generation
# Token cost is minimized: 3 fixed invocations with short prompts.
# Before running: ensure Bedrock model access is granted in the console.

set -euo pipefail

SANDBOX_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_CMD="terraform -chdir=${SANDBOX_DIR} output -raw"

# ---------------------------------------------------------------------------
# 識別子の自動取得（env が設定されていれば env を優先）
# ---------------------------------------------------------------------------
echo "=== Phase6 Bedrock load.sh ==="
echo "[setup] sandbox: ${SANDBOX_DIR}"

echo "[setup] terraform output から識別子を取得中..."
FUNCTION_NAME="${FUNCTION_NAME:-$(${TF_CMD} lambda_function_name 2>/dev/null || echo "bedrock-sandbox-invoker")}"
REGION="${AWS_REGION:-$(${TF_CMD} cloudwatch_dashboard_url 2>/dev/null \
  | grep -oE '[a-z]+-[a-z]+-[0-9]+' | head -1 \
  || echo "us-east-1")}"
MODEL_ID="${MODEL_ID:-anthropic.claude-3-haiku-20240307-v1:0}"
INVOCATIONS=3

echo "  Lambda 関数名 : ${FUNCTION_NAME}"
echo "  リージョン    : ${REGION}"
echo "  モデル ID     : ${MODEL_ID}"
echo ""

# ---------------------------------------------------------------------------
# [1/4] モデルアクセス確認 (probe invocation)
# ---------------------------------------------------------------------------
echo "[1/4] モデルアクセス確認中（probe: 'ping' を送信）..."
PROBE_PAYLOAD='{"prompt":"ping"}'
aws lambda invoke \
  --function-name "${FUNCTION_NAME}" \
  --region "${REGION}" \
  --payload "${PROBE_PAYLOAD}" \
  --cli-binary-format raw-in-base64-out \
  /tmp/phase6_probe_out.json > /dev/null || true

if grep -q "AccessDeniedException\|403\|ModelNotReady" /tmp/phase6_probe_out.json 2>/dev/null; then
  echo ""
  echo "ERROR: Bedrock モデルアクセスが有効になっていません。"
  echo "  手順: AWS Console -> Bedrock -> Model access -> Manage model access"
  echo "        対象の Claude モデルを有効化し、'Access granted' になるまで待つ"
  echo ""
  exit 1
fi
echo "  OK: モデルアクセス確認済み"
echo ""

# ---------------------------------------------------------------------------
# [2/4] 3 回の固定プロンプト送信
# ---------------------------------------------------------------------------
PROMPTS=(
  "Say hello in one sentence."
  "What is AWS Bedrock? Answer in 10 words."
  "Name one benefit of serverless. Answer in one sentence."
)

echo "[2/4] Lambda -> Bedrock 呼び出し開始（${INVOCATIONS} 件）..."
echo "--------------------------------------------------------------"
ERRORS=0
for i in $(seq 0 $((INVOCATIONS - 1))); do
  PROMPT="${PROMPTS[$i]}"
  CALL_NUM=$((i + 1))
  echo "  [${CALL_NUM}/${INVOCATIONS}] 送信: \"${PROMPT}\""
  aws lambda invoke \
    --function-name "${FUNCTION_NAME}" \
    --region "${REGION}" \
    --payload "{\"prompt\":\"${PROMPT}\"}" \
    --cli-binary-format raw-in-base64-out \
    /tmp/phase6_out_${i}.json > /dev/null || true

  # レスポンス整形表示
  RESP=$(python3 -m json.tool /tmp/phase6_out_${i}.json 2>/dev/null \
    || cat /tmp/phase6_out_${i}.json 2>/dev/null || echo "(no response)")
  echo "          応答: ${RESP}"

  if grep -q "FunctionError\|errorMessage" /tmp/phase6_out_${i}.json 2>/dev/null; then
    echo "  WARNING: 呼び出し ${CALL_NUM} でエラーを検出"
    ERRORS=$((ERRORS + 1))
  fi
  echo ""
done
echo "--------------------------------------------------------------"

# ---------------------------------------------------------------------------
# [3/4] エラーサマリー
# ---------------------------------------------------------------------------
echo "[3/4] エラー確認..."
if [ "${ERRORS}" -gt 0 ]; then
  echo "  WARNING: ${ERRORS} 件の呼び出しでエラーが発生しました。"
  echo "  Lambda ログを確認してください:"
  echo "    https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#logsV2:log-groups/log-group/\$252Faws\$252Flambda\$252F${FUNCTION_NAME}"
else
  echo "  OK: 全 ${INVOCATIONS} 件がエラーなく完了しました"
fi
echo ""

# ---------------------------------------------------------------------------
# [4/4] 完了案内
# ---------------------------------------------------------------------------
echo "[4/4] 送信完了サマリー"
echo "  送信プロンプト数 : ${INVOCATIONS} 件"
echo "  対象 Lambda      : ${FUNCTION_NAME}"
echo "  対象モデル       : ${MODEL_ID}"
echo "  リージョン       : ${REGION}"
echo ""
echo "================================================================"
echo "  Bedrock メトリクスは CloudWatch に反映されるまで 2〜3 分かかります。"
echo "  次のコマンドでメトリクスを観測してください:"
echo ""
echo "      make sandbox-watch-phase6"
echo ""
echo "  (S3/KMS の課金は sandbox-down するまで継続します)"
echo "================================================================"
