// Teste ponta a ponta contra o ambiente dev. Uso: npm run e2e  |  npm run e2e -- --load 200
const crypto = require('node:crypto');
const { execSync } = require('node:child_process');
const { KMSClient, GetPublicKeyCommand } = require('@aws-sdk/client-kms');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, GetCommand } = require('@aws-sdk/lib-dynamodb');
const { S3Client, GetObjectCommand } = require('@aws-sdk/client-s3');
const { encryptEnvelope } = require('./encrypt-envelope');

const REGION = 'us-east-2';
const URL = 'https://025tr6hq7g.execute-api.us-east-2.amazonaws.com/dev/ingest';
const NOK_BUCKET = 'ingest-nok-019141478952';
const TIMEOUT_MS = 180_000;

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region: REGION }));
const s3 = new S3Client({ region: REGION });
const apiKey = process.env.API_KEY || execSync(
  'aws apigateway get-api-key --api-key 0wxuggrnvl --include-value --query value --output text --region us-east-2',
).toString().trim();

const now = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
const nonce = () => crypto.randomBytes(16).toString('base64url');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function post(envelope) {
  const res = await fetch(URL, {
    method: 'POST',
    headers: { 'x-api-key': apiKey, 'Content-Type': 'application/json' },
    body: JSON.stringify(envelope),
  });
  return { status: res.status, messageId: res.ok ? (await res.json()).messageId : null };
}

async function findOk(deviceId, timestamp, messageId) {
  const { Item } = await ddb.send(new GetCommand({ TableName: 'ingest-data', Key: { deviceId, sk: `${timestamp}#${messageId}` } }));
  return Item;
}

async function findNok(messageId) {
  const day = new Date().toISOString().slice(0, 10).replace(/-/g, '/');
  try {
    const obj = await s3.send(new GetObjectCommand({ Bucket: NOK_BUCKET, Key: `nok/${day}/${messageId}.json` }));
    return JSON.parse(await obj.Body.transformToString()).reason;
  } catch (err) {
    if (err.name === 'NoSuchKey') return undefined;
    throw err;
  }
}

// Espera até a mensagem chegar ao destino final: 'ok' (ingest-data) ou o motivo do NOK.
async function waitResult({ deviceId, timestamp }, messageId) {
  const start = Date.now();
  while (Date.now() - start < TIMEOUT_MS) {
    if (await findOk(deviceId, timestamp, messageId)) return { result: 'ok', ms: Date.now() - start };
    const reason = await findNok(messageId);
    if (reason) return { result: reason, ms: Date.now() - start };
    await sleep(3000);
  }
  return { result: 'timeout', ms: TIMEOUT_MS };
}

async function scenarios(publicKey) {
  const base = (deviceId, extra = {}) => ({ deviceId, timestamp: now(), type: 'telemetry', nonce: nonce(), data: { battery: 50 }, ...extra });
  const enc = (p) => encryptEnvelope(JSON.stringify(p), publicKey);

  const valid = base('dev002');
  const replayPayload = base('abc123');
  const replayEnvelope = enc(replayPayload);
  const cases = [
    { name: 'válido (dev002)', payload: valid, envelope: enc(valid), expect: ['ok'] },
    { name: 'inativo (dev003)', payload: base('dev003'), expect: ['dispositivo_inativo'] },
    { name: 'não cadastrado (dev999)', payload: base('dev999'), expect: ['dispositivo_nao_cadastrado'] },
    { name: 'schema inválido', payload: base('dev002', { data: { battery: 500 } }), expect: ['schema_invalido'] },
    { name: 'fora da janela', payload: base('dev002', { timestamp: '2020-01-01T00:00:00Z' }), expect: ['fora_da_janela'] },
  ];
  const results = await Promise.all(cases.map(async (c) => {
    const { status, messageId } = await post(c.envelope ?? enc(c.payload));
    if (status !== 200) return { ...c, got: `HTTP ${status}` };
    const { result } = await waitResult(c.payload, messageId);
    return { ...c, got: result };
  }));

  // Replay: o mesmo envelope 2×; exatamente um deve virar 'ok' e o outro 'replay'.
  const replayPosts = await Promise.all([post(replayEnvelope), post(replayEnvelope)]);
  const replayResults = (await Promise.all(replayPosts.map(({ messageId }) => waitResult(replayPayload, messageId))))
    .map((r) => r.result).sort();
  results.push({ name: 'replay (2× o mesmo envelope)', expect: ['ok,replay'], got: replayResults.join(',') });

  let failed = 0;
  for (const r of results) {
    const pass = r.expect.includes(r.got);
    if (!pass) failed++;
    console.log(`${pass ? '✅' : '❌'} ${r.name}: esperado ${r.expect.join('|')}, obtido ${r.got}`);
  }
  return failed;
}

async function load(publicKey, total, concurrency = 10) {
  const sent = [];
  let throttled = 0;
  let next = 0;
  const t0 = Date.now();
  await Promise.all(Array.from({ length: concurrency }, async () => {
    while (next < total) {
      next++;
      const payload = { deviceId: 'dev002', timestamp: now(), type: 'telemetry', nonce: nonce(), data: { battery: 42 } };
      const { status, messageId } = await post(encryptEnvelope(JSON.stringify(payload), publicKey));
      if (status === 429) throttled++;
      else if (status === 200) sent.push({ payload, messageId, at: Date.now() });
    }
  }));
  console.log(`Enviadas: ${sent.length} OK, ${throttled} com 429 em ${((Date.now() - t0) / 1000).toFixed(1)} s`);

  const results = await Promise.all(sent.map(async ({ payload, messageId, at }) => {
    const start = Date.now();
    while (Date.now() - start < TIMEOUT_MS) {
      if (await findOk(payload.deviceId, payload.timestamp, messageId)) return Date.now() - at;
      await sleep(5000);
    }
    return null;
  }));
  const lat = results.filter((x) => x !== null).sort((a, b) => a - b);
  const p = (q) => (lat[Math.floor(q * (lat.length - 1))] / 1000).toFixed(1);
  console.log(`Gravadas em ingest-data: ${lat.length}/${sent.length}`);
  if (lat.length) console.log(`Latência ponta a ponta (s): p50=${p(0.5)} p95=${p(0.95)} máx=${p(1)}`);
  return sent.length - lat.length;
}

async function main() {
  const kms = new KMSClient({ region: REGION });
  const { PublicKey } = await kms.send(new GetPublicKeyCommand({ KeyId: 'alias/ingest-payload' }));
  const publicKey = Buffer.from(PublicKey);
  const loadIdx = process.argv.indexOf('--load');
  const failed = loadIdx > 0 ? await load(publicKey, Number(process.argv[loadIdx + 1] || 100)) : await scenarios(publicKey);
  process.exit(failed ? 1 : 0);
}

main().catch((err) => { console.error(err); process.exit(1); });
