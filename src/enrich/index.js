// SQS (ingest-ok-queue) → cadastro ingest-devices → DynamoDB ingest-data (ou NOK se dispositivo inválido).
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, GetCommand, PutCommand } = require('@aws-sdk/lib-dynamodb');
const { SQSClient, SendMessageCommand } = require('@aws-sdk/client-sqs');

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const sqs = new SQSClient({});
const { DEVICES_TABLE, DATA_TABLE, NOK_QUEUE_URL } = process.env;

async function sendNok(meta, reason) {
  await sqs.send(new SendMessageCommand({ QueueUrl: NOK_QUEUE_URL, MessageBody: JSON.stringify({ ...meta, reason }) }));
  console.log(JSON.stringify({ level: 'warn', msg: 'nok', ...meta, reason }));
}

async function processRecord(record) {
  const { payload, ...meta } = JSON.parse(record.body);
  const { Item: device } = await ddb.send(new GetCommand({ TableName: DEVICES_TABLE, Key: { deviceId: payload.deviceId } }));
  if (!device) return sendNok(meta, 'dispositivo_nao_cadastrado');
  if (device.status !== 'active') return sendNok(meta, 'dispositivo_inativo');

  const { deviceId, status, ...snapshot } = device;
  try {
    await ddb.send(new PutCommand({
      TableName: DATA_TABLE,
      Item: {
        deviceId,
        sk: `${payload.timestamp}#${meta.messageId}`,
        timestamp: payload.timestamp,
        type: payload.type,
        data: payload.data,
        device: snapshot,
        ...meta,
      },
      ConditionExpression: 'attribute_not_exists(sk)',
    }));
  } catch (err) {
    // Reprocessamento da mesma mensagem: o item já existe, então é sucesso.
    if (err.name !== 'ConditionalCheckFailedException') throw err;
  }
  console.log(JSON.stringify({ level: 'info', msg: 'gravado', messageId: meta.messageId, deviceId }));
}

exports.handler = async (event) => {
  const batchItemFailures = [];
  await Promise.all(event.Records.map(async (record) => {
    try {
      await processRecord(record);
    } catch (err) {
      console.error(JSON.stringify({ level: 'error', msg: 'falha no enriquecimento', sqsMessageId: record.messageId, error: err.message }));
      batchItemFailures.push({ itemIdentifier: record.messageId });
    }
  }));
  return { batchItemFailures };
};
