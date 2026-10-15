// Resumable inflate (RFC 1951) for Scryfall's all_cards file: one gzip member of ~400MB that inflates to ~3GB,
// far more than one edge request's 2s of CPU can take (native DecompressionStream can't stop and resume). This
// inflater stops between deflate blocks, so a later request can carry on from a checkpoint: the absolute bit
// offset of the next block plus the last 32KB of output (the back-reference window), range-fetching only the
// compressed bytes from there on. Table-driven like fflate; pure, so it also runs under Node for tests.

/** Where the next deflate block starts and the output before it. `final` once the last block is done. */
export interface InflateCheckpoint {
  bit: number;
  window: Uint8Array;
  final: boolean;
}

const WSIZE = 32768;

// Length codes 257..285 and distance codes 0..29: extra bits and bases.
const LEN_EXTRA = new Uint8Array([0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, 0, 0]);
const DIST_EXTRA = new Uint8Array([0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 0, 0]);
const CL_ORDER = new Uint8Array([16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]);
const bases = (extra: Uint8Array, start: number) => {
  const b = new Uint16Array(extra.length);
  for (let i = 0, v = start; i < extra.length; i++) { b[i] = v; v += 1 << extra[i]; }
  return b;
};
const LEN_BASE = bases(LEN_EXTRA, 3);
LEN_BASE[28] = 258;
const DIST_BASE = bases(DIST_EXTRA, 1);

/** Bit-reversed decode table: index by the next `max` bits, entry = symbol << 4 | code length. */
function decodeTable(lengths: Uint8Array, max: number): Uint16Array {
  const count = new Uint16Array(max + 1);
  for (const l of lengths) if (l) count[l]++;
  const next = new Uint16Array(max + 1);
  for (let b = 1, code = 0; b <= max; b++) { code = (code + count[b - 1]) << 1; next[b] = code; }
  next[0] = 0;
  const table = new Uint16Array(1 << max);
  for (let sym = 0; sym < lengths.length; sym++) {
    const l = lengths[sym];
    if (!l) continue;
    let code = next[l]++;
    let rev = 0;
    for (let i = 0; i < l; i++) { rev = rev << 1 | code & 1; code >>= 1; }
    const entry = sym << 4 | l;
    for (let i = rev; i < 1 << max; i += 1 << l) table[i] = entry;
  }
  return table;
}
const maxLen = (lengths: Uint8Array) => { let m = 1; for (const l of lengths) if (l > m) m = l; return m; };

const FIXED_LIT = (() => {
  const l = new Uint8Array(288);
  l.fill(8, 0, 144); l.fill(9, 144, 256); l.fill(7, 256, 280); l.fill(8, 280, 288);
  return decodeTable(l, 9);
})();
const FIXED_DIST = decodeTable(new Uint8Array(32).fill(5), 5);

/** Byte length of a gzip member header (RFC 1952), so the deflate data starts at 8× this bit. */
export function gzipHeaderBytes(d: Uint8Array): number {
  if (d[0] !== 0x1f || d[1] !== 0x8b || d[2] !== 8) throw new Error("not a gzip file");
  const flg = d[3];
  let p = 10;
  if (flg & 4) p += 2 + (d[p] | d[p + 1] << 8);
  if (flg & 8) while (d[p++]);
  if (flg & 16) while (d[p++]);
  if (flg & 2) p += 2;
  return p;
}

/**
 * Inflates whole blocks from `data`, which holds the file's bytes from byte `base` on, starting at checkpoint
 * `from`. Before each block, stops when fewer than `reserve` bytes of `data` are left (a block never spans more
 * unless the file is corrupt) or `maxOut` bytes have come out. `emit` gets output in order, in pieces of a few MB
 * that are only valid during the call. Returns the checkpoint to resume from.
 */
export function inflateBlocks(
  data: Uint8Array, base: number, from: InflateCheckpoint, reserve: number, maxOut: number,
  emit: (out: Uint8Array) => void,
): InflateCheckpoint {
  const CHUNK = 4 << 20;
  const buf = new Uint8Array(WSIZE + CHUNK + 1024);
  buf.set(from.window, WSIZE - from.window.length);
  let o = WSIZE;          // write position
  let emitted = WSIZE;    // output before this is already emitted
  let total = 0;
  let p = from.bit - base * 8;
  if (p < 0) throw new Error("checkpoint before the fetched range");
  const limit = (data.length - reserve) * 8;
  let final = from.final;
  // Reads up to 17 bits at p (callers mask); past the end reads zeros, caught by the reserve check.
  const bits = (n: number) => {
    const i = p >> 3;
    const v = (data[i] | data[i + 1] << 8 | data[i + 2] << 16) >> (p & 7) & (1 << n) - 1;
    p += n;
    return v;
  };
  const flush = () => {
    if (o > emitted) { emit(buf.subarray(emitted, o)); total += o - emitted; }
    buf.copyWithin(0, o - WSIZE, o);
    o = WSIZE;
    emitted = WSIZE;
  };

  while (!final && p < limit && total + (o - emitted) < maxOut) {
    final = bits(1) === 1;
    const type = bits(2);
    if (type === 0) {
      p = p + 7 & ~7;
      const i = p >> 3;
      const len = data[i] | data[i + 1] << 8;
      if ((len ^ (data[i + 2] | data[i + 3] << 8)) !== 0xffff) throw new Error("bad stored block");
      if (o + len > buf.length) flush();
      buf.set(data.subarray(i + 4, i + 4 + len), o);
      o += len;
      p = (i + 4 + len) * 8;
      if (o - WSIZE >= CHUNK) flush();
      continue;
    }
    let lit: Uint16Array, dist: Uint16Array, litMask: number, distMask: number;
    if (type === 1) {
      lit = FIXED_LIT; dist = FIXED_DIST; litMask = 511; distMask = 31;
    } else if (type === 2) {
      const hlit = bits(5) + 257, hdist = bits(5) + 1, hclen = bits(4) + 4;
      const cl = new Uint8Array(19);
      for (let i = 0; i < hclen; i++) cl[CL_ORDER[i]] = bits(3);
      const clMax = maxLen(cl);
      const clTable = decodeTable(cl, clMax);
      const lens = new Uint8Array(hlit + hdist);
      for (let i = 0; i < lens.length;) {
        const e = clTable[bits(clMax) & (1 << clMax) - 1];
        p -= clMax - (e & 15);
        const sym = e >> 4;
        if (sym < 16) lens[i++] = sym;
        else {
          let n = 0, v = 0;
          if (sym === 16) { if (!i) throw new Error("bad code lengths"); v = lens[i - 1]; n = 3 + bits(2); }
          else if (sym === 17) n = 3 + bits(3);
          else n = 11 + bits(7);
          if (i + n > lens.length) throw new Error("bad code lengths");
          lens.fill(v, i, i + n);
          i += n;
        }
      }
      const ll = lens.subarray(0, hlit), dl = lens.subarray(hlit);
      const lm = maxLen(ll), dm = maxLen(dl);
      lit = decodeTable(ll, lm); dist = decodeTable(dl, dm);
      litMask = (1 << lm) - 1; distMask = (1 << dm) - 1;
    } else throw new Error("bad block type");

    const high = buf.length - 300;
    for (;;) {
      if (o >= high) flush();
      let i = p >> 3;
      let e = lit[(data[i] | data[i + 1] << 8 | data[i + 2] << 16) >> (p & 7) & litMask];
      p += e & 15;
      const sym = e >> 4;
      if (sym < 256) { buf[o++] = sym; continue; }
      if (sym === 256) break;
      const li = sym - 257;
      let len = LEN_BASE[li];
      if (LEN_EXTRA[li]) len += bits(LEN_EXTRA[li]);
      i = p >> 3;
      e = dist[(data[i] | data[i + 1] << 8 | data[i + 2] << 16) >> (p & 7) & distMask];
      p += e & 15;
      const ds = e >> 4;
      let d = DIST_BASE[ds];
      if (DIST_EXTRA[ds]) d += bits(DIST_EXTRA[ds]);
      if (d > o) throw new Error("distance too far back");
      let s = o - d;
      const end = o + len;
      if (d >= len) { buf.copyWithin(o, s, s + len); o = end; }
      else while (o < end) buf[o++] = buf[s++];
    }
    if (o - WSIZE >= CHUNK) flush();
  }
  if (p > data.length * 8) throw new Error("ran past the fetched range");
  flush();
  return { bit: base * 8 + p, window: buf.slice(0, WSIZE), final };
}
