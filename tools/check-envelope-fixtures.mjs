// Independent OpenSSL/Node oracle, not the Swift encoder. All keys are public fixtures.
import { createCipheriv, createHash, hkdfSync, argon2Sync } from 'node:crypto';
import { expandProviderZstd } from './zstd-frame.mjs';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const u16 = n => { const b = Buffer.alloc(2); b.writeUInt16BE(n); return b; };
const u32 = n => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; };
const u64 = n => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(n)); return b; };
const hash = b => createHash('sha256').update(b).digest();
const collection = Buffer.alloc(16, 1), keyID = Buffer.alloc(16, 2), writer = Buffer.alloc(16, 3);
const key = Buffer.from(Array.from({length:32}, (_,i) => i)), nonce = Buffer.alloc(12, 4);
const domain = Buffer.from('NV object envelope\0v1\0');
const vectors = [];
for (const kind of [1,2,3]) for (const suite of [0,1]) for (const compressed of [false,true]) {
  const payload = Buffer.from('café\0東京\r\n');
  // Frozen standard raw-block frame: encoder heuristics are not canonical bytes.
  const encoded = compressed ? Buffer.from('28b52ffd200e710000636166c3a900e69db1e4baac0d0a','hex') : payload;
  if (compressed && !expandProviderZstd(encoded,payload.length).equals(payload)) throw Error('fixture frame payload');
  const header = Buffer.concat([Buffer.from('NVSEG1\r\n'),u16(1),Buffer.from([kind,suite]),u32(124),
    collection,suite ? keyID : Buffer.alloc(16),writer,u64(7),Buffer.alloc(16),Buffer.from([+compressed]),
    Buffer.alloc(7),u64(encoded.length),u64(payload.length),suite ? nonce : Buffer.alloc(12)]);
  if (header.length !== 124) throw Error('header width');
  let body, trailer, derived;
  if (suite) {
    derived = Buffer.from(hkdfSync('sha256',key,Buffer.concat([collection,keyID]),
      Buffer.concat([Buffer.from('NV object key\0v1\0'),Buffer.from([kind]),writer,Buffer.alloc(16)]),32));
    const cipher = createCipheriv('aes-256-gcm',derived,nonce);
    cipher.setAAD(Buffer.concat([domain,header]));
    body = Buffer.concat([cipher.update(encoded),cipher.final()]); trailer = cipher.getAuthTag();
  } else { body = encoded; trailer = hash(Buffer.concat([domain,header,body])); }
  const envelope = Buffer.concat([header,body,trailer]);
  vectors.push({kind,suite,compressed,payload:payload.toString('hex'),
    derivedKey:derived?.toString('hex') ?? null, envelope:envelope.toString('hex'), segmentID:hash(envelope).toString('hex')});
}
const descriptors = [];
if (process.argv.includes('--descriptors')) for (const encrypted of [false,true]) {
  const salt = Buffer.alloc(16, encrypted ? 5 : 0), n = Buffer.alloc(12, encrypted ? 6 : 0);
  const header = Buffer.concat([Buffer.from('NVKEY1\r\n'),u16(1),Buffer.from([encrypted ? 2 : 1]),collection,
    encrypted ? keyID : Buffer.alloc(16),u16(1),writer,u64(7),Buffer.alloc(32,9),Buffer.from([+encrypted]),
    u32(encrypted ? 0x13 : 0),u32(encrypted ? 65536 : 0),u32(encrypted ? 3 : 0),u32(encrypted ? 4 : 0),salt,n,u32(encrypted ? 32 : 0)]);
  if (header.length !== 150) throw Error('descriptor header width');
  let body, wrapKey;
  const password = 'café';
  if (encrypted) {
    wrapKey = argon2Sync('argon2id',{message:Buffer.from(password.normalize('NFC')), nonce:salt,
      parallelism:4,memory:65536,passes:3,tagLength:32});
    const cipher = createCipheriv('aes-256-gcm',wrapKey,n);
    cipher.setAAD(Buffer.concat([Buffer.from('NV key wrap\0v1\0'),header]));
    body = Buffer.concat([cipher.update(key),cipher.final(),cipher.getAuthTag()]);
  } else body = hash(Buffer.concat([Buffer.from('NV public descriptor\0v1\0'),header]));
  const descriptor = Buffer.concat([header,body]);
  descriptors.push({encrypted,password,wrappingKey:wrapKey?.toString('hex') ?? null,
    descriptor:descriptor.toString('hex'),descriptorID:hash(descriptor).toString('hex')});
}
const selected = process.argv.includes('--descriptors') ? descriptors : vectors;
const output = JSON.stringify(selected,null,2)+'\n';
if (process.argv.includes('--print')) process.stdout.write(output);
else {
  const name = process.argv.includes('--descriptors') ? 'descriptors' : 'envelopes';
  const file = fileURLToPath(new URL(`../NVStorage/Tests/NVStorageCoreTests/Fixtures/${name}.json`,import.meta.url));
  if (readFileSync(file,'utf8') !== output) throw Error('independent envelope fixtures differ');
  console.log(`PASS: ${selected.length} independent ${name} fixtures`);
}
