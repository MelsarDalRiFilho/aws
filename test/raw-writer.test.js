const mockSend = jest.fn();
jest.mock('@aws-sdk/client-s3', () => ({
  S3Client: jest.fn(() => ({ send: mockSend })),
  PutObjectCommand: jest.fn((input) => input),
}));

process.env.RAW_BUCKET = 'bucket-teste';
const { handler, buildObject } = require('../src/raw-writer');

const record = (id, body = '{"v":1}') => ({
  messageId: id,
  body,
  attributes: { SentTimestamp: '1700000000000' },
  messageAttributes: {
    receivedAt: { stringValue: '1761595872000' },
    sourceIp: { stringValue: '1.2.3.4' },
    requestId: { stringValue: 'req-1' },
  },
});

beforeEach(() => mockSend.mockReset());

test('monta a chave por data de chegada e inclui os metadados', () => {
  const { key, body } = buildObject(record('m1'));
  expect(key).toBe('raw/2025/10/27/m1.json');
  expect(JSON.parse(body)).toEqual({
    messageId: 'm1', receivedAt: 1761595872000, sourceIp: '1.2.3.4', requestId: 'req-1', envelope: { v: 1 },
  });
});

test('grava todas as mensagens do lote no bucket', async () => {
  mockSend.mockResolvedValue({});
  const res = await handler({ Records: [record('m1'), record('m2')] });
  expect(res.batchItemFailures).toEqual([]);
  expect(mockSend).toHaveBeenCalledTimes(2);
  expect(mockSend.mock.calls[0][0]).toMatchObject({ Bucket: 'bucket-teste', Key: 'raw/2025/10/27/m1.json' });
});

test('reporta apenas as mensagens que falharam', async () => {
  mockSend.mockResolvedValueOnce({}).mockRejectedValueOnce(new Error('S3 fora'));
  const res = await handler({ Records: [record('m1'), record('m2')] });
  expect(res.batchItemFailures).toEqual([{ itemIdentifier: 'm2' }]);
});

test('corpo inválido vira falha do item, sem derrubar o lote', async () => {
  mockSend.mockResolvedValue({});
  const res = await handler({ Records: [record('m1', 'não-json'), record('m2')] });
  expect(res.batchItemFailures).toEqual([{ itemIdentifier: 'm1' }]);
});
