// Verify production Swift-sealed frames with independent Node crypto and decoding.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {createHash, createDecipheriv, hkdfSync} from 'node:crypto';
import {expandProviderZstd} from './zstd-frame.mjs';
const args = process.argv.slice(2);
const reports = JSON.parse(args[0] === '--reports' ? readFileSync(args[1],'utf8') :
  execFileSync(args[0], ['zstd-envelopes'], {encoding:'utf8',timeout:60000}));
assert.equal(reports.length,12);
const seen = new Set(), collection = Buffer.alloc(16,1), keyID = Buffer.alloc(16,2), writer = Buffer.alloc(16,3);
const domain = Buffer.from('NV object envelope\0v1\0');
for (const r of reports) {
  assert([1,2,3].includes(r.kind) && typeof r.encrypted === 'boolean' && [0,4096].includes(r.size));
  seen.add([r.kind,r.encrypted,r.size].join(':'));
  const b = Buffer.from(r.bytes,'hex'), h = b.subarray(0,124), suite = +r.encrypted;
  assert.equal(h.subarray(0,8).toString(),'NVSEG1\r\n');
  assert.equal(h.readUInt16BE(8),1); assert.equal(h[10],r.kind); assert.equal(h[11],suite);
  assert.equal(h.readUInt32BE(12),124); assert.deepEqual(h.subarray(16,32),collection);
  assert.deepEqual(h.subarray(32,48),suite ? keyID : Buffer.alloc(16));
  assert.deepEqual(h.subarray(48,64),writer); assert.equal(h.readBigUInt64BE(64),7n);
  assert.deepEqual(h.subarray(72,88),Buffer.alloc(16)); assert.equal(h[88],1);
  assert.deepEqual(h.subarray(89,96),Buffer.alloc(7)); assert.equal(h.readBigUInt64BE(104),BigInt(r.size));
  const size = Number(h.readBigUInt64BE(96)); assert.equal(b.length,124+size+(suite?16:32));
  const body = b.subarray(124,124+size), tag = b.subarray(124+size);
  let frame;
  if (suite) {
    const key = hkdfSync('sha256',Buffer.from(Array.from({length:32},(_,i)=>i)),Buffer.concat([collection,keyID]),
      Buffer.concat([Buffer.from('NV object key\0v1\0'),Buffer.from([r.kind]),writer,Buffer.alloc(16)]),32);
    const decipher = createDecipheriv('aes-256-gcm',key,h.subarray(112,124));
    decipher.setAAD(Buffer.concat([domain,h])); decipher.setAuthTag(tag);
    frame = Buffer.concat([decipher.update(body),decipher.final()]);
  } else {
    assert.deepEqual(h.subarray(112),Buffer.alloc(12));
    assert.deepEqual(tag,createHash('sha256').update(Buffer.concat([domain,h,body])).digest()); frame = body;
  }
  const expected = Buffer.from(Array.from({length:r.size},(_,i)=>i%251));
  assert.deepEqual(expandProviderZstd(frame,r.size),expected);
}
assert.equal(seen.size,12);
const raw = Buffer.from('28b52ffd2003190000616263','hex'), empty = Buffer.from('28b52ffd2000010000','hex');
assert.deepEqual(expandProviderZstd(raw,3),Buffer.from('abc'));
for (const bad of [Buffer.concat([raw,empty]),Buffer.concat([raw,Buffer.from([0])]),raw.subarray(0,-1),
  Buffer.from('28b52ffd0000190000616263','hex'), Buffer.from('28b52ffd808803000000190000616263','hex'),
  Buffer.from('28b52ffd210003190000616263','hex'),Buffer.from('789c4b4c4a0600024d0127','hex')]) {
  assert.throws(()=>expandProviderZstd(bad,3));
}
console.log('PASS: 12 independently checked production zstd envelopes and decoder negative controls');
