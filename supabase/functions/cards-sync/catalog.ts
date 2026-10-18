// Pure helpers for cards-sync: Scryfall card → slim row, line-aligned splitting of the bulk stream, and printed
// names from all_cards. No Deno or Supabase imports, so this file also runs under Node for local tests.
import { type InflateCheckpoint, inflateBlocks } from "./inflate.ts";

/** Pieces written to the staging bucket stay under the 50MB object limit with room to spare. */
export const STAGE_PIECE_BYTES = 32 * 1024 * 1024;
/** Rows per catalog_ingest call. */
export const INGEST_BATCH = 1000;
/** Rows per catalog_names_ingest call. */
export const NAMES_BATCH = 2000;

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
  /** Letters from WUBRGCF in that order; see producedMana. */
  produced_mana: string;
  /** Scryfall ids of the token printings the card makes (all_parts, component "token"), sorted. */
  token_card_ids: string[];
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
    produced_mana: producedMana(c),
    token_card_ids: tokenCardIds(c),
  };
}

const MANA_ORDER = "WUBRGCF";
const BASIC_TYPES: [RegExp, string][] = [
  [/\bPlains\b/, "W"], [/\bIslands?\b/, "U"], [/\bSwamps?\b/, "B"], [/\bMountains?\b/, "R"], [/\bForests?\b/, "G"],
];

/**
 * The mana a card makes, as letters from WUBRGCF: Scryfall produced_mana (W U B R G C), plus, for a land, the colors
 * of the basic land types it searches for ("Search your library for a Plains or Island card" → W U) and F when it
 * searches for any basic land (Evolving Wilds, Prismatic Vista). Empty when it makes none.
 */
export function producedMana(c: Json): string {
  const got = new Set<string>();
  for (const m of Array.isArray(c.produced_mana) ? c.produced_mana : []) if ("WUBRGC".includes(m)) got.add(m);
  const faces: Json[] = Array.isArray(c.card_faces) ? c.card_faces : [];
  const typeLine: string = c.type_line ?? faces[0]?.type_line ?? "";
  if (/\bLand\b/.test(typeLine.split(" // ")[0].split(" — ")[0])) {
    const text = [c.oracle_text, ...faces.map((f) => f.oracle_text)].filter((t) => typeof t === "string").join("\n");
    for (const m of text.matchAll(/search your library for ([^.]*)/gi)) {
      let typed = false;
      for (const [re, color] of BASIC_TYPES) if (re.test(m[1])) { got.add(color); typed = true; }
      if (!typed && /\bbasic land cards?\b/i.test(m[1])) got.add("F");
    }
  }
  return [...MANA_ORDER].filter((x) => got.has(x)).join("");
}

/** Token printings the card makes, from all_parts (component "token"), never the card itself. */
export function tokenCardIds(c: Json): string[] {
  const ids = new Set<string>();
  for (const p of Array.isArray(c.all_parts) ? c.all_parts : []) {
    if (p?.component === "token" && typeof p.id === "string" && p.id !== c.id) ids.add(p.id);
  }
  return [...ids].sort();
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

/**
 * Languages whose printed names go into the pack (N lines): the ones the scanner's OCR reads. Latin and Cyrillic
 * (Vision on iOS, ML Kit's Latin model on Android), and since 2026-10-16 Japanese, Chinese (simplified and
 * traditional) and Korean (VisionKit with those languages; ML Kit's Japanese, Chinese and Korean models).
 */
export const NAME_LANGS = ["de", "es", "fr", "it", "pt", "ru", "ja", "zhs", "zht", "ko"];
const LANG_KEY = new TextEncoder().encode('"lang":"');
const NAME_LANG_SET = new Set(NAME_LANGS);

/**
 * True when a raw all_cards line is a printing in one of NAME_LANGS, read from the bytes without decoding or
 * parsing (all_cards is ~3GB of JSON; only about half of it is kept). `lang` sits near the start of the object.
 */
export function isNameLangLine(line: Uint8Array): boolean {
  const end = Math.min(line.length, 4096);
  for (let i = line.indexOf(34 /* " */); i >= 0 && i < end; i = line.indexOf(34, i + 1)) {
    let k = 1;
    while (k < LANG_KEY.length && line[i + k] === LANG_KEY[k]) k++;
    if (k < LANG_KEY.length) continue;
    const j = i + LANG_KEY.length;
    const q = line.indexOf(34, j);
    return q > j && q - j <= 3 && NAME_LANG_SET.has(String.fromCharCode(...line.subarray(j, q)));
  }
  return false;
}

/** One printed name: what catalog_names_ingest takes. */
export interface PrintedName {
  oracle_id: string;
  lang: string;
  printed_name: string;
}

/** A foreign printing's printed names (each face of a multi-faced card), skipping any that equal the English name. */
export function printedNames(c: Json): PrintedName[] {
  if (!Array.isArray(c.games) || !c.games.includes("paper") || !c.lang || c.lang === "en") return [];
  const faces: Json[] = Array.isArray(c.card_faces) ? c.card_faces : [];
  const out: PrintedName[] = [];
  const add = (oracle: string | undefined, printed: unknown, name: unknown) => {
    if (!oracle || typeof printed !== "string") return;
    const p = printed.replace(/[\t\n\r]+/g, " ").trim();
    if (p && p !== name) out.push({ oracle_id: oracle, lang: c.lang, printed_name: p });
  };
  add(c.oracle_id ?? faces[0]?.oracle_id, c.printed_name, c.name);
  for (const f of faces) add(f.oracle_id ?? c.oracle_id, f.printed_name, f.name);
  return out;
}

/**
 * One names step's work: inflates a slice of all_cards from checkpoint `from` (`carry` is the partial line the
 * previous slice ended on) and returns the printed names it found, deduplicated, with where to resume.
 */
export function namesFromSlice(data: Uint8Array, base: number, from: InflateCheckpoint, carry: Uint8Array, reserve: number) {
  const found = new Map<string, PrintedName>();
  const dec = new TextDecoder();
  const take = (line: Uint8Array) => {
    if (!isNameLangLine(line)) return;
    let s = dec.decode(line).trim();
    if (s.endsWith(",")) s = s.slice(0, -1);
    for (const n of printedNames(JSON.parse(s))) found.set(`${n.oracle_id}\t${n.lang}\t${n.printed_name}`, n);
  };
  const join = (a: Uint8Array, b: Uint8Array) => {
    const j = new Uint8Array(a.length + b.length);
    j.set(a);
    j.set(b, a.length);
    return j;
  };
  const checkpoint = inflateBlocks(data, base, from, reserve, Infinity, (out) => {
    let p = 0;
    for (let i = out.indexOf(10); i >= 0; i = out.indexOf(10, p)) {
      if (carry.length) { take(join(carry, out.subarray(p, i))); carry = new Uint8Array(0); }
      else take(out.subarray(p, i));
      p = i + 1;
    }
    if (p < out.length) carry = join(carry, out.subarray(p));
  });
  if (checkpoint.final && carry.length) { take(carry); carry = new Uint8Array(0); }
  return { checkpoint, carry, names: [...found.values()] };
}
