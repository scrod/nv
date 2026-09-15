// Independent provider-frame oracle: inspect framing before Node's bounded decoder.
import assert from 'node:assert/strict';
import {zstdDecompressSync} from 'node:zlib';

export function expandProviderZstd(bytes, count) {
  assert(Number.isSafeInteger(count) && count >= 0 && count <= 64*1024*1024);
  assert(bytes.length >= 6 && bytes.length <= 64*1024*1024+64*1024);
  assert.equal(bytes.readUInt32LE(), 0xfd2fb528);
  const flags = bytes[4], single = !!(flags & 32), sizeFlag = flags >> 6;
  assert.equal(flags & 27, 0); // No dictionary ID, reserved or unused bits.
  let pos = 5;
  if (!single) {
    const descriptor = bytes[pos++], base = 2 ** ((descriptor >> 3) + 10);
    assert(base + base/8 * (descriptor & 7) <= 64*1024*1024);
  }
  const width = sizeFlag ? 2 ** sizeFlag : single ? 1 : 0;
  assert(width !== 0 && pos + width <= bytes.length);
  let size = 0n;
  for (let i=0; i<width; ++i) size |= BigInt(bytes[pos++]) << BigInt(i*8);
  if (width === 2) size += 256n;
  assert.equal(size, BigInt(count));
  let last = false;
  while (!last) {
    assert(pos+3 <= bytes.length);
    const block = bytes.readUIntLE(pos,3); pos += 3;
    last = !!(block & 1);
    const kind = (block >> 1) & 3, length = block >> 3;
    assert(kind !== 3 && length <= 128*1024);
    pos += kind === 1 ? 1 : length;
    assert(pos <= bytes.length);
  }
  if (flags & 4) pos += 4;
  assert.equal(pos,bytes.length);
  const result = zstdDecompressSync(bytes,{maxOutputLength: Math.max(1,count)});
  assert.equal(result.length,count);
  return result;
}
