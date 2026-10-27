#!/usr/bin/env bash
# Fase 2: SQS de ingestão (+DLQ) e API Gateway REST com API Key integrada direto ao SQS. Idempotente.
set -euo pipefail
source "$(dirname "$0")/config.sh"

QUEUE=${PREFIX}-queue
DLQ=${PREFIX}-queue-dlq
ROLE=${PREFIX}-apigw-sqs-role
API_NAME=${PREFIX}-api
STAGE=dev

# --- SQS ---
DLQ_URL=$(aws sqs create-queue --queue-name "$DLQ" --tags Project=ingest,Env=dev \
  --attributes MessageRetentionPeriod=1209600,SqsManagedSseEnabled=true --query QueueUrl --output text)
DLQ_ARN=arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${DLQ}
QUEUE_URL=$(aws sqs create-queue --queue-name "$QUEUE" --tags Project=ingest,Env=dev \
  --attributes VisibilityTimeout=180,MessageRetentionPeriod=345600,SqsManagedSseEnabled=true \
  --query QueueUrl --output text)
QUEUE_ARN=arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${QUEUE}
aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes \
  "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}"
echo "Filas: $QUEUE_URL | $DLQ_URL"

# --- Role do API Gateway (apenas SendMessage nesta fila) ---
# Sem condição aws:SourceAccount: o API Gateway não envia essa chave ao assumir a role de integração.
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"Service":"apigateway.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --tags $TAGS --assume-role-policy-document "$TRUST" >/dev/null
  echo "Role criada: $ROLE"
else
  aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "$TRUST"
fi
aws iam put-role-policy --role-name "$ROLE" --policy-name sqs-send --policy-document "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"${QUEUE_ARN}\"}]}"
ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/${ROLE}
sleep 10 # propagação da role no IAM

# --- REST API ---
API_ID=$(aws apigateway get-rest-apis --query "items[?name=='${API_NAME}'].id | [0]" --output text)
if [ "$API_ID" = "None" ]; then
  API_ID=$(aws apigateway create-rest-api --name "$API_NAME" \
    --endpoint-configuration types=REGIONAL --tags Project=ingest,Env=dev --query id --output text)
  echo "API criada: $API_ID"
fi
ROOT_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --query "items[?path=='/'].id | [0]" --output text)
RES_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --query "items[?path=='/ingest'].id | [0]" --output text)
if [ "$RES_ID" = "None" ]; then
  RES_ID=$(aws apigateway create-resource --rest-api-id "$API_ID" --parent-id "$ROOT_ID" \
    --path-part ingest --query id --output text)
fi

# Modelo do envelope criptografado (ct limitado a 200.000 caracteres)
if ! aws apigateway get-model --rest-api-id "$API_ID" --model-name Envelope >/dev/null 2>&1; then
  aws apigateway create-model --rest-api-id "$API_ID" --name Envelope --content-type application/json \
    --schema '{
      "$schema":"http://json-schema.org/draft-04/schema#","type":"object",
      "required":["v","ek","iv","tag","ct"],"additionalProperties":false,
      "properties":{
        "v":{"type":"integer","enum":[1]},
        "ek":{"type":"string","maxLength":1024},
        "iv":{"type":"string","maxLength":32},
        "tag":{"type":"string","maxLength":32},
        "ct":{"type":"string","minLength":1,"maxLength":200000}}}' >/dev/null
fi
VALIDATOR_ID=$(aws apigateway get-request-validators --rest-api-id "$API_ID" \
  --query "items[?name=='body'].id | [0]" --output text)
if [ "$VALIDATOR_ID" = "None" ]; then
  VALIDATOR_ID=$(aws apigateway create-request-validator --rest-api-id "$API_ID" --name body \
    --validate-request-body --query id --output text)
fi

aws apigateway delete-method --rest-api-id "$API_ID" --resource-id "$RES_ID" --http-method POST 2>/dev/null || true
aws apigateway put-method --rest-api-id "$API_ID" --resource-id "$RES_ID" --http-method POST \
  --authorization-type NONE --api-key-required \
  --request-validator-id "$VALIDATOR_ID" --request-models application/json=Envelope >/dev/null
aws apigateway put-integration --rest-api-id "$API_ID" --resource-id "$RES_ID" --http-method POST \
  --type AWS --integration-http-method POST \
  --uri "arn:aws:apigateway:${AWS_REGION}:sqs:path/${ACCOUNT_ID}/${QUEUE}" \
  --credentials "$ROLE_ARN" --passthrough-behavior NEVER \
  --request-parameters "integration.request.header.Content-Type=\"'application/x-www-form-urlencoded'\"" \
  --request-templates '{"application/json":"Action=SendMessage&MessageBody=$util.urlEncode($input.body)"}' >/dev/null

for code in 200 502; do
  aws apigateway put-method-response --rest-api-id "$API_ID" --resource-id "$RES_ID" \
    --http-method POST --status-code $code --response-models application/json=Empty >/dev/null
done
aws apigateway put-integration-response --rest-api-id "$API_ID" --resource-id "$RES_ID" \
  --http-method POST --status-code 200 --selection-pattern "" \
  --response-templates '{"application/json":"{\"messageId\":$input.json('"'"'$.SendMessageResponse.SendMessageResult.MessageId'"'"')}"}' >/dev/null
aws apigateway put-integration-response --rest-api-id "$API_ID" --resource-id "$RES_ID" \
  --http-method POST --status-code 502 --selection-pattern "[45]\d{2}" \
  --response-templates '{"application/json":"{\"message\":\"falha ao enfileirar\"}"}' >/dev/null

aws apigateway create-deployment --rest-api-id "$API_ID" --stage-name "$STAGE" >/dev/null
echo "Deploy: https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/${STAGE}/ingest"

# --- Usage Plan + API Key ---
PLAN_ID=$(aws apigateway get-usage-plans --query "items[?name=='${PREFIX}-plan'].id | [0]" --output text)
if [ "$PLAN_ID" = "None" ]; then
  PLAN_ID=$(aws apigateway create-usage-plan --name ${PREFIX}-plan \
    --api-stages apiId=${API_ID},stage=${STAGE} \
    --throttle rateLimit=10,burstLimit=20 --quota limit=10000,period=DAY \
    --tags Project=ingest,Env=dev --query id --output text)
fi
KEY_ID=$(aws apigateway get-api-keys --name-query ${PREFIX}-key --query "items[0].id" --output text)
if [ "$KEY_ID" = "None" ]; then
  KEY_ID=$(aws apigateway create-api-key --name ${PREFIX}-key --enabled \
    --tags Project=ingest,Env=dev --query id --output text)
  aws apigateway create-usage-plan-key --usage-plan-id "$PLAN_ID" --key-id "$KEY_ID" --key-type API_KEY >/dev/null
fi
echo "API_ID=$API_ID PLAN_ID=$PLAN_ID KEY_ID=$KEY_ID"
