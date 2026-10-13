// Independent literal fixtures and malformed neighbors for private current-row framing.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {expandCurrentRow} from './current-row-frame.mjs';

const base = new URL('../NVStorage/Tests/NVStorageCoreTests/Fixtures/', import.meta.url);
const fixture = name => JSON.parse(readFileSync(new URL(name + '.json', base)));
const B = hex => Buffer.from(hex, 'hex');
const canonical = B(fixture('current-state').cell);
const plain = B(fixture('private-current-frame').frame);
const trained = fixture('private-current-dictionary'), dictionary = B(trained.dictionary);
const digest = createHash('sha256').update(dictionary).digest('hex');
const dictionaries = new Map([[digest, dictionary]]), framed = B(trained.frame);
assert.deepEqual(expandCurrentRow(plain), canonical);
assert.deepEqual(expandCurrentRow(framed, dictionaries), canonical);
assert.deepEqual(expandCurrentRow(canonical), canonical);
const rawHeader = Buffer.alloc(19); rawHeader.write('NVROW1\r\n'); rawHeader.writeUInt16BE(1, 8);
rawHeader.writeUInt32BE(canonical.length, 11); rawHeader.writeUInt32BE(canonical.length, 15);
assert.deepEqual(expandCurrentRow(Buffer.concat([rawHeader, canonical])), canonical);
for (const frame of [plain, framed]) {
  for (let cut = 0; cut < frame.length; ++cut) assert.throws(() => expandCurrentRow(frame.subarray(0, cut), dictionaries));
  assert.throws(() => expandCurrentRow(Buffer.concat([frame, Buffer.from([0])]), dictionaries));
  for (const position of [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]) {
    const bad = Buffer.from(frame); bad[position] ^= 255;
    assert.throws(() => expandCurrentRow(bad, dictionaries));
  }
}
assert.throws(() => expandCurrentRow(framed));
const badDigest = Buffer.from(framed); badDigest[19] ^= 1;
assert.throws(() => expandCurrentRow(badDigest, dictionaries));
const badDictionary = Buffer.from(dictionary); badDictionary[8] ^= 1;
assert.throws(() => expandCurrentRow(framed, new Map([[digest, badDictionary]])));
assert.equal(canonical.subarray(0, 8).toString(), 'NVCEL1\r\n');
assert.equal(canonical.length, 234);
console.log('Private current-row fixtures: independent raw/plain/dictionary bytes and malformed neighbors passed.');
