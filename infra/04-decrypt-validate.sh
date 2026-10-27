#!/usr/bin/env bash
# Fase 4: S3 raw → SQS validate → Lambda decrypt-validate → SQS ok | SQS nok. Idempotente; republica o código.
set -euo pipefail
source "$(dirname "$0")/config.sh"
cd "$(dirname "$0")/.."

FN=${PREFIX}-decrypt-validate
ROLE=${FN}-role
BUCKET=${PREFIX}-raw-${ACCOUNT_ID}
LOG_GROUP=/aws/lambda/${FN}
SQS_ARN=arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}
KMS_KEY_ARN=$(aws kms describe-key --key-id alias/${PREFIX}-payload --query KeyMetadata.Arn --output text)

# Cria fila + DLQ (redrive 3x). Imprime a URL da fila principal.
create_queue_with_dlq() {
  local name=$1
  aws sqs create-queue --queue-name "${name}-dlq" --tags Project=ingest,Env=dev \
    --attributes MessageRetentionPeriod=1209600,SqsManagedSseEnabled=true >/dev/null
  local url
  url=$(aws sqs create-queue --queue-name "$name" --tags Project=ingest,Env=dev \
    --attributes VisibilityTimeout=180,MessageRetentionPeriod=345600,SqsManagedSseEnabled=true \
    --query QueueUrl --output text)
  aws sqs set-queue-attributes --queue-url "$url" --attributes \
    "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"${SQS_ARN}:${name}-dlq\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}"
  echo "$url"
}

VALIDATE_URL=$(create_queue_with_dlq ${PREFIX}-validate-queue)
OK_URL=$(create_queue_with_dlq ${PREFIX}-ok-queue)
NOK_URL=$(create_queue_with_dlq ${PREFIX}-nok-queue)
echo "Filas: $VALIDATE_URL | $OK_URL | $NOK_URL"

# --- S3 → SQS validate: apenas o bucket raw desta conta pode enviar ---
POLICY=$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"s3.amazonaws.com"},
 "Action":"sqs:SendMessage","Resource":"${SQS_ARN}:${PREFIX}-validate-queue",
 "Condition":{"ArnEquals":{"aws:SourceArn":"arn:aws:s3:::${BUCKET}"},
              "StringEquals":{"aws:SourceAccount":"${ACCOUNT_ID}"}}}]}
EOF
)
aws sqs set-queue-attributes --queue-url "$VALIDATE_URL" \
  --attributes "{\"Policy\":$(printf '%s' "$POLICY" | node -e 'process.stdout.write(JSON.stringify(require("fs").readFileSync(0,"utf8")))')}"
aws s3api put-bucket-notification-configuration --bucket "$BUCKET" --notification-configuration "{
  \"QueueConfigurations\":[{\"Id\":\"raw-to-validate\",\"QueueArn\":\"${SQS_ARN}:${PREFIX}-validate-queue\",
    \"Events\":[\"s3:ObjectCreated:*\"],
    \"Filter\":{\"Key\":{\"FilterRules\":[{\"Name\":\"prefix\",\"Value\":\"raw/\"},{\"Name\":\"suffix\",\"Value\":\".json\"}]}}}]}"

# --- Log group ---
aws logs create-log-group --log-group-name "$LOG_GROUP" --tags Project=ingest,Env=dev 2>/dev/null || true
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 14

# --- Role de execução ---
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --tags $TAGS --assume-role-policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow",
      "Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  echo "Role criada: $ROLE"
  NEW_ROLE=1
fi
aws iam put-role-policy --role-name "$ROLE" --policy-name app --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"${SQS_ARN}:${PREFIX}-validate-queue\"},
    {\"Effect\":\"Allow\",\"Action\":\"sqs:SendMessage\",\"Resource\":[\"${SQS_ARN}:${PREFIX}-ok-queue\",\"${SQS_ARN}:${PREFIX}-nok-queue\"]},
    {\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::${BUCKET}/raw/*\"},
    {\"Effect\":\"Allow\",\"Action\":\"kms:Decrypt\",\"Resource\":\"${KMS_KEY_ARN}\"},
    {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}:*\"}]}"
[ -n "${NEW_ROLE:-}" ] && sleep 10

# --- Pacote (código + dependências de produção) ---
BUILD=dist/${FN}
rm -rf "$BUILD" dist/${FN}.zip && mkdir -p "$BUILD"
cp src/decrypt-validate/*.js package.json package-lock.json "$BUILD"/
(cd "$BUILD" && npm ci --omit=dev --silent && zip -q -r ../${FN}.zip . -x package-lock.json)

# --- Função ---
ENV="Variables={RAW_BUCKET=${BUCKET},KMS_KEY_ID=${KMS_KEY_ARN},OK_QUEUE_URL=${OK_URL},NOK_QUEUE_URL=${NOK_URL}}"
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
  aws lambda wait function-updated-v2 --function-name "$FN"
  aws lambda update-function-configuration --function-name "$FN" --environment "$ENV" >/dev/null
  echo "Código atualizado: $FN"
fi
aws lambda wait function-updated-v2 --function-name "$FN"

# --- Event Source Mapping ---
ESM=$(aws lambda list-event-source-mappings --function-name "$FN" --event-source-arn "${SQS_ARN}:${PREFIX}-validate-queue" \
  --query 'EventSourceMappings[0].UUID' --output text)
if [ "$ESM" = "None" ]; then
  ESM=$(aws lambda create-event-source-mapping --function-name "$FN" --event-source-arn "${SQS_ARN}:${PREFIX}-validate-queue" \
    --batch-size 10 --maximum-batching-window-in-seconds 5 \
    --function-response-types ReportBatchItemFailures --query UUID --output text)
  echo "ESM criado: $ESM"
fi
echo "FN=$FN ESM=$ESM"
