// The offline card catalog (contract/catalog-2026-10-14.md): one gzipped TSV pack, downloaded only when its
// version changes, parsed once per page load into column arrays. Search, filters and the collection list all
// read from here; the server is only asked for prices.
import { supabase } from "./supabaseClient";

export interface CatalogInfo {
  version: string;
  format: number;
  url: string;
  bytes: number;
  sha256: string;
}

/** Column store: index i of each array is one card (O) or printing (P). */
export interface Catalog {
  version: string;
  oracles: number;
  oId: string[];
  oName: string[];
  oNorm: string[];
  oType: string[];
  oCost: string[];
  oCmc: Float64Array;
  oColors: string[];
  oFaces: string[];
  /** Legality code per card, one character per LEGALITY_FORMATS entry (L, R, B, -); "" in older packs. */
  oLegal: string[];
  /** The card's original paper printing (the default for adds), or -1 when the pack doesn't say. */
  oOriginal: Int32Array;
  /** Canadian Highlander points per card (0 = none). */
  oPoints: Uint8Array;
  /** Printings of card i are pFirst[i] .. pFirst[i] + pCount[i] - 1, newest first. */
  pFirst: Int32Array;
  pCount: Int32Array;
  printings: number;
  pId: string[];
  pOracle: Int32Array;
  pSet: string[];
  pCn: string[];
  pLang: string[];
  pRarity: string[];
  pFinishes: string[];
  pReleased: string[];
  pImageTs: string[];
  pFaces: Uint8Array;
  pPrintedName: string[];
  printingIndex: Map<string, number>;
}

const INFO_KEY = "table1.catalog.info";
const INFO_TTL_MS = 24 * 60 * 60 * 1000;
const CACHE_NAME = "table1-catalog";

/** Same steps as public.card_name_norm. */
export function normName(s: string): string {
  return s
    .normalize("NFKD")
    .toLowerCase()
    .replace(/[̀-ͯ]/g, "")
    .replace(/æ/g, "ae")
    .replace(/œ/g, "oe")
    .replace(/['’]/g, "")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

/** Formats in a card's legality code, in order. */
export const LEGALITY_FORMATS = ["standard", "pioneer", "modern", "legacy", "vintage", "pauper", "commander", "premodern"];

export type Legality = "legal" | "restricted" | "banned" | "not_legal";

/**
 * A card's legality in a deck format, or null when the format isn't checked (or the pack predates the code).
 * Canadian Highlander ("canlander") follows Vintage, and restricted cards are legal there (every card is a singleton).
 */
export function legalityOf(c: Catalog, oi: number, format: string): Legality | null {
  const f = format.toLowerCase();
  const i = LEGALITY_FORMATS.indexOf(f === "canlander" ? "vintage" : f);
  const ch = i < 0 ? undefined : c.oLegal[oi]?.[i];
  if (!ch) return null;
  return ch === "L" ? "legal" : ch === "R" ? (f === "canlander" ? "legal" : "restricted") : ch === "B" ? "banned" : "not_legal";
}

/** Canadian Highlander: at most this many points per deck (canadianhighlander.ca/points-list). */
export const CANLANDER_POINT_LIMIT = 10;

/** A deck format as players write it. */
export function formatName(format: string): string {
  if (format === "canlander") return "Canadian Highlander";
  return format.charAt(0).toUpperCase() + format.slice(1);
}

export const FINISH_LETTER: Record<string, "nonfoil" | "foil" | "etched"> = { n: "nonfoil", f: "foil", e: "etched" };
export const RARITY_NAME: Record<string, string> = {
  c: "Common", u: "Uncommon", r: "Rare", m: "Mythic", s: "Special", b: "Bonus",
};

/**
 * Card corner radius as a fraction of the card's width, measured from Scryfall's transparent PNG scans
 * (2026-10-15): every printing 4.32% (≈2.7 mm on a 63 mm card), Alpha 6.99% (≈4.4 mm: its cutting die was
 * rounder), Collectors' and International Edition square (they were cut square).
 */
export function cornerRatio(set: string): number {
  if (set === "lea") return 0.0699;
  if (set === "ced" || set === "cei") return 0;
  return 0.0432;
}

export function cardImageUrl(c: Catalog, p: number, size: "small" | "normal" | "large" = "normal", back = false) {
  const id = c.pId[p];
  const ts = c.pImageTs[p];
  return `https://cards.scryfall.io/${size}/${back ? "back" : "front"}/${id[0]}/${id[1]}/${id}.jpg${ts ? `?${ts}` : ""}`;
}

async function fetchInfo(): Promise<CatalogInfo | null> {
  try {
    const raw = localStorage.getItem(INFO_KEY);
    if (raw) {
      const { at, info } = JSON.parse(raw) as { at: number; info: CatalogInfo };
      if (Date.now() - at < INFO_TTL_MS) return info;
    }
  } catch {
    /* storage blocked: ask the server */
  }
  const { data, error } = await supabase.rpc("catalog_info");
  if (error) throw error;
  const info = data as CatalogInfo | null;
  try {
    if (info) localStorage.setItem(INFO_KEY, JSON.stringify({ at: Date.now(), info }));
  } catch {
    /* fine */
  }
  return info;
}

/** The pack bytes, from Cache Storage when present (packs are immutable per URL). */
async function fetchPack(info: CatalogInfo): Promise<Response> {
  try {
    const cache = await caches.open(CACHE_NAME);
    const hit = await cache.match(info.url);
    if (hit) return hit;
    const res = await fetch(info.url);
    if (!res.ok) throw new Error(`Card data ${res.status}`);
    await cache.put(info.url, res.clone());
    // Older packs are dead weight once a new one is in.
    for (const req of await cache.keys()) if (req.url !== info.url) await cache.delete(req);
    return res;
  } catch (e) {
    if (e instanceof Error && e.message.startsWith("Card data")) throw e;
    const res = await fetch(info.url); // no Cache Storage (private window): the HTTP cache still applies
    if (!res.ok) throw new Error(`Card data ${res.status}`);
    return res;
  }
}

export function parsePack(version: string, text: string): Catalog {
  const lines = text.split("\n");
  const head = lines[0].split("\t");
  if (head[0] !== "#t1catalog" || head[1] !== "1") throw new Error("Unknown card data format");
  const nO = Number(head[3]);
  const nP = Number(head[4]);
  const c: Catalog = {
    version, oracles: nO, printings: nP,
    oId: new Array(nO), oName: new Array(nO), oNorm: new Array(nO), oType: new Array(nO), oCost: new Array(nO),
    oCmc: new Float64Array(nO), oColors: new Array(nO), oFaces: new Array(nO),
    oLegal: new Array(nO), oOriginal: new Int32Array(nO).fill(-1), oPoints: new Uint8Array(nO),
    pFirst: new Int32Array(nO).fill(-1), pCount: new Int32Array(nO),
    pId: new Array(nP), pOracle: new Int32Array(nP), pSet: new Array(nP), pCn: new Array(nP), pLang: new Array(nP),
    pRarity: new Array(nP), pFinishes: new Array(nP), pReleased: new Array(nP), pImageTs: new Array(nP),
    pFaces: new Uint8Array(nP), pPrintedName: new Array(nP), printingIndex: new Map(),
  };
  let o = 0;
  let p = 0;
  for (let li = 1; li < lines.length; li++) {
    const line = lines[li];
    if (!line) continue;
    const f = line.split("\t");
    if (f[0] === "O" && o < nO) {
      const i = Number(f[1]);
      c.oId[i] = f[2]; c.oName[i] = f[3]; c.oNorm[i] = f[4]; c.oType[i] = f[5]; c.oCost[i] = f[6];
      c.oCmc[i] = f[7] ? Number(f[7]) : 0; c.oColors[i] = f[8] ?? ""; c.oFaces[i] = f[9] ?? "";
      c.oLegal[i] = f[10] ?? "";
      c.oPoints[i] = Number(f[11]) || 0;
      o++;
    } else if (f[0] === "P" && p < nP) {
      const oi = Number(f[2]);
      c.pId[p] = f[1]; c.pOracle[p] = oi; c.pSet[p] = f[3]; c.pCn[p] = f[4]; c.pLang[p] = f[5];
      c.pRarity[p] = f[6]; c.pFinishes[p] = f[7]; c.pReleased[p] = f[8]; c.pImageTs[p] = f[9];
      c.pFaces[p] = Number(f[10]) || 0; c.pPrintedName[p] = f[11] ?? "";
      if (f[12] === "1") c.oOriginal[oi] = p;
      if (c.pFirst[oi] < 0) c.pFirst[oi] = p;
      c.pCount[oi]++;
      c.printingIndex.set(f[1], p);
      p++;
    }
    // Unknown line types are skipped (format rule).
  }
  return c;
}

let loading: Promise<Catalog> | null = null;

/** Loads the catalog once per page; later calls share the same promise. */
export function loadCatalog(): Promise<Catalog> {
  if (!loading) {
    loading = (async () => {
      const info = await fetchInfo();
      if (!info) throw new Error("Card data isn't available yet");
      const res = await fetchPack(info);
      const text = await new Response(res.body!.pipeThrough(new DecompressionStream("gzip"))).text();
      return parsePack(info.version, text);
    })().catch((e) => {
      loading = null; // let the next caller retry
      throw e;
    });
  }
  return loading;
}

const EXTRA = /^(Token|Card|Emblem)\b|\bToken\b/;

/**
 * Name search over cards. Tiers: exact name, then names with a word starting with the query, then any
 * substring, then tokens and art cards; within a tier the most-reprinted card first (Lightning Bolt has ~70
 * printings), then shorter names.
 */
export function searchCatalog(c: Catalog, query: string, limit = 30): number[] {
  const q = normName(query);
  if (q.length < 2) return [];
  const tiers: number[][] = [[], [], [], []];
  const word = " " + q;
  for (let i = 0; i < c.oracles; i++) {
    const n = c.oNorm[i];
    let t = -1;
    if (n === q) t = 0;
    else if (n.startsWith(q) || n.includes(word)) t = 1;
    else if (n.includes(q)) t = 2;
    if (t < 0) continue;
    if (t > 0 && EXTRA.test(c.oType[i])) t = 3;
    tiers[t].push(i);
  }
  const out: number[] = [];
  for (const tier of tiers) {
    tier.sort((a, b) => c.pCount[b] - c.pCount[a] || c.oNorm[a].length - c.oNorm[b].length || (c.oNorm[a] < c.oNorm[b] ? -1 : 1));
    for (const i of tier) {
      out.push(i);
      if (out.length >= limit) return out;
    }
  }
  return out;
}

/**
 * A card's default printing, shown as its picture and used when it's added: its original paper printing
 * (flagged in the pack), else the newest English printing with an image, else the newest.
 */
export function coverPrinting(c: Catalog, oi: number): number {
  if (c.oOriginal[oi] >= 0) return c.oOriginal[oi];
  const first = c.pFirst[oi];
  for (let p = first; p < first + c.pCount[oi]; p++) if (c.pLang[p] === "en" && c.pFaces[p] > 0) return p;
  return first;
}

const nameIndexes = new WeakMap<Catalog, Map<string, number>>();

/**
 * Default printings for card names as decklists print them: exact names, or the front face of a split or
 * double-faced card ("Delver of Secrets" finds "Delver of Secrets // Insectile Aberration"). Names that match
 * no card are left out.
 */
export function printingsByName(c: Catalog, names: string[]): Map<string, number> {
  let index = nameIndexes.get(c);
  if (!index) {
    index = new Map();
    const fronts = new Map<string, number>();
    for (let i = 0; i < c.oracles; i++) {
      index.set(c.oNorm[i], i);
      const front = c.oName[i].split(" // ")[0];
      if (front !== c.oName[i]) {
        const k = normName(front);
        const had = fronts.get(k);
        if (had === undefined || c.pCount[i] > c.pCount[had]) fronts.set(k, i);
      }
    }
    for (const [k, i] of fronts) if (!index.has(k)) index.set(k, i);
    nameIndexes.set(c, index);
  }
  const out = new Map<string, number>();
  for (const n of names) {
    const oi = index.get(normName(n));
    if (oi !== undefined) out.set(n, coverPrinting(c, oi));
  }
  return out;
}

const setCnIndexes = new WeakMap<Catalog, Map<string, number>>();

/** A printing by set code and collector number ("set|cn", set in lowercase), English first. */
export function printingBySetCn(c: Catalog, set: string, cn: string): number | undefined {
  let index = setCnIndexes.get(c);
  if (!index) {
    index = new Map();
    for (let p = 0; p < c.printings; p++) {
      const k = `${c.pSet[p]}|${c.pCn[p]}`;
      const had = index.get(k);
      if (had === undefined || (c.pLang[p] === "en" && c.pLang[had] !== "en")) index.set(k, p);
    }
    setCnIndexes.set(c, index);
  }
  return index.get(`${set.toLowerCase()}|${cn}`);
}

export function oracleIndexById(c: Catalog, oracleId: string): number {
  return c.oId.indexOf(oracleId);
}
