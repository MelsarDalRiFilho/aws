#!/usr/bin/env bash
# Remove TODOS os recursos do pipeline (Fases 1–7). Irreversível: apaga dados do S3 e do DynamoDB.
# Uso: ./infra/teardown.sh --confirm
set -uo pipefail
source "$(dirname "$0")/config.sh"

if [ "${1:-}" != "--confirm" ]; then
  echo "Isto apaga todos os recursos e dados do pipeline '${PREFIX}' em ${AWS_REGION}. Rode com --confirm."
  exit 1
fi

FNS="raw-writer decrypt-validate enrich nok-writer"
QUEUES="queue validate-queue ok-queue nok-queue"
API_ID=$(aws apigateway get-rest-apis --query "items[?name=='${PREFIX}-api'].id | [0]" --output text)

echo "== Lambdas, ESMs, roles e logs"
for f in $FNS; do
  FN=${PREFIX}-$f
  for uuid in $(aws lambda list-event-source-mappings --function-name "$FN" --query 'EventSourceMappings[].UUID' --output text 2>/dev/null); do
    aws lambda delete-event-source-mapping --uuid "$uuid" >/dev/null
  done
  aws lambda delete-function --function-name "$FN" 2>/dev/null
  aws iam delete-role-policy --role-name "${FN}-role" --policy-name app 2>/dev/null
  aws iam delete-role --role-name "${FN}-role" 2>/dev/null
  aws logs delete-log-group --log-group-name "/aws/lambda/${FN}" 2>/dev/null
done

echo "== API Gateway"
for plan in $(aws apigateway get-usage-plans --query "items[?name=='${PREFIX}-plan'].id" --output text); do
  for key in $(aws apigateway get-usage-plan-keys --usage-plan-id "$plan" --query 'items[].id' --output text); do
    aws apigateway delete-usage-plan-key --usage-plan-id "$plan" --key-id "$key"
  done
  aws apigateway update-usage-plan --usage-plan-id "$plan" \
    --patch-operations op=remove,path=/apiStages,value=${API_ID}:dev >/dev/null 2>&1
  aws apigateway delete-usage-plan --usage-plan-id "$plan"
done
for key in $(aws apigateway get-api-keys --name-query ${PREFIX}-key --query 'items[].id' --output text); do
  aws apigateway delete-api-key --api-key "$key"
done
[ "$API_ID" != "None" ] && aws apigateway delete-rest-api --rest-api-id "$API_ID"
aws iam delete-role-policy --role-name ${PREFIX}-apigw-sqs-role --policy-name sqs-send 2>/dev/null
aws iam delete-role --role-name ${PREFIX}-apigw-sqs-role 2>/dev/null
aws logs delete-log-group --log-group-name /aws/apigateway/${PREFIX}-api 2>/dev/null

echo "== SQS"
for q in $QUEUES; do
  for name in ${PREFIX}-$q ${PREFIX}-$q-dlq; do
    URL=$(aws sqs get-queue-url --queue-name "$name" --query QueueUrl --output text 2>/dev/null) && aws sqs delete-queue --queue-url "$URL"
  done
done

echo "== S3 (todas as versões)"
for kind in raw nok; do
  BUCKET=${PREFIX}-${kind}-${ACCOUNT_ID}
  aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null || continue
  aws s3api put-bucket-notification-configuration --bucket "$BUCKET" --notification-configuration '{}'
  while :; do
    OBJS=$(aws s3api list-object-versions --bucket "$BUCKET" --max-items 500 --output json \
      --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}')
    [ "$(echo "$OBJS" | node -e 'const o=JSON.parse(require("fs").readFileSync(0));process.stdout.write(String((o.Objects||[]).length))')" = 0 ] && break
    aws s3api delete-objects --bucket "$BUCKET" --delete "$OBJS" >/dev/null
  done
  aws s3api delete-bucket --bucket "$BUCKET"
done

echo "== DynamoDB"
for t in devices data nonces; do aws dynamodb delete-table --table-name ${PREFIX}-$t >/dev/null 2>&1; done

echo "== CloudWatch e SNS"
aws cloudwatch delete-alarms --alarm-names ${PREFIX}-dlq-mensagens ${PREFIX}-lambda-erros ${PREFIX}-fila-parada ${PREFIX}-api-5xx ${PREFIX}-nok-alto
aws cloudwatch delete-dashboards --dashboard-names ${PREFIX} 2>/dev/null
aws sns delete-topic --topic-arn arn:aws:sns:${AWS_REGION}:${ACCOUNT_ID}:${PREFIX}-alerts

echo "== KMS (exclusão agendada em 7 dias; cancelável com 'aws kms cancel-key-deletion')"
KEY_ID=$(aws kms describe-key --key-id alias/${PREFIX}-payload --query KeyMetadata.KeyId --output text 2>/dev/null) && {
  aws kms delete-alias --alias-name alias/${PREFIX}-payload
  aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7 >/dev/null
}

echo "Concluído. Mantidos de propósito: a role 'apigateway-cloudwatch-logs-role' (configuração da conta do API Gateway)."
