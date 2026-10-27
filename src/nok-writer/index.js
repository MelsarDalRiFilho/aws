// SQS (ingest-nok-queue) → S3 nok. Grava nok/AAAA/MM/DD/<messageId>.json com motivo + envelope cifrado do raw.
const { S3Client, GetObjectCommand, PutObjectCommand } = require('@aws-sdk/client-s3');

const s3 = new S3Client({});
const { RAW_BUCKET, NOK_BUCKET } = process.env;

async function readEnvelope(rawKey) {
  try {
    const obj = await s3.send(new GetObjectCommand({ Bucket: RAW_BUCKET, Key: rawKey }));
    return JSON.parse(await obj.Body.transformToString()).envelope;
  } catch (err) {
    if (err.name === 'NoSuchKey') return null; // raw expirado: guarda o NOK mesmo assim
    throw err;
  }
}

async function processRecord(record) {
  const nok = JSON.parse(record.body);
  const day = new Date(nok.receivedAt).toISOString().slice(0, 10).replace(/-/g, '/');
  const key = `nok/${day}/${nok.messageId}.json`;
  const envelope = await readEnvelope(nok.rawKey);
  await s3.send(new PutObjectCommand({
    Bucket: NOK_BUCKET, Key: key, ContentType: 'application/json',
    Body: JSON.stringify({ ...nok, envelope }),
  }));
  console.log(JSON.stringify({ level: 'info', msg: 'nok gravado', messageId: nok.messageId, reason: nok.reason, key, envelopeFound: envelope !== null }));
}

exports.handler = async (event) => {
  const batchItemFailures = [];
  await Promise.all(event.Records.map(async (record) => {
    try {
      await processRecord(record);
    } catch (err) {
      console.error(JSON.stringify({ level: 'error', msg: 'falha ao gravar nok', sqsMessageId: record.messageId, error: err.message }));
      batchItemFailures.push({ itemIdentifier: record.messageId });
    }
  }));
  return { batchItemFailures };
};
