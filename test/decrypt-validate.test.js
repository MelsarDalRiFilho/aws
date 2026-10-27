const crypto = require('node:crypto');

const mockS3 = jest.fn();
const mockKms = jest.fn();
const mockSqs = jest.fn();
const mockDdb = jest.fn();
jest.mock('@aws-sdk/client-dynamodb', () => ({ DynamoDBClient: jest.fn() }));
jest.mock('@aws-sdk/lib-dynamodb', () => ({
  DynamoDBDocumentClient: { from: () => ({ send: mockDdb }) },
  PutCommand: jest.fn((input) => input),
}));
jest.mock('@aws-sdk/client-s3', () => ({
  S3Client: jest.fn(() => ({ send: mockS3 })),
  GetObjectCommand: jest.fn((input) => input),
}));
jest.mock('@aws-sdk/client-kms', () => ({
  KMSClient: jest.fn(() => ({ send: mockKms })),
  DecryptCommand: jest.fn((input) => input),
}));
jest.mock('@aws-sdk/client-sqs', () => ({
  SQSClient: jest.fn(() => ({ send: mockSqs })),
  SendMessageCommand: jest.fn((input) => input),
}));

Object.assign(process.env, {
  RAW_BUCKET: 'raw', KMS_KEY_ID: 'chave', OK_QUEUE_URL: 'ok-url', NOK_QUEUE_URL: 'nok-url', NONCES_TABLE: 'nonces',
});
const { handler } = require('../src/decrypt-validate');
const { encryptEnvelope } = require('../tools/encrypt-envelope');

// Par RSA local fazendo o papel do KMS.
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const publicDer = publicKey.export({ format: 'der', type: 'spki' });
const kmsDecrypt = (input) => {
  try {
    return { Plaintext: crypto.privateDecrypt({ key: privateKey, padding: crypto.constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' }, input.CiphertextBlob) };
  } catch {
    throw Object.assign(new Error('bad'), { name: 'InvalidCiphertextException' });
  }
};

const valid = {
  deviceId: 'abc123', timestamp: '2026-10-27T20:00:00Z', type: 'telemetry', nonce: 'n0nce-aleatorio-123',
  data: { lat: -23.5, lon: -46.6, battery: 87, Tamper: 1, Motion: 0, Impact: 0, InternalMoisture: 1, MetallicMaterial: 0, Jamming: 0 },
};
const RECEIVED_AT = Date.parse(valid.timestamp) + 60_000; // chegou 1 min depois da leitura

function rawWith(envelope) {
  return { Body: { transformToString: async () => JSON.stringify({ messageId: 'm1', receivedAt: RECEIVED_AT, sourceIp: 'ip', requestId: 'r1', envelope }) } };
}
const s3Event = (key) => ({ Records: [{ messageId: 'sqs-1', body: JSON.stringify({ Records: [{ s3: { object: { key } } }] }) }] });

async function run(envelope) {
  mockS3.mockResolvedValue(rawWith(envelope));
  const res = await handler(s3Event('raw/2026/10/27/m1.json'));
  const sent = mockSqs.mock.calls.map(([cmd]) => ({ queue: cmd.QueueUrl, body: JSON.parse(cmd.MessageBody) }));
  return { res, sent };
}

beforeEach(() => {
  [mockS3, mockKms, mockSqs, mockDdb].forEach((m) => m.mockReset());
  mockKms.mockImplementation(async (input) => kmsDecrypt(input));
  mockSqs.mockResolvedValue({});
  mockDdb.mockResolvedValue({});
  jest.spyOn(console, 'log').mockImplementation(() => {});
  jest.spyOn(console, 'error').mockImplementation(() => {});
});

test('payload válido vai para a fila OK com os metadados', async () => {
  const { res, sent } = await run(encryptEnvelope(JSON.stringify(valid), publicDer));
  expect(res.batchItemFailures).toEqual([]);
  expect(sent).toEqual([{ queue: 'ok-url', body: { messageId: 'm1', receivedAt: RECEIVED_AT, sourceIp: 'ip', requestId: 'r1', rawKey: 'raw/2026/10/27/m1.json', payload: valid } }]);
  expect(mockDdb.mock.calls[0][0]).toMatchObject({
    TableName: 'nonces',
    Item: { id: 'abc123#n0nce-aleatorio-123', messageId: 'm1' },
    ConditionExpression: 'attribute_not_exists(id) OR messageId = :m',
    ExpressionAttributeValues: { ':m': 'm1' },
  });
});

test('apenas os obrigatórios é válido', async () => {
  const { sent } = await run(encryptEnvelope(JSON.stringify({ deviceId: 'd', timestamp: '2026-10-27T20:00:00Z', type: 'telemetry', nonce: 'abcdefghijklmnop' }), publicDer));
  expect(sent[0].queue).toBe('ok-url');
});

test('nonce já usado (outro messageId) vai para NOK replay', async () => {
  mockDdb.mockRejectedValue(Object.assign(new Error('x'), { name: 'ConditionalCheckFailedException' }));
  const { res, sent } = await run(encryptEnvelope(JSON.stringify(valid), publicDer));
  expect(res.batchItemFailures).toEqual([]);
  expect(sent.map((s) => [s.queue, s.body.reason])).toEqual([['nok-url', 'replay']]);
});

test.each([
  ['mais de 24 h atrás', '2026-10-26T19:00:00Z'],
  ['mais de 5 min no futuro', '2026-10-27T20:10:00Z'],
])('timestamp %s vai para NOK fora_da_janela', async (_, timestamp) => {
  const { sent } = await run(encryptEnvelope(JSON.stringify({ ...valid, timestamp }), publicDer));
  expect(sent.map((s) => s.body.reason)).toEqual(['fora_da_janela']);
  expect(mockDdb).not.toHaveBeenCalled();
});

test('leitura de 23 h atrás (buffer offline) é aceita', async () => {
  const { sent } = await run(encryptEnvelope(JSON.stringify({ ...valid, timestamp: '2026-10-26T21:30:00Z' }), publicDer));
  expect(sent[0].queue).toBe('ok-url');
});

test('erro temporário do DynamoDB gera retry, sem NOK', async () => {
  mockDdb.mockRejectedValue(Object.assign(new Error('x'), { name: 'ProvisionedThroughputExceededException' }));
  const { res, sent } = await run(encryptEnvelope(JSON.stringify(valid), publicDer));
  expect(res.batchItemFailures).toEqual([{ itemIdentifier: 'sqs-1' }]);
  expect(sent).toEqual([]);
});

test.each([
  ['sem nonce', { ...valid, nonce: undefined }],
  ['nonce curto', { ...valid, nonce: 'curto' }],
  ['sem deviceId', { ...valid, deviceId: undefined }],
  ['type desconhecido', { ...valid, type: 'outro' }],
  ['timestamp inválido', { ...valid, timestamp: 'ontem' }],
  ['sensor fora de 0/1', { ...valid, data: { ...valid.data, Tamper: 2 } }],
  ['battery > 100', { ...valid, data: { ...valid.data, battery: 120 } }],
  ['campo extra', { ...valid, extra: 1 }],
])('schema inválido (%s) vai para NOK', async (_, payload) => {
  const { res, sent } = await run(encryptEnvelope(JSON.stringify(payload), publicDer));
  expect(res.batchItemFailures).toEqual([]);
  expect(sent).toHaveLength(1);
  expect(sent[0].queue).toBe('nok-url');
  expect(sent[0].body.reason).toBe('schema_invalido');
  expect(sent[0].body.payload).toBeUndefined();
});

test('JSON inválido vai para NOK', async () => {
  const { sent } = await run(encryptEnvelope('não é json', publicDer));
  expect(sent[0].body.reason).toBe('json_invalido');
});

test('ciphertext adulterado vai para NOK (tag GCM)', async () => {
  const env = encryptEnvelope(JSON.stringify(valid), publicDer);
  const ct = Buffer.from(env.ct, 'base64'); ct[0] ^= 0xff;
  const { sent } = await run({ ...env, ct: ct.toString('base64') });
  expect(sent[0].body.reason).toBe('falha_decifrar');
});

test('chave cifrada inválida vai para NOK', async () => {
  const env = encryptEnvelope(JSON.stringify(valid), publicDer);
  const { sent } = await run({ ...env, ek: Buffer.from('lixo').toString('base64') });
  expect(sent[0].body.reason).toBe('ek_invalida');
});

test('erro temporário do KMS gera retry, sem NOK', async () => {
  mockKms.mockReset().mockRejectedValue(Object.assign(new Error('rate'), { name: 'ThrottlingException' }));
  const { res, sent } = await run(encryptEnvelope(JSON.stringify(valid), publicDer));
  expect(res.batchItemFailures).toEqual([{ itemIdentifier: 'sqs-1' }]);
  expect(sent).toEqual([]);
});

test('s3:TestEvent é ignorado', async () => {
  const res = await handler({ Records: [{ messageId: 't', body: JSON.stringify({ Event: 's3:TestEvent' }) }] });
  expect(res.batchItemFailures).toEqual([]);
  expect(mockS3).not.toHaveBeenCalled();
});
