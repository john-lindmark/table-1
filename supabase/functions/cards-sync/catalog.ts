// Pure helpers for cards-sync: Scryfall card → slim row, and line-aligned splitting of the bulk stream.
// No Deno or Supabase imports, so this file also runs under Node for local tests against a real bulk file.

/** Pieces written to the staging bucket stay under the 50MB object limit with room to spare. */
export const STAGE_PIECE_BYTES = 32 * 1024 * 1024;
/** Rows per catalog_ingest call. */
export const INGEST_BATCH = 1000;

// deno-lint-ignore no-explicit-any
type Json = any;

/** What catalog_ingest takes per printing (column names match t1_private.catalog_rows). */
export interface SlimCard {
  id: string;
  oracle_id: string;
  name: string;
  face_names: string[] | null;
  layout: string;
  type_line: string | null;
  mana_cost: string | null;
  cmc: number | null;
  colors: string[] | null;
  color_identity: string[] | null;
  legalities: Record<string, string>;
  set_code: string;
  collector_number: string;
  lang: string;
  rarity: string;
  finishes: string[];
  printed_name: string | null;
  released_at: string | null;
  image_ts: number | null;
  image_faces: number;
  usd: string | null;
  usd_foil: string | null;
  usd_etched: string | null;
  eur: string | null;
  eur_foil: string | null;
}

const KEEP_LEGALITY = new Set(["legal", "restricted", "banned"]);
const TS = /\?(\d+)$/;

/** Maps one Scryfall card object. Null for digital-only cards and the few with no Oracle id. */
export function slimCard(c: Json): SlimCard | null {
  if (!Array.isArray(c.games) || !c.games.includes("paper")) return null;
  const faces: Json[] = Array.isArray(c.card_faces) ? c.card_faces : [];
  const f0 = faces[0];
  const oracle = c.oracle_id ?? f0?.oracle_id;
  if (!oracle || !c.id || !c.set || !c.collector_number) return null;

  const img: string | undefined = c.image_uris?.normal ?? f0?.image_uris?.normal;
  const ts = img ? TS.exec(img) : null;
  const imageFaces = c.image_uris ? 1 : faces[1]?.image_uris ? 2 : f0?.image_uris ? 1 : 0;

  const legalities: Record<string, string> = {};
  for (const [k, v] of Object.entries(c.legalities ?? {})) if (KEEP_LEGALITY.has(v as string)) legalities[k] = v as string;

  const p = c.prices ?? {};
  return {
    id: c.id,
    oracle_id: oracle,
    name: c.name,
    face_names: faces.length > 1 && typeof c.name === "string" && c.name.includes(" // ")
      ? faces.map((f) => f.name).filter(Boolean)
      : null,
    layout: c.layout ?? "normal",
    type_line: c.type_line ?? (faces.length ? faces.map((f) => f.type_line).filter(Boolean).join(" // ") : null),
    mana_cost: c.mana_cost ?? f0?.mana_cost ?? null,
    cmc: typeof c.cmc === "number" ? c.cmc : null,
    colors: c.colors ?? f0?.colors ?? null,
    color_identity: c.color_identity ?? null,
    legalities,
    set_code: c.set,
    collector_number: c.collector_number,
    lang: c.lang ?? "en",
    rarity: c.rarity ?? "common",
    finishes: Array.isArray(c.finishes) && c.finishes.length ? c.finishes : ["nonfoil"],
    printed_name: c.lang && c.lang !== "en" ? (c.printed_name ?? f0?.printed_name ?? null) : null,
    released_at: c.released_at ?? null,
    image_ts: ts ? Number(ts[1]) : null,
    image_faces: imageFaces,
    usd: p.usd ?? null,
    usd_foil: p.usd_foil ?? null,
    usd_etched: p.usd_etched ?? null,
    eur: p.eur ?? null,
    eur_foil: p.eur_foil ?? null,
  };
}

/**
 * Collects a byte stream into pieces of about `size` bytes that end on a newline, without decoding anything.
 * `emit` gets each piece; the buffer is reused afterwards, so emit must finish with it before returning.
 */
export class PieceSplitter {
  private buf: Uint8Array;
  private len = 0;
  private size: number;
  private emit: (piece: Uint8Array, n: number) => Promise<void>;
  count = 0;

  constructor(size: number, emit: (piece: Uint8Array, n: number) => Promise<void>) {
    this.size = size;
    this.emit = emit;
    this.buf = new Uint8Array(size + 4 * 1024 * 1024);
  }

  async push(chunk: Uint8Array) {
    let off = 0;
    while (off < chunk.length) {
      const take = Math.min(chunk.length - off, this.buf.length - this.len);
      this.buf.set(chunk.subarray(off, off + take), this.len);
      this.len += take;
      off += take;
      if (this.len >= this.size) await this.cut();
    }
  }

  async end() {
    if (this.len > 0) await this.flush(this.len);
  }

  private async cut() {
    const nl = this.buf.lastIndexOf(10, this.len - 1);
    if (nl < 0) {
      if (this.len === this.buf.length) throw new Error("line longer than a staging piece");
      return; // keep reading until a line ends
    }
    await this.flush(nl + 1);
  }

  private async flush(upTo: number) {
    await this.emit(this.buf.subarray(0, upTo), this.count++);
    this.buf.copyWithin(0, upTo, this.len);
    this.len -= upTo;
  }
}

/** Splits a staged piece into JSON lines without decoding the whole piece into one string. */
export function* pieceLines(piece: Uint8Array): Generator<string> {
  const dec = new TextDecoder();
  let p = 0;
  for (;;) {
    const i = piece.indexOf(10, p);
    const end = i < 0 ? piece.length : i;
    if (end > p) {
      // Bulk JSONL may be wrapped as a JSON array; tolerate "[", "]" and trailing commas.
      let s = dec.decode(piece.subarray(p, end)).trim();
      if (s.endsWith(",")) s = s.slice(0, -1);
      if (s && s !== "[" && s !== "]") yield s;
    }
    if (i < 0) return;
    p = i + 1;
  }
}

export const PACK_FORMAT = 1;
/** First line of a pack: magic, format, version (content hash), counts. Deterministic for the same body. */
export const packHeader = (version: string, oracles: number, printings: number) =>
  `#t1catalog\t${PACK_FORMAT}\t${version}\t${oracles}\t${printings}`;
