const mockSend = jest.fn();
jest.mock('@aws-sdk/client-s3', () => ({
  S3Client: jest.fn(() => ({ send: mockSend })),
  GetObjectCommand: jest.fn((input) => ({ op: 'get', ...input })),
  PutObjectCommand: jest.fn((input) => ({ op: 'put', ...input })),
}));

Object.assign(process.env, { RAW_BUCKET: 'raw', NOK_BUCKET: 'nok' });
const { handler } = require('../src/nok-writer');

const envelope = { v: 1, ek: 'a', iv: 'b', tag: 'c', ct: 'd' };
const nokMsg = {
  messageId: 'm1', receivedAt: 1761595872000, sourceIp: 'ip', requestId: 'r1',
  rawKey: 'raw/2025/10/27/m1.json', reason: 'schema_invalido', details: ['/data/battery must be <= 100'],
};
const sqsEvent = (...bodies) => ({ Records: bodies.map((b, i) => ({ messageId: `sqs-${i}`, body: JSON.stringify(b) })) });
const puts = () => mockSend.mock.calls.map(([c]) => c).filter((c) => c.op === 'put');

beforeEach(() => {
  mockSend.mockReset();
  jest.spyOn(console, 'log').mockImplementation(() => {});
  jest.spyOn(console, 'error').mockImplementation(() => {});
});

test('grava o NOK com motivo e envelope copiado do raw', async () => {
  mockSend.mockImplementation(async (c) => (c.op === 'get'
    ? { Body: { transformToString: async () => JSON.stringify({ envelope }) } } : {}));
  const res = await handler(sqsEvent(nokMsg));
  expect(res.batchItemFailures).toEqual([]);
  const [put] = puts();
  expect(put).toMatchObject({ Bucket: 'nok', Key: 'nok/2025/10/27/m1.json' });
  expect(JSON.parse(put.Body)).toEqual({ ...nokMsg, envelope });
});

test('raw expirado: grava o NOK com envelope null', async () => {
  mockSend.mockImplementation(async (c) => {
    if (c.op === 'get') throw Object.assign(new Error('x'), { name: 'NoSuchKey' });
    return {};
  });
  const res = await handler(sqsEvent(nokMsg));
  expect(res.batchItemFailures).toEqual([]);
  expect(JSON.parse(puts()[0].Body).envelope).toBeNull();
});

test('erro temporário do S3 gera retry só do item', async () => {
  mockSend.mockImplementation(async (c) => {
    if (c.op === 'get') return { Body: { transformToString: async () => JSON.stringify({ envelope }) } };
    if (c.Key.includes('m2')) throw new Error('S3 fora');
    return {};
  });
  const res = await handler(sqsEvent(nokMsg, { ...nokMsg, messageId: 'm2' }));
  expect(res.batchItemFailures).toEqual([{ itemIdentifier: 'sqs-1' }]);
});
