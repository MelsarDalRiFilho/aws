// SQS (ingest-queue) → S3 raw. Grava cada mensagem em raw/AAAA/MM/DD/<messageId>.json.
const { S3Client, PutObjectCommand } = require('@aws-sdk/client-s3');

const s3 = new S3Client({});
const BUCKET = process.env.RAW_BUCKET;

function attr(record, name) {
  return record.messageAttributes?.[name]?.stringValue;
}

function buildObject(record) {
  const receivedAt = Number(attr(record, 'receivedAt')) || Number(record.attributes.SentTimestamp);
  const day = new Date(receivedAt).toISOString().slice(0, 10).replace(/-/g, '/');
  return {
    key: `raw/${day}/${record.messageId}.json`,
    body: JSON.stringify({
      messageId: record.messageId,
      receivedAt,
      sourceIp: attr(record, 'sourceIp'),
      requestId: attr(record, 'requestId'),
      envelope: JSON.parse(record.body),
    }),
  };
}

exports.handler = async (event) => {
  const batchItemFailures = [];
  await Promise.all(event.Records.map(async (record) => {
    try {
      const { key, body } = buildObject(record);
      await s3.send(new PutObjectCommand({
        Bucket: BUCKET, Key: key, Body: body, ContentType: 'application/json',
      }));
      console.log(JSON.stringify({ level: 'info', msg: 'raw gravado', messageId: record.messageId, key }));
    } catch (err) {
      console.error(JSON.stringify({ level: 'error', msg: 'falha ao gravar raw', messageId: record.messageId, error: err.message }));
      batchItemFailures.push({ itemIdentifier: record.messageId });
    }
  }));
  return { batchItemFailures };
};

exports.buildObject = buildObject;
