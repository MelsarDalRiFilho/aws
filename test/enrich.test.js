const mockDdb = jest.fn();
const mockSqs = jest.fn();
jest.mock('@aws-sdk/client-dynamodb', () => ({ DynamoDBClient: jest.fn() }));
jest.mock('@aws-sdk/lib-dynamodb', () => ({
  DynamoDBDocumentClient: { from: () => ({ send: mockDdb }) },
  GetCommand: jest.fn((input) => ({ op: 'get', ...input })),
  PutCommand: jest.fn((input) => ({ op: 'put', ...input })),
}));
jest.mock('@aws-sdk/client-sqs', () => ({
  SQSClient: jest.fn(() => ({ send: mockSqs })),
  SendMessageCommand: jest.fn((input) => input),
}));

Object.assign(process.env, { DEVICES_TABLE: 'devices', DATA_TABLE: 'data', NOK_QUEUE_URL: 'nok-url' });
const { handler } = require('../src/enrich');

const meta = { messageId: 'm1', receivedAt: 1, sourceIp: 'ip', requestId: 'r1', rawKey: 'raw/x/m1.json' };
const payload = { deviceId: 'abc123', timestamp: '2026-10-27T20:00:00Z', type: 'telemetry', data: { battery: 87 } };
const device = {
  deviceId: 'abc123', ownerId: '888', personId: '777', exclusionAreaId: '', stayAreaId: '989', scheduleId: '',
  contractId: '', model: 'Tracker T1', firmwareVersionId: '', messageLayoutId: '', status: 'active', installedAt: '2026-01-10',
};
const okEvent = (...ids) => ({ Records: ids.map((id) => ({ messageId: id, body: JSON.stringify({ ...meta, payload }) })) });
const withDevice = (dev, putImpl = async () => ({})) => mockDdb.mockImplementation(async (c) => (c.op === 'get' ? { Item: dev } : putImpl(c)));
const puts = () => mockDdb.mock.calls.map(([c]) => c).filter((c) => c.op === 'put');
const noks = () => mockSqs.mock.calls.map(([c]) => JSON.parse(c.MessageBody));

beforeEach(() => {
  mockDdb.mockReset();
  mockSqs.mockReset().mockResolvedValue({});
  jest.spyOn(console, 'log').mockImplementation(() => {});
  jest.spyOn(console, 'error').mockImplementation(() => {});
});

test('grava payload + retrato do cadastro + metadados', async () => {
  withDevice(device);
  const res = await handler(okEvent('s1'));
  expect(res.batchItemFailures).toEqual([]);
  const { deviceId, status, ...snapshot } = device;
  expect(puts()[0]).toMatchObject({
    TableName: 'data',
    ConditionExpression: 'attribute_not_exists(sk)',
    Item: { deviceId: 'abc123', sk: '2026-10-27T20:00:00Z#m1', timestamp: payload.timestamp, type: 'telemetry', data: payload.data, device: snapshot, ...meta },
  });
  expect(puts()[0].Item.device.status).toBeUndefined();
  expect(mockSqs).not.toHaveBeenCalled();
});

test('dispositivo não cadastrado vai para NOK', async () => {
  withDevice(undefined);
  await handler(okEvent('s1'));
  expect(puts()).toEqual([]);
  expect(noks()).toEqual([{ ...meta, reason: 'dispositivo_nao_cadastrado' }]);
});

test('dispositivo inativo vai para NOK', async () => {
  withDevice({ ...device, status: 'inactive' });
  await handler(okEvent('s1'));
  expect(puts()).toEqual([]);
  expect(noks()).toEqual([{ ...meta, reason: 'dispositivo_inativo' }]);
});

test('reprocessamento (item já existe) é sucesso', async () => {
  withDevice(device, async () => { throw Object.assign(new Error('x'), { name: 'ConditionalCheckFailedException' }); });
  const res = await handler(okEvent('s1'));
  expect(res.batchItemFailures).toEqual([]);
});

test('erro temporário do DynamoDB gera retry', async () => {
  withDevice(device, async () => { throw Object.assign(new Error('x'), { name: 'ProvisionedThroughputExceededException' }); });
  const res = await handler(okEvent('s1'));
  expect(res.batchItemFailures).toEqual([{ itemIdentifier: 's1' }]);
});
