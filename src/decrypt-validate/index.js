// SQS (eventos S3 do raw) → KMS decrypt + validação → SQS ok | SQS nok.
const crypto = require('node:crypto');
const { S3Client, GetObjectCommand } = require('@aws-sdk/client-s3');
const { KMSClient, DecryptCommand } = require('@aws-sdk/client-kms');
const { SQSClient, SendMessageCommand } = require('@aws-sdk/client-sqs');
const Ajv = require('ajv');
const schema = require('./schema');

const s3 = new S3Client({});
const kms = new KMSClient({});
const sqs = new SQSClient({});
const validate = new Ajv({ allErrors: true }).compile(schema);
const { RAW_BUCKET, KMS_KEY_ID, OK_QUEUE_URL, NOK_QUEUE_URL } = process.env;

// Erro de conteúdo: a mensagem vai para NOK em vez de ser reprocessada.
class InvalidPayload extends Error {
  constructor(reason, details) {
    super(reason);
    this.reason = reason;
    this.details = details;
  }
}

async function decryptEnvelope({ ek, iv, tag, ct }) {
  let key;
  try {
    const res = await kms.send(new DecryptCommand({
      KeyId: KMS_KEY_ID,
      CiphertextBlob: Buffer.from(ek, 'base64'),
      EncryptionAlgorithm: 'RSAES_OAEP_SHA_256',
    }));
    key = Buffer.from(res.Plaintext);
  } catch (err) {
    if (err.name === 'InvalidCiphertextException') throw new InvalidPayload('ek_invalida');
    throw err;
  }
  try {
    const decipher = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(iv, 'base64'));
    decipher.setAuthTag(Buffer.from(tag, 'base64'));
    return Buffer.concat([decipher.update(Buffer.from(ct, 'base64')), decipher.final()]).toString('utf8');
  } catch {
    throw new InvalidPayload('falha_decifrar');
  }
}

function parseAndValidate(plaintext) {
  let payload;
  try {
    payload = JSON.parse(plaintext);
  } catch {
    throw new InvalidPayload('json_invalido');
  }
  if (!validate(payload)) {
    throw new InvalidPayload('schema_invalido', validate.errors.map((e) => `${e.instancePath || '/'} ${e.message}`));
  }
  return payload;
}

async function processObject(rawKey) {
  const obj = await s3.send(new GetObjectCommand({ Bucket: RAW_BUCKET, Key: rawKey }));
  const raw = JSON.parse(await obj.Body.transformToString());
  const meta = { messageId: raw.messageId, receivedAt: raw.receivedAt, sourceIp: raw.sourceIp, requestId: raw.requestId, rawKey };

  try {
    const payload = parseAndValidate(await decryptEnvelope(raw.envelope));
    await sqs.send(new SendMessageCommand({ QueueUrl: OK_QUEUE_URL, MessageBody: JSON.stringify({ ...meta, payload }) }));
    console.log(JSON.stringify({ level: 'info', msg: 'ok', ...meta, deviceId: payload.deviceId }));
  } catch (err) {
    if (!(err instanceof InvalidPayload)) throw err;
    await sqs.send(new SendMessageCommand({
      QueueUrl: NOK_QUEUE_URL,
      MessageBody: JSON.stringify({ ...meta, reason: err.reason, details: err.details }),
    }));
    console.log(JSON.stringify({ level: 'warn', msg: 'nok', ...meta, reason: err.reason, details: err.details }));
  }
}

// Cada mensagem SQS traz um evento S3 (ou o s3:TestEvent enviado ao configurar a notificação).
function rawKeysOf(record) {
  const event = JSON.parse(record.body);
  return (event.Records || []).map((r) => decodeURIComponent(r.s3.object.key.replace(/\+/g, ' ')));
}

exports.handler = async (event) => {
  const batchItemFailures = [];
  await Promise.all(event.Records.map(async (record) => {
    try {
      await Promise.all(rawKeysOf(record).map(processObject));
    } catch (err) {
      console.error(JSON.stringify({ level: 'error', msg: 'falha temporária', sqsMessageId: record.messageId, error: err.message }));
      batchItemFailures.push({ itemIdentifier: record.messageId });
    }
  }));
  return { batchItemFailures };
};
