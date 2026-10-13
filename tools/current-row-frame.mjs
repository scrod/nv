// Independent private-row oracle: verify the enclosure, dictionary binding and one complete zstd frame.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {zstdDecompressSync} from 'node:zlib';

export function expandCurrentRow(bytes, dictionaries = new Map()) {
  const ceiling = 64 * 1024 * 1024;
  assert(bytes.length > 0 && bytes.length <= ceiling + 64 * 1024 + 51);
  if (bytes.subarray(0, 8).toString() === 'NVCEL1\r\n') {
    assert(bytes.length <= ceiling); return bytes;
  }
  assert(bytes.length >= 19);
  assert.equal(bytes.subarray(0, 8).toString(), 'NVROW1\r\n');
  assert.equal(bytes.readUInt16BE(8), 1);
  const tag = bytes[10], count = bytes.readUInt32BE(11), stored = bytes.readUInt32BE(15);
  assert(tag <= 2 && count > 0 && count <= ceiling && stored > 0 && stored <= ceiling + 64 * 1024);
  const offset = tag === 2 ? 51 : 19;
  assert.equal(bytes.length, offset + stored);
  const payload = bytes.subarray(offset);
  if (tag === 0) { assert.equal(count, stored); return payload; }
  let dictionary;
  if (tag === 2) {
    const digest = bytes.subarray(19, 51).toString('hex');
    dictionary = dictionaries.get(digest);
    assert(dictionary && dictionary.length >= 8 && dictionary.length <= 8192);
    assert.equal(dictionary.readUInt32LE(), 0xec30a437);
    assert(dictionary.readUInt32LE(4) !== 0);
    assert.equal(createHash('sha256').update(dictionary).digest('hex'), digest);
  }
  assert(payload.length >= 6 && payload.readUInt32LE() === 0xfd2fb528);
  const flags = payload[4], single = !!(flags & 32), sizeFlag = flags >> 6;
  assert.equal(flags & 24, 0);
  let pos = 5;
  if (!single) {
    const descriptor = payload[pos++], base = 2 ** ((descriptor >> 3) + 10);
    assert(base + base / 8 * (descriptor & 7) <= ceiling);
  }
  const idWidth = [0, 1, 2, 4][flags & 3];
  assert(pos + idWidth <= payload.length);
  const id = idWidth ? payload.readUIntLE(pos, idWidth) : 0; pos += idWidth;
  assert.equal(id, dictionary ? dictionary.readUInt32LE(4) : 0);
  const width = sizeFlag ? 2 ** sizeFlag : single ? 1 : 0;
  assert(width > 0 && pos + width <= payload.length);
  let size = 0n;
  for (let i = 0; i < width; ++i) size |= BigInt(payload[pos++]) << BigInt(i * 8);
  if (width === 2) size += 256n;
  assert.equal(size, BigInt(count));
  let last = false;
  while (!last) {
    assert(pos + 3 <= payload.length);
    const block = payload.readUIntLE(pos, 3); pos += 3;
    last = !!(block & 1);
    const kind = (block >> 1) & 3, length = block >> 3;
    assert(kind !== 3 && length <= 128 * 1024);
    pos += kind === 1 ? 1 : length;
    assert(pos <= payload.length);
  }
  if (flags & 4) pos += 4;
  assert.equal(pos, payload.length);
  const result = zstdDecompressSync(payload, {maxOutputLength: count, ...(dictionary ? {dictionary} : {})});
  assert.equal(result.length, count);
  return result;
}
