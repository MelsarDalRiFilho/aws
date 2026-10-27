#!/usr/bin/env bash
# Fase 7: SNS de alertas, access logs do API Gateway, metric filters OK/NOK, alarmes e dashboard. Idempotente.
set -euo pipefail
source "$(dirname "$0")/config.sh"

ALERT_EMAIL=${ALERT_EMAIL:-melsar.filho@gmail.com}
API_ID=025tr6hq7g
STAGE=dev
API_LOG_GROUP=/aws/apigateway/${PREFIX}-api
CW_ROLE=apigateway-cloudwatch-logs-role

# --- SNS ---
TOPIC_ARN=$(aws sns create-topic --name ${PREFIX}-alerts --tags $TAGS --query TopicArn --output text)
if ! aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" \
     --query "Subscriptions[?Endpoint=='${ALERT_EMAIL}']" --output text | grep -q .; then
  aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$ALERT_EMAIL" >/dev/null
  echo "Assinatura criada para $ALERT_EMAIL (confirme pelo e-mail)"
fi

# --- Role de logs do API Gateway (configuração única da conta; não sobrescreve se já existir) ---
CURRENT=$(aws apigateway get-account --query cloudwatchRoleArn --output text)
if [ "$CURRENT" = "None" ]; then
  if ! aws iam get-role --role-name "$CW_ROLE" >/dev/null 2>&1; then
    aws iam create-role --role-name "$CW_ROLE" --tags $TAGS --assume-role-policy-document '{
      "Version":"2012-10-17","Statement":[{"Effect":"Allow",
        "Principal":{"Service":"apigateway.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    aws iam attach-role-policy --role-name "$CW_ROLE" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs
    sleep 10
  fi
  aws apigateway update-account --patch-operations \
    op=replace,path=/cloudwatchRoleArn,value=arn:aws:iam::${ACCOUNT_ID}:role/${CW_ROLE} >/dev/null
  echo "Role de logs do API Gateway configurada"
else
  echo "Conta já tem role de logs do API Gateway: $CURRENT"
fi

# --- Access logs do stage ---
aws logs create-log-group --log-group-name "$API_LOG_GROUP" --tags Project=ingest,Env=dev 2>/dev/null || true
aws logs put-retention-policy --log-group-name "$API_LOG_GROUP" --retention-in-days 14
FORMAT='{"requestId":"$context.requestId","ip":"$context.identity.sourceIp","time":"$context.requestTime","status":"$context.status","latency":"$context.responseLatency","len":"$context.requestLength","error":"$context.error.message","integrationError":"$context.integration.error"}'
PATCH=$(DEST="arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${API_LOG_GROUP}" FORMAT="$FORMAT" node -e '
  process.stdout.write(JSON.stringify([
    { op: "replace", path: "/accessLogSettings/destinationArn", value: process.env.DEST },
    { op: "replace", path: "/accessLogSettings/format", value: process.env.FORMAT },
  ]))')
aws apigateway update-stage --rest-api-id "$API_ID" --stage-name "$STAGE" --patch-operations "$PATCH" >/dev/null
echo "Access logs: $API_LOG_GROUP"

# --- Metric filters (logs JSON das Lambdas) ---
metric_filter() { # log-group nome-filtro padrão métrica
  aws logs put-metric-filter --log-group-name "$1" --filter-name "$2" --filter-pattern "$3" \
    --metric-transformations metricName=$4,metricNamespace=Ingest,metricValue=1,defaultValue=0,unit=Count
}
metric_filter /aws/lambda/${PREFIX}-decrypt-validate nok '{ $.msg = "nok" }' Nok
metric_filter /aws/lambda/${PREFIX}-enrich nok '{ $.msg = "nok" }' Nok
metric_filter /aws/lambda/${PREFIX}-enrich ok '{ $.msg = "gravado" }' Ok

# --- Alarmes ---
COMMON=(--alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN" --treat-missing-data notBreaching --tags $TAGS)

dlq_metric() { # id fila
  echo "{\"Id\":\"$1\",\"ReturnData\":false,\"MetricStat\":{\"Metric\":{\"Namespace\":\"AWS/SQS\",\"MetricName\":\"ApproximateNumberOfMessagesVisible\",\"Dimensions\":[{\"Name\":\"QueueName\",\"Value\":\"$2\"}]},\"Period\":300,\"Stat\":\"Maximum\"}}"
}
aws cloudwatch put-metric-alarm --alarm-name ${PREFIX}-dlq-mensagens \
  --alarm-description "Há mensagens em alguma DLQ do pipeline (falha após 3 tentativas)" \
  --comparison-operator GreaterThanThreshold --threshold 0 --evaluation-periods 1 \
  --metrics "[$(dlq_metric a ${PREFIX}-queue-dlq),$(dlq_metric b ${PREFIX}-validate-queue-dlq),$(dlq_metric c ${PREFIX}-ok-queue-dlq),$(dlq_metric d ${PREFIX}-nok-queue-dlq),
    {\"Id\":\"total\",\"Expression\":\"a+b+c+d\",\"Label\":\"Mensagens nas DLQs\",\"ReturnData\":true}]" \
  "${COMMON[@]}"

aws cloudwatch put-metric-alarm --alarm-name ${PREFIX}-lambda-erros \
  --alarm-description "Erros de Lambda na conta (só há Lambdas do pipeline)" \
  --namespace AWS/Lambda --metric-name Errors --statistic Sum --period 300 \
  --comparison-operator GreaterThanThreshold --threshold 0 --evaluation-periods 1 "${COMMON[@]}"

aws cloudwatch put-metric-alarm --alarm-name ${PREFIX}-fila-parada \
  --alarm-description "Mensagem mais antiga da ingest-queue com mais de 5 min (consumidor travado)" \
  --namespace AWS/SQS --metric-name ApproximateAgeOfOldestMessage --dimensions Name=QueueName,Value=${PREFIX}-queue \
  --statistic Maximum --period 300 \
  --comparison-operator GreaterThanThreshold --threshold 300 --evaluation-periods 1 "${COMMON[@]}"

aws cloudwatch put-metric-alarm --alarm-name ${PREFIX}-api-5xx \
  --alarm-description "Erros 5XX no API Gateway (falha ao enfileirar)" \
  --namespace AWS/ApiGateway --metric-name 5XXError --dimensions Name=ApiName,Value=${PREFIX}-api Name=Stage,Value=${STAGE} \
  --statistic Sum --period 300 \
  --comparison-operator GreaterThanThreshold --threshold 0 --evaluation-periods 1 "${COMMON[@]}"

aws cloudwatch put-metric-alarm --alarm-name ${PREFIX}-nok-alto \
  --alarm-description "Mais de 20 NOK em 5 min (app com bug ou tentativa de abuso)" \
  --namespace Ingest --metric-name Nok --statistic Sum --period 300 \
  --comparison-operator GreaterThanThreshold --threshold 20 --evaluation-periods 1 "${COMMON[@]}"
echo "Alarmes criados"

# --- Dashboard ---
R=$AWS_REGION
lambda_metric() { echo "[\"AWS/Lambda\",\"$1\",\"FunctionName\",\"${PREFIX}-$2\"]"; }
queue_metric() { echo "[\"AWS/SQS\",\"ApproximateNumberOfMessagesVisible\",\"QueueName\",\"${PREFIX}-$1\"]"; }
FNS="raw-writer decrypt-validate enrich nok-writer"
INV=$(for f in $FNS; do lambda_metric Invocations $f; done | paste -sd,)
ERR=$(for f in $FNS; do lambda_metric Errors $f; done | paste -sd,)
DUR=$(for f in $FNS; do echo "[\"AWS/Lambda\",\"Duration\",\"FunctionName\",\"${PREFIX}-$f\",{\"stat\":\"p95\"}]"; done | paste -sd,)
QS=$(for q in queue validate-queue ok-queue nok-queue; do queue_metric $q; done | paste -sd,)
DLQS=$(for q in queue-dlq validate-queue-dlq ok-queue-dlq nok-queue-dlq; do queue_metric $q; done | paste -sd,)
widget() { # x y título métricas [stat]
  echo "{\"type\":\"metric\",\"x\":$1,\"y\":$2,\"width\":12,\"height\":6,\"properties\":{\"title\":\"$3\",\"region\":\"$R\",\"view\":\"timeSeries\",\"stat\":\"${5:-Sum}\",\"period\":300,\"metrics\":[$4]}}"
}
API="[\"AWS/ApiGateway\",\"Count\",\"ApiName\",\"${PREFIX}-api\",\"Stage\",\"$STAGE\"],[\".\",\"4XXError\",\".\",\".\",\".\",\".\"],[\".\",\"5XXError\",\".\",\".\",\".\",\".\"]"
OKNOK="[\"Ingest\",\"Ok\"],[\"Ingest\",\"Nok\"]"
BODY="{\"widgets\":[
  $(widget 0 0 'API Gateway: requisições e erros' "$API"),
  $(widget 12 0 'Resultado: OK x NOK' "$OKNOK"),
  $(widget 0 6 'Filas: mensagens visíveis' "$QS" Maximum),
  $(widget 12 6 'DLQs: mensagens visíveis' "$DLQS" Maximum),
  $(widget 0 12 'Lambda: invocações' "$INV"),
  $(widget 12 12 'Lambda: erros' "$ERR"),
  $(widget 0 18 'Lambda: duração p95 (ms)' "$DUR" p95)]}"
aws cloudwatch put-dashboard --dashboard-name ${PREFIX} --dashboard-body "$BODY" >/dev/null
echo "Dashboard: https://${R}.console.aws.amazon.com/cloudwatch/home?region=${R}#dashboards/dashboard/${PREFIX}"
echo "TOPIC_ARN=$TOPIC_ARN"
