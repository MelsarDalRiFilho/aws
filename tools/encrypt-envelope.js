// Simula o celular: cifra um payload JSON com AES-256-GCM e a chave AES com a chave pública RSA do KMS.
// Uso: node tools/encrypt-envelope.js '<json>'  (ou payload via stdin). Imprime o envelope.
const crypto = require('node:crypto');
const { KMSClient, GetPublicKeyCommand } = require('@aws-sdk/client-kms');

function encryptEnvelope(plaintext, publicKeyDer) {
  const key = crypto.randomBytes(32);
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ct = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const ek = crypto.publicEncrypt({
    key: crypto.createPublicKey({ key: publicKeyDer, format: 'der', type: 'spki' }),
    padding: crypto.constants.RSA_PKCS1_OAEP_PADDING,
    oaepHash: 'sha256',
  }, key);
  return {
    v: 1,
    ek: ek.toString('base64'),
    iv: iv.toString('base64'),
    tag: cipher.getAuthTag().toString('base64'),
    ct: ct.toString('base64'),
  };
}

async function main() {
  const plaintext = process.argv[2] ?? require('node:fs').readFileSync(0, 'utf8');
  const kms = new KMSClient({ region: process.env.AWS_REGION || 'us-east-2' });
  const { PublicKey } = await kms.send(new GetPublicKeyCommand({ KeyId: 'alias/ingest-payload' }));
  console.log(JSON.stringify(encryptEnvelope(plaintext, Buffer.from(PublicKey))));
}

if (require.main === module) main().catch((err) => { console.error(err.message); process.exit(1); });

module.exports = { encryptEnvelope };
