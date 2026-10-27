#!/usr/bin/env bash
# Fase 5: Lambda nok-writer (SQS ingest-nok-queue → S3 nok). Idempotente; republica o código.
set -euo pipefail
source "$(dirname "$0")/config.sh"
cd "$(dirname "$0")/.."

FN=${PREFIX}-nok-writer
ROLE=${FN}-role
RAW_BUCKET=${PREFIX}-raw-${ACCOUNT_ID}
NOK_BUCKET=${PREFIX}-nok-${ACCOUNT_ID}
QUEUE_ARN=arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${PREFIX}-nok-queue
LOG_GROUP=/aws/lambda/${FN}

aws logs create-log-group --log-group-name "$LOG_GROUP" --tags Project=ingest,Env=dev 2>/dev/null || true
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 14

if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --tags $TAGS --assume-role-policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow",
      "Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  echo "Role criada: $ROLE"
  NEW_ROLE=1
fi
# s3:ListBucket no raw faz o GetObject de chave inexistente retornar NoSuchKey (e não AccessDenied).
aws iam put-role-policy --role-name "$ROLE" --policy-name app --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"${QUEUE_ARN}\"},
    {\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::${RAW_BUCKET}/raw/*\"},
    {\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"arn:aws:s3:::${RAW_BUCKET}\",\"Condition\":{\"StringLike\":{\"s3:prefix\":\"raw/*\"}}},
    {\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",\"Resource\":\"arn:aws:s3:::${NOK_BUCKET}/nok/*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}:*\"}]}"
[ -n "${NEW_ROLE:-}" ] && sleep 10

mkdir -p dist
rm -f dist/${FN}.zip
(cd src/nok-writer && zip -q -r ../../dist/${FN}.zip index.js)

if ! aws lambda get-function --function-name "$FN" >/dev/null 2>&1; then
  aws lambda create-function --function-name "$FN" \
    --runtime nodejs22.x --architectures arm64 --handler index.handler \
    --memory-size 256 --timeout 30 \
    --role arn:aws:iam::${ACCOUNT_ID}:role/${ROLE} \
    --environment "Variables={RAW_BUCKET=${RAW_BUCKET},NOK_BUCKET=${NOK_BUCKET}}" \
    --zip-file fileb://dist/${FN}.zip \
    --tags Project=ingest,Env=dev >/dev/null
  echo "Lambda criada: $FN"
else
  aws lambda update-function-code --function-name "$FN" --zip-file fileb://dist/${FN}.zip >/dev/null
  echo "Código atualizado: $FN"
fi
aws lambda wait function-updated-v2 --function-name "$FN"

ESM=$(aws lambda list-event-source-mappings --function-name "$FN" --event-source-arn "$QUEUE_ARN" \
  --query 'EventSourceMappings[0].UUID' --output text)
if [ "$ESM" = "None" ]; then
  ESM=$(aws lambda create-event-source-mapping --function-name "$FN" --event-source-arn "$QUEUE_ARN" \
    --batch-size 10 --maximum-batching-window-in-seconds 5 \
    --function-response-types ReportBatchItemFailures --query UUID --output text)
  echo "ESM criado: $ESM"
fi
echo "FN=$FN ESM=$ESM"
