// The catalog pack body, built in parts (catalog_pack_part: O, P and N lines per window of cards) so each part
// fits the 8s statement timeout as the catalog grows. Parts are joined in idx order: the same text
// catalog_pack_body() returns.

/** One catalog_pack_part call: the kind's lines for cards [from, to), or null when there are none. */
export type PartCall = (kind: number, from: number, to: number) => Promise<string | null>;

/** Cards per catalog_pack_part window: ~0.5s warm (2026-10-28), up to ~7s cold. */
export const PACK_WINDOW = 10_000;
/** A part that times out is split in halves down to this many cards before the run gives up. */
export const MIN_PACK_WINDOW = 625;

const isStatementTimeout = (e: unknown) => String(e).includes("statement timeout");

/**
 * One window's lines. The night every oracle is rewritten the cache is cold and a P-line part can run past the
 * statement timeout (bug #21, 2026-10-28), so a part that times out is built from its two halves instead.
 */
async function part(call: PartCall, kind: number, from: number, to: number, min: number): Promise<string | null> {
  try {
    return await call(kind, from, to);
  } catch (e) {
    if (!isStatementTimeout(e) || to - from <= min) throw e;
    const mid = from + Math.floor((to - from) / 2);
    const a = await part(call, kind, from, mid, min);
    const b = await part(call, kind, mid, to, min);
    return a == null ? b : b == null ? a : a + "\n" + b;
  }
}

/** O lines window by window until one comes back empty, then P and N lines for the same windows. */
export async function packBody(call: PartCall, window = PACK_WINDOW, min = MIN_PACK_WINDOW): Promise<string> {
  const parts: string[] = [];
  let windows = 0;
  for (let kind = 0; kind < 3; kind++) {
    for (let w = 0; kind === 0 || w < windows; w++) {
      const p = await part(call, kind, w * window, (w + 1) * window, min);
      if (kind === 0 && p == null) { windows = w; break; }
      if (p) parts.push(p);
    }
  }
  return parts.join("\n");
}
