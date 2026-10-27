// Grava o cadastro de dispositivos em ingest-devices. Uso: node tools/seed-devices.js [arquivo.json]
// Sem argumento, usa tools/devices.example.json.
const fs = require('node:fs');
const path = require('node:path');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const { DynamoDBDocumentClient, BatchWriteCommand } = require('@aws-sdk/lib-dynamodb');

async function main() {
  const file = process.argv[2] ?? path.join(__dirname, 'devices.example.json');
  const devices = JSON.parse(fs.readFileSync(file, 'utf8'));
  const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region: process.env.AWS_REGION || 'us-east-2' }));
  for (let i = 0; i < devices.length; i += 25) {
    const batch = devices.slice(i, i + 25).map((Item) => ({ PutRequest: { Item } }));
    const res = await ddb.send(new BatchWriteCommand({ RequestItems: { 'ingest-devices': batch } }));
    const left = res.UnprocessedItems?.['ingest-devices']?.length ?? 0;
    if (left) throw new Error(`${left} itens não processados; execute novamente`);
  }
  console.log(`${devices.length} dispositivos gravados`);
}

main().catch((err) => { console.error(err.message); process.exit(1); });
