#!/usr/bin/env bash
# load.sh — Phase 6 Bedrock sandbox load generation
# Token cost is minimized: 3 fixed invocations with short prompts.
# Before running: ensure Bedrock model access is granted in the console.

set -euo pipefail

FUNCTION_NAME="bedrock-sandbox-invoker"
REGION="${AWS_REGION:-us-east-1}"
INVOCATIONS=3

echo "=== Phase6 Bedrock load.sh ==="

# --- Model access check ---
# Invoke once to probe. If Bedrock returns 403, model access is not enabled.
echo "[1/4] Checking model access..."
PROBE_PAYLOAD='{"prompt":"ping"}'
aws lambda invoke \
  --function-name "$FUNCTION_NAME" \
  --region "$REGION" \
  --payload "$PROBE_PAYLOAD" \
  --cli-binary-format raw-in-base64-out \
  /tmp/probe_out.json > /dev/null || true

# Lambda may return 200 HTTP but contain a FunctionError body
if grep -q "AccessDeniedException\|403" /tmp/probe_out.json 2>/dev/null; then
  echo "ERROR: Bedrock model access is not enabled."
  echo "  Go to: AWS Console -> Bedrock -> Model access -> Manage model access"
  echo "  Enable the target Claude model and wait for 'Access granted' status."
  exit 1
fi
echo "  Model access OK"

# --- Fixed 3 invocations ---
PROMPTS=(
  "Say hello in one sentence."
  "What is AWS Bedrock? Answer in 10 words."
  "Name one benefit of serverless. Answer in one sentence."
)

echo "[2/4] Invoking Lambda -> Bedrock ${INVOCATIONS} times..."
for i in $(seq 0 $((INVOCATIONS - 1))); do
  PROMPT="${PROMPTS[$i]}"
  echo "  Call $((i + 1)): prompt='${PROMPT}'"
  aws lambda invoke \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION" \
    --payload "{\"prompt\":\"${PROMPT}\"}" \
    --cli-binary-format raw-in-base64-out \
    /tmp/lambda_out_${i}.json > /dev/null
  python3 -m json.tool /tmp/lambda_out_${i}.json 2>/dev/null || cat /tmp/lambda_out_${i}.json
  echo ""
done

echo "[3/4] Checking for errors..."
for i in $(seq 0 $((INVOCATIONS - 1))); do
  if grep -q "FunctionError\|errorMessage" /tmp/lambda_out_${i}.json 2>/dev/null; then
    echo "WARNING: Call $((i + 1)) returned an error:"
    cat /tmp/lambda_out_${i}.json
    exit 1
  fi
done

echo "[4/4] Done. Metrics appear in CloudWatch in approximately 2-5 minutes."
echo "      Run watch.sh to observe metrics."
echo ""
echo "NOTE: Remember to run 'make sandbox-down-phase6' when finished."
echo "      (S3/KMS charges continue until destroyed)"
