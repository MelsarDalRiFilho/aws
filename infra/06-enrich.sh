#!/usr/bin/env bash
# Fase 6: Lambda enrich (SQS ingest-ok-queue → cadastro ingest-devices → ingest-data | nok-queue). Idempotente.
set -euo pipefail
source "$(dirname "$0")/config.sh"
cd "$(dirname "$0")/.."

FN=${PREFIX}-enrich
ROLE=${FN}-role
DDB_ARN=arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table
SQS_ARN=arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}
NOK_URL=https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/${PREFIX}-nok-queue
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
aws iam put-role-policy --role-name "$ROLE" --policy-name app --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"${SQS_ARN}:${PREFIX}-ok-queue\"},
    {\"Effect\":\"Allow\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"${SQS_ARN}:${PREFIX}-nok-queue\"},
    {\"Effect\":\"Allow\",\"Action\":\"dynamodb:GetItem\",\"Resource\":\"${DDB_ARN}/${PREFIX}-devices\"},
    {\"Effect\":\"Allow\",\"Action\":\"dynamodb:PutItem\",\"Resource\":\"${DDB_ARN}/${PREFIX}-data\"},
    {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}:*\"}]}"
[ -n "${NEW_ROLE:-}" ] && sleep 10

mkdir -p dist
rm -f dist/${FN}.zip
(cd src/enrich && zip -q -r ../../dist/${FN}.zip index.js)

ENV="Variables={DEVICES_TABLE=${PREFIX}-devices,DATA_TABLE=${PREFIX}-data,NOK_QUEUE_URL=${NOK_URL}}"
if ! aws lambda get-function --function-name "$FN" >/dev/null 2>&1; then
  aws lambda create-function --function-name "$FN" \
    --runtime nodejs22.x --architectures arm64 --handler index.handler \
    --memory-size 256 --timeout 30 \
    --role arn:aws:iam::${ACCOUNT_ID}:role/${ROLE} \
    --environment "$ENV" --zip-file fileb://dist/${FN}.zip \
    --tags Project=ingest,Env=dev >/dev/null
  echo "Lambda criada: $FN"
else
  aws lambda update-function-code --function-name "$FN" --zip-file fileb://dist/${FN}.zip >/dev/null
  echo "Código atualizado: $FN"
fi
aws lambda wait function-updated-v2 --function-name "$FN"

ESM=$(aws lambda list-event-source-mappings --function-name "$FN" --event-source-arn "${SQS_ARN}:${PREFIX}-ok-queue" \
  --query 'EventSourceMappings[0].UUID' --output text)
if [ "$ESM" = "None" ]; then
  ESM=$(aws lambda create-event-source-mapping --function-name "$FN" --event-source-arn "${SQS_ARN}:${PREFIX}-ok-queue" \
    --batch-size 10 --maximum-batching-window-in-seconds 5 \
    --function-response-types ReportBatchItemFailures --query UUID --output text)
  echo "ESM criado: $ESM"
fi
echo "FN=$FN ESM=$ESM"
