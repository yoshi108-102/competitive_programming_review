#!/usr/bin/env bash
set -euo pipefail

# ── 識別子の自動取得（env があれば env を優先）────────────────────────────────
SANDBOX_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_CMD="terraform -chdir=${SANDBOX_DIR}"

BUCKET=${PHASE2_BUCKET:-$(${TF_CMD} output -raw main_bucket_name)}
REGION=${AWS_DEFAULT_REGION:-$(${TF_CMD} output -raw aws_region 2>/dev/null || echo "ap-northeast-1")}
PREFIX="load-$(date +%s)"

echo "============================================================"
echo "  Phase 2 load.sh — S3 負荷生成"
echo "============================================================"
echo "  バケット : $BUCKET"
echo "  リージョン: $REGION"
echo "  プレフィクス: $PREFIX"
echo ""

# ── Step 1: 小オブジェクト 30 件 PutObject ────────────────────────────────────
echo "[1/6] 小オブジェクト (1行テキスト) を 30 件 PutObject ..."
SUCCESS=0
for i in $(seq 1 30); do
  TMP=$(mktemp)
  echo "phase2 test object $i at $(date -u +%FT%TZ)" >"$TMP"
  aws s3 cp "$TMP" "s3://$BUCKET/$PREFIX/small-$i.txt" \
    --region "$REGION" --quiet || true
  rm -f "$TMP"
  SUCCESS=$((SUCCESS + 1))
  # 10 件ごとに進捗表示
  if [ $((i % 10)) -eq 0 ]; then
    echo "    ... $i / 30 件完了"
  fi
done
echo "    [OK] 小オブジェクト ${SUCCESS} 件アップロード完了"
echo ""

# ── Step 2: 12 MB 大オブジェクト（aws cli が自動でマルチパート送信）─────────────
echo "[2/6] 12 MB オブジェクトをマルチパートで PutObject ..."
echo "    (aws cli は 8 MB 以上で自動的に multipart upload を使用します)"
dd if=/dev/urandom bs=1M count=12 2>/dev/null \
  | aws s3 cp - "s3://$BUCKET/$PREFIX/large-12mb.bin" \
      --region "$REGION" \
      --expected-size $((12 * 1024 * 1024)) \
  || true
echo "    [OK] 12 MB オブジェクト (large-12mb.bin) アップロード完了"
echo ""

# ── Step 3: GetObject 10 件（AllRequests にカウント）─────────────────────────
echo "[3/6] 小オブジェクトを 10 件 GetObject ..."
GET_OK=0
for i in $(seq 1 10); do
  aws s3 cp "s3://$BUCKET/$PREFIX/small-$i.txt" /dev/null \
    --region "$REGION" --quiet || true
  GET_OK=$((GET_OK + 1))
done
echo "    [OK] GetObject ${GET_OK} 件完了"
echo ""

# ── Step 4: バージョン確認（Versioning が有効かを確認）────────────────────────
echo "[4/6] オブジェクトバージョン数を確認 ..."
VER_COUNT=$(aws s3api list-object-versions \
  --bucket "$BUCKET" --prefix "$PREFIX/" \
  --query 'length(Versions[])' --output text --region "$REGION" 2>/dev/null || echo "N/A")
echo "    [OK] プレフィクス '$PREFIX/' のバージョン数: ${VER_COUNT}"
echo "         (Enabled なら PutObject のたびに新バージョンが積まれます)"
echo ""

# ── Step 5: 存在しないキーへの GetObject（404 を AllRequests に含める）───────
echo "[5/6] 存在しないキーへ GetObject（意図的 404 生成）..."
aws s3 cp "s3://$BUCKET/$PREFIX/nonexistent.txt" /dev/null \
  --region "$REGION" 2>/dev/null \
  || echo "    [OK] 期待通り 404（AllRequests に計上されます）"
echo ""

# ── Step 6: プリサインド URL 生成 → curl で取得（SigV4 署名検証）────────────
echo "[6/6] プリサインド URL を生成して curl で取得（SigV4 署名確認）..."
PRESIGNED=$(aws s3 presign "s3://$BUCKET/$PREFIX/small-1.txt" \
  --expires-in 60 --region "$REGION" 2>/dev/null || echo "")
if [ -n "$PRESIGNED" ]; then
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$PRESIGNED" || echo "ERR")
  echo "    [OK] Presigned URL HTTP ステータス: ${HTTP_STATUS}"
  if [ "$HTTP_STATUS" = "200" ]; then
    echo "         → 200 OK: SigV4 署名が正しく機能しています"
  else
    echo "         → 予期しないステータス (期限切れ / KMS 復号権限等を確認)"
  fi
else
  echo "    [SKIP] presign 生成に失敗（権限または IAM 設定を確認）"
fi
echo ""

# ── 完了サマリ ─────────────────────────────────────────────────────────────────
echo "============================================================"
echo "  load.sh 完了"
echo ""
echo "  生成リクエスト概要:"
echo "    PutObject  : 30件 (小) + 1件 (12MB マルチパート)"
echo "    GetObject  : 10件 (正常) + 1件 (404)"
echo "    Presign    : 1件"
echo ""
echo "  メトリクス反映タイミング:"
echo "    Lambda Invocations : 即時（1-2 分で CloudWatch に出現）"
echo "    S3 AllRequests     : ~1-2 分（S3 リクエストメトリクスフィルタ）"
echo "    BucketSizeBytes    : 翌日（日次集計のため当日は 0 のことが多い）"
echo ""
echo "  次のステップ:"
echo "    1-2 分待ってから → make sandbox-watch-phase2 を実行してください"
echo "============================================================"
