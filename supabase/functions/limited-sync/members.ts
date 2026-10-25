// 17Lands' larger files are several gzip members one after another (the draft dumps), which cards-sync's
// resumable inflate treats as one member each. This carries on member by member, so a checkpoint is still just a
// bit offset and a window: a checkpoint at the very start of a member (empty window, byte-aligned, gzip magic
// there) means "read the member's header first".
import { gzipHeaderBytes, inflateBlocks, type InflateCheckpoint } from "../cards-sync/inflate.ts";

const isMember = (d: Uint8Array, at: number) => d[at] === 0x1f && d[at + 1] === 0x8b && d[at + 2] === 8;

/** Where to start in `data` (the file from byte `base`): past a member header when the checkpoint sits on one. */
export function startAt(data: Uint8Array, base: number, bit: number | null, window: Uint8Array): InflateCheckpoint {
  const at = bit == null ? 0 : bit / 8 - base;
  if ((bit == null || (bit % 8 === 0 && window.length === 0)) && Number.isInteger(at) && isMember(data, at)) {
    return { bit: (base + at + gzipHeaderBytes(data.subarray(at))) * 8, window: new Uint8Array(0), final: false };
  }
  return { bit: bit ?? 0, window, final: false };
}

/**
 * Inflates from `from` through as many members as this slice holds, up to maxOut bytes of output. `done` once the
 * file's last member has ended. The returned checkpoint is either inside a member or at the start of the next one.
 */
export function inflateMembers(data: Uint8Array, base: number, total: number, from: InflateCheckpoint, reserve: number, maxOut: number,
                               emit: (out: Uint8Array) => void): { checkpoint: InflateCheckpoint; done: boolean } {
  let cp = from, out = 0;
  const last = base + data.length >= total;
  for (;;) {
    cp = inflateBlocks(data, base, cp, last ? 0 : reserve, maxOut - out, (o) => { out += o.length; emit(o); });
    if (!cp.final) return { checkpoint: cp, done: false };
    const next = Math.ceil(cp.bit / 8) + 8;            // past the member's CRC32 and ISIZE
    if (next >= total) return { checkpoint: cp, done: true };
    const at = next - base;
    const member = { bit: next * 8, window: new Uint8Array(0), final: false };
    // the next header must be inside this slice with room for its first block; otherwise the next slice starts there
    if (at + reserve >= data.length && !last) return { checkpoint: member, done: false };
    if (!isMember(data, at)) throw new Error(`no gzip member at byte ${next}`);
    if (out >= maxOut) return { checkpoint: member, done: false };
    cp = { bit: (next + gzipHeaderBytes(data.subarray(at))) * 8, window: new Uint8Array(0), final: false };
  }
}
