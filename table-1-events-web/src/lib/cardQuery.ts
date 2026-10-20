/* Advanced search (contract/library-polish-2026-10-19.md § Advanced search): Scryfall's query syntax in every Add
   cards search. A plain name is the usual name search. A query with syntax runs on the local card data when every
   key it uses is one the pack carries (name, type, colors, mana value, mana cost, rarity, set, collector number,
   year, language, finish, format legality, mana produced); anything else (card text, power, artist, …) is sent to
   Scryfall's search API and the hits are matched back to the local data by printing id. Same rules as iOS
   `CardQuery.swift`; cases shared with iOS and Android: testdata/card-query/cases.json. */
import { LEGALITY_FORMATS, coverPrinting, legalityOf, normName, searchCatalog, type Catalog } from "./catalog";

export interface Term {
  /** Lowercased key; "" for a bare word (the card's name). */
  key: string;
  /** ":", "=", "!=", "<", ">", "<=", ">=". */
  op: string;
  value: string;
  /** `!"Name"`: the whole name, not a part of it. */
  exact?: boolean;
}

export type QueryNode =
  | { and: QueryNode[] }
  | { or: QueryNode[] }
  | { not: QueryNode }
  | { term: Term };

type Token = "open" | "close" | "or" | "neg" | { term: Term };

/* ── parsing ─────────────────────────────────────────────────────────── */

const OPS = ["!=", "<=", ">=", ":", "=", "<", ">"];
const isSpace = (ch: string) => /\s/.test(ch);
const isLetter = (ch: string) => /\p{L}/u.test(ch);

/** True when the query uses any syntax (a key, an operator, a quote, a minus, parentheses or "or"); a plain name
 *  goes to the ranked name search instead. */
export function hasSyntax(q: string): boolean {
  const tokens = tokenize(q);
  if (!tokens) return true;
  return tokens.some((t) => (typeof t === "string" ? true : t.term.key !== "" || !!t.term.exact || t.term.value.includes(" ")));
}

export function parseQuery(q: string): QueryNode | null {
  const tokens = tokenize(q);
  if (!tokens || !tokens.length) return null;
  let i = 0;
  const orExpr = (): QueryNode | null => {
    const first = andExpr();
    if (!first) return null;
    const parts = [first];
    while (i < tokens.length && tokens[i] === "or") {
      i++;
      const next = andExpr();
      if (!next) return null;
      parts.push(next);
    }
    return parts.length === 1 ? parts[0] : { or: parts };
  };
  const andExpr = (): QueryNode | null => {
    const parts: QueryNode[] = [];
    while (i < tokens.length && tokens[i] !== "or" && tokens[i] !== "close") {
      const u = unary();
      if (!u) return null;
      parts.push(u);
    }
    if (!parts.length) return null;
    return parts.length === 1 ? parts[0] : { and: parts };
  };
  const unary = (): QueryNode | null => {
    if (i >= tokens.length) return null;
    const t = tokens[i];
    if (t === "neg") {
      i++;
      const inner = unary();
      return inner ? { not: inner } : null;
    }
    if (t === "open") {
      i++;
      const inner = orExpr();
      if (!inner || i >= tokens.length || tokens[i] !== "close") return null;
      i++;
      return inner;
    }
    if (typeof t !== "string") {
      i++;
      return { term: t.term };
    }
    return null;
  };
  const node = orExpr();
  return node && i === tokens.length ? node : null;
}

function tokenize(q: string): Token[] | null {
  const chars = Array.from(q);
  const out: Token[] = [];
  let i = 0;
  const readValue = (): string | null => {
    if (i < chars.length && (chars[i] === '"' || chars[i] === "'")) {
      const quote = chars[i];
      i++;
      let v = "";
      while (i < chars.length && chars[i] !== quote) v += chars[i++];
      if (i >= chars.length) return null;
      i++;
      return v;
    }
    let v = "";
    while (i < chars.length && !isSpace(chars[i]) && chars[i] !== "(" && chars[i] !== ")") v += chars[i++];
    return v;
  };
  while (i < chars.length) {
    const c = chars[i];
    if (isSpace(c)) { i++; continue; }
    if (c === "(") { out.push("open"); i++; continue; }
    if (c === ")") { out.push("close"); i++; continue; }
    if (c === "-" && i + 1 < chars.length && !isSpace(chars[i + 1])) { out.push("neg"); i++; continue; }
    if (c === "!") {
      i++;
      const v = readValue();
      if (!v) return null;
      out.push({ term: { key: "", op: ":", value: v, exact: true } });
      continue;
    }
    if (c === '"' || c === "'") {
      const v = readValue();
      if (v == null) return null;
      if (v) out.push({ term: { key: "", op: ":", value: v } });
      continue;
    }
    // A key is letters followed by an operator; otherwise the word is part of the name.
    let j = i;
    while (j < chars.length && isLetter(chars[j])) j++;
    const op = j > i ? OPS.find((o) => chars.slice(j, j + o.length).join("") === o) : undefined;
    if (op) {
      const key = chars.slice(i, j).join("").toLowerCase();
      // Not a key Scryfall knows ("Circle of Protection: Red"): part of the name.
      if (!KNOWN_KEYS.has(key)) {
        const word = readValue();
        if (word) out.push({ term: { key: "", op: ":", value: word } });
        continue;
      }
      i = j + op.length;
      const v = readValue();
      if (v == null) return null;
      out.push({ term: { key, op, value: v } });
      continue;
    }
    const word = readValue();
    if (!word) { i++; continue; }
    const lw = word.toLowerCase();
    if (lw === "or") out.push("or");
    else if (lw !== "and") out.push({ term: { key: "", op: ":", value: word } }); // "and" is the default between terms
  }
  return out;
}

/* ── what runs locally ───────────────────────────────────────────────── */

const set = (...xs: string[]) => new Set(xs);
const NAME_KEYS = set("", "name", "n");
const TYPE_KEYS = set("t", "type");
const COLOR_KEYS = set("c", "color", "colors");
const MV_KEYS = set("mv", "cmc", "manavalue");
const MANA_KEYS = set("m", "mana");
const RARITY_KEYS = set("r", "rarity");
const SET_KEYS = set("s", "set", "e", "edition");
const CN_KEYS = set("cn", "number");
const LANG_KEYS = set("lang", "language");
const LEGAL_KEYS = set("f", "format", "legal");
const PRINTING_KEYS = new Set([...RARITY_KEYS, ...SET_KEYS, ...CN_KEYS, ...LANG_KEYS, "year", "date", "is"]);
const FORMATS = new Set([...LEGALITY_FORMATS, "canlander"]);

/** Every key Scryfall's syntax has (local or not); any other "word:" is part of a card name. */
const KNOWN_KEYS = new Set([
  "name", "n", ...TYPE_KEYS, ...COLOR_KEYS, ...MV_KEYS, ...MANA_KEYS, ...PRINTING_KEYS, ...LEGAL_KEYS, "banned", "restricted",
  "produces", "o", "oracle", "fo", "fulloracle", "pow", "power", "tou", "toughness", "pt", "powtou", "loy", "loyalty", "def",
  "defense", "id", "identity", "ci", "commander", "kw", "keyword", "a", "artist", "ft", "flavor", "wm", "watermark", "border",
  "frame", "game", "in", "st", "art", "atag", "otag", "function", "devotion", "usd", "eur", "tix", "prints", "sets",
  "papersets", "cube", "block", "b", "new", "not", "has", "include", "layout", "stamp", "unique", "order", "prefer",
  "direction", "lore", "hand", "life", "paper",
]);

const num = (v: string): number | null => (/^[+-]?(\d+\.?\d*|\.\d+)$/.test(v) ? Number(v) : null);
const int = (v: string): number | null => (/^[+-]?\d+$/.test(v) ? Number(v) : null);

/** Whether the local data can answer this term. */
export function termIsLocal(t: Term): boolean {
  const k = t.key, v = t.value.toLowerCase();
  if (NAME_KEYS.has(k) || TYPE_KEYS.has(k) || SET_KEYS.has(k) || LANG_KEYS.has(k)) return v !== "";
  if (COLOR_KEYS.has(k)) return colorSet(v) != null || int(v) != null;
  if (MV_KEYS.has(k)) return num(v) != null || v === "even" || v === "odd";
  if (MANA_KEYS.has(k)) return manaSymbols(v).length > 0;
  if (RARITY_KEYS.has(k)) return rarityRank(v) != null;
  if (CN_KEYS.has(k)) return v !== "";
  if (k === "year") return int(v) != null;
  if (k === "date") return Array.from(v).length === 10;
  if (k === "is") return v === "foil" || v === "nonfoil" || v === "etched";
  if (LEGAL_KEYS.has(k) || k === "banned" || k === "restricted") return FORMATS.has(v);
  if (k === "produces") return colorSet(v) != null;
  return false;
}

export function isLocal(n: QueryNode): boolean {
  if ("and" in n) return n.and.every(isLocal);
  if ("or" in n) return n.or.every(isLocal);
  if ("not" in n) return isLocal(n.not);
  return termIsLocal(n.term);
}

/** Whether any term is about a printing (set, rarity, year, …): those match card by card's printings. */
export function usesPrinting(n: QueryNode): boolean {
  if ("and" in n) return n.and.some(usesPrinting);
  if ("or" in n) return n.or.some(usesPrinting);
  if ("not" in n) return usesPrinting(n.not);
  return PRINTING_KEYS.has(n.term.key);
}

/** The name words the query asks for (not negated), for ranking. */
export function nameWords(n: QueryNode): string[] {
  if ("and" in n) return n.and.flatMap(nameWords);
  if ("or" in n) return n.or.flatMap(nameWords);
  if ("not" in n) return [];
  return NAME_KEYS.has(n.term.key) ? [n.term.value] : [];
}

/* ── matching ────────────────────────────────────────────────────────── */

/** Does card `oi` (and printing `p`, for printing terms; null when the query has none) match? */
export function matches(n: QueryNode, c: Catalog, oi: number, p: number | null): boolean {
  if ("and" in n) return n.and.every((x) => matches(x, c, oi, p));
  if ("or" in n) return n.or.some((x) => matches(x, c, oi, p));
  if ("not" in n) return !matches(n.not, c, oi, p);
  return termMatches(n.term, c, oi, p);
}

const FINISH_OF: Record<string, string> = { n: "nonfoil", f: "foil", e: "etched" };

function compare(a: number, op: string, b: number): boolean {
  switch (op) {
    case "<": return a < b;
    case ">": return a > b;
    case "<=": return a <= b;
    case ">=": return a >= b;
    case "!=": return a !== b;
    default: return a === b;
  }
}

const isSubset = (a: Set<string>, b: Set<string>) => [...a].every((x) => b.has(x));
const sameSet = (a: Set<string>, b: Set<string>) => a.size === b.size && isSubset(a, b);

export function termMatches(t: Term, c: Catalog, oi: number, p: number | null): boolean {
  const k = t.key, v = t.value.toLowerCase();
  const name = c.oName[oi];
  if (NAME_KEYS.has(k)) {
    const q = normName(t.value);
    return t.exact ? normName(name) === q || name.toLowerCase().split(" // ").includes(v) : normName(name).includes(q);
  }
  if (TYPE_KEYS.has(k)) return normName(c.oType[oi]).includes(normName(t.value));
  if (COLOR_KEYS.has(k) || k === "produces") {
    const src = k === "produces" ? (c.oProduced[oi] ?? "").toUpperCase() : c.oColors[oi].toUpperCase();
    const allowed = k === "produces" ? "WUBRGC" : "WUBRG";
    const have = new Set(Array.from(src).filter((x) => allowed.includes(x)));
    const n = int(v);
    if (n != null && k !== "produces") return compare(have.size, t.op, n);
    const want = colorSet(v);
    if (!want) return false;
    if (want === "colorless") return t.op === "!=" ? have.size > 0 : have.size === 0;
    if (want === "multicolor") return t.op === "!=" ? have.size < 2 : have.size >= 2;
    switch (t.op) {
      case "=": return sameSet(have, want);
      case "!=": return !sameSet(have, want);
      case "<=": return isSubset(have, want);
      case "<": return isSubset(have, want) && have.size < want.size;
      case ">": return isSubset(want, have) && have.size > want.size;
      default: return isSubset(want, have); // ":" and ">=": at least these
    }
  }
  if (MV_KEYS.has(k)) {
    const mv = c.oCmc[oi];
    if (v === "even") return Math.trunc(mv) % 2 === 0;
    if (v === "odd") return Math.trunc(mv) % 2 === 1;
    const b = num(v);
    return b != null && compare(mv, t.op, b);
  }
  if (MANA_KEYS.has(k)) {
    const counts = (xs: string[]) => xs.reduce((m, x) => m.set(x, (m.get(x) ?? 0) + 1), new Map<string, number>());
    const w = counts(manaSymbols(v)), h = counts(manaSymbols(c.oCost[oi].toLowerCase()));
    const same = w.size === h.size && [...w].every(([s, n]) => h.get(s) === n);
    if (t.op === "=") return same;
    if (t.op === "!=") return !same;
    return [...w].every(([s, n]) => (h.get(s) ?? 0) >= n);
  }
  if (LEGAL_KEYS.has(k)) {
    const l = legalityOf(c, oi, v);
    return l === "legal" || l === "restricted";
  }
  if (k === "banned") return legalityOf(c, oi, v) === "banned";
  if (k === "restricted") return legalityOf(c, oi, v) === "restricted";
  if (p == null) return false;
  if (RARITY_KEYS.has(k)) {
    const have = rarityRank(c.pRarity[p]), want = rarityRank(v);
    return have != null && want != null && compare(have, t.op, want);
  }
  const pset = c.pSet[p].toLowerCase();
  if (SET_KEYS.has(k)) return t.op === "!=" ? pset !== v : pset === v;
  if (CN_KEYS.has(k)) {
    const cn = c.pCn[p];
    const a = int(cn.replace(/\D/g, "")), b = int(v);
    if (["<", ">", "<=", ">="].includes(t.op) && a != null && b != null) return compare(a, t.op, b);
    return t.op === "!=" ? cn.toLowerCase() !== v : cn.toLowerCase() === v;
  }
  if (LANG_KEYS.has(k)) return t.op === "!=" ? c.pLang[p] !== v : c.pLang[p] === v;
  const released = c.pReleased[p] ?? "";
  if (k === "year") {
    const y = int(released.slice(0, 4));
    return y != null && compare(y, t.op, num(v) ?? 0);
  }
  if (k === "date") {
    const d = released.slice(0, 10);
    switch (t.op) {
      case "<": return d < v;
      case ">": return d > v;
      case "<=": return d <= v;
      case ">=": return d >= v;
      case "!=": return d !== v;
      default: return d === v;
    }
  }
  if (k === "is") return Array.from(c.pFinishes[p] ?? "").some((l) => FINISH_OF[l] === v);
  return false;
}

export type ColorWant = Set<string> | "colorless" | "multicolor";

const COLOR_NAMES: Record<string, string> = {
  white: "W", blue: "U", black: "B", red: "R", green: "G",
  azorius: "WU", dimir: "UB", rakdos: "BR", gruul: "RG", selesnya: "GW",
  orzhov: "WB", izzet: "UR", golgari: "BG", boros: "RW", simic: "GU",
  bant: "GWU", esper: "WUB", grixis: "UBR", jund: "BRG", naya: "RGW",
  abzan: "WBG", jeskai: "URW", sultai: "BGU", mardu: "RWB", temur: "GUR",
};

export function colorSet(value: string): ColorWant | null {
  const v = value.toLowerCase();
  if (v === "c" || v === "colorless") return "colorless";
  if (v === "m" || v === "multicolor") return "multicolor";
  const named = COLOR_NAMES[v];
  if (named) return new Set(named);
  const letters = v.toUpperCase();
  if (!letters || !Array.from(letters).every((x) => "WUBRG".includes(x))) return null;
  return new Set(letters);
}

/** Mana symbols as lowercased strings without braces: "{2}{R}{R}" and "2rr" both read as ["2", "r", "r"]. */
export function manaSymbols(value: string): string[] {
  const out: string[] = [];
  const chars = Array.from(value.toLowerCase());
  let i = 0;
  while (i < chars.length) {
    if (chars[i] === "{") {
      let s = "";
      i++;
      while (i < chars.length && chars[i] !== "}") s += chars[i++];
      i++;
      if (s) out.push(s);
    } else if (/\d/.test(chars[i])) {
      let s = "";
      while (i < chars.length && /\d/.test(chars[i])) s += chars[i++];
      out.push(s);
    } else if ("wubrgcxs".includes(chars[i])) {
      out.push(chars[i++]);
    } else {
      return [];
    }
  }
  return out;
}

function rarityRank(v: string): number | null {
  switch (v.toLowerCase()) {
    case "c": case "common": return 0;
    case "u": case "uncommon": return 1;
    case "r": case "rare": return 2;
    case "m": case "mythic": return 3;
    case "s": case "special": return 4;
    case "b": case "bonus": return 5;
    default: return null;
  }
}

/* ── running a search ────────────────────────────────────────────────── */

export interface SearchResult {
  /** Card (O-line) indexes, in the order shown. */
  hits: number[];
  /** The printing each hit shows (and adds): the one a set/rarity/year term matched, else the card's cover. */
  covers: Map<number, number>;
  total: number;
  remote: boolean;
  error?: string;
}

export const SEARCH_LIMIT = 200;

/** Delay before running, in ms: typing settles faster for local searches than for a request to Scryfall. */
export function searchDelay(q: string): number {
  if (!hasSyntax(q)) return 120;
  const n = parseQuery(q);
  return n && isLocal(n) ? 150 : 450;
}

const coversOf = (c: Catalog, idxs: number[]) => new Map(idxs.map((oi) => [oi, coverPrinting(c, oi)]));

/** The ranked name search, the local advanced search, or Scryfall. */
export async function runCardSearch(q: string, c: Catalog, signal?: AbortSignal, nameLimit = 40): Promise<SearchResult> {
  const trimmed = q.trim();
  if (!hasSyntax(trimmed)) {
    const hits = searchCatalog(c, trimmed, nameLimit);
    return { hits, covers: coversOf(c, hits), total: hits.length, remote: false };
  }
  const node = parseQuery(trimmed);
  if (node && isLocal(node)) return localSearch(node, c);
  return scryfallSearch(trimmed, node, c, signal);
}

const EXTRA = /^(Token|Card|Emblem)\b|\bToken\b/;

/** Name-search tiers over the given cards (exact, word start, substring, tokens), as `searchCatalog` ranks. */
function rank(c: Catalog, idxs: number[], query: string): number[] {
  const q = normName(query);
  if (q.length < 2) return [];
  const tiers: number[][] = [[], [], [], []];
  const word = " " + q;
  for (const i of idxs) {
    const n = c.oNorm[i];
    let t = -1;
    if (n === q) t = 0;
    else if (n.startsWith(q) || n.includes(word)) t = 1;
    else if (n.includes(q)) t = 2;
    if (t < 0) continue;
    if (t > 0 && EXTRA.test(c.oType[i])) t = 3;
    tiers[t].push(i);
  }
  return tiers.flatMap((tier) =>
    tier.sort((a, b) => c.pCount[b] - c.pCount[a] || c.oNorm[a].length - c.oNorm[b].length || (c.oNorm[a] < c.oNorm[b] ? -1 : 1)));
}

/** Every card (with a printing term, every printing) checked on the local data. */
export function localSearch(node: QueryNode, c: Catalog): SearchResult {
  const found: number[] = [];
  let covers = new Map<number, number>();
  if (usesPrinting(node)) {
    // Prefer English with an image, then the original printing, then newest (pack order).
    const score = (p: number) => (c.pLang[p] === "en" && c.pFaces[p] > 0 ? 2 : 0) + (c.oOriginal[c.pOracle[p]] === p ? 1 : 0);
    for (let p = 0; p < c.printings; p++) {
      const oi = c.pOracle[p];
      if (!matches(node, c, oi, p)) continue;
      const best = covers.get(oi);
      if (best == null) {
        covers.set(oi, p);
        found.push(oi);
      } else if (score(p) > score(best)) covers.set(oi, p);
    }
  } else {
    for (let oi = 0; oi < c.oracles; oi++) if (matches(node, c, oi, null)) found.push(oi);
  }
  let ordered = found.slice().sort((a, b) => (c.oName[a] < c.oName[b] ? -1 : c.oName[a] > c.oName[b] ? 1 : 0));
  const words = nameWords(node).join(" ");
  if (normName(words).length >= 2) {
    const ranked = rank(c, found, words);
    const inRank = new Set(ranked);
    ordered = [...ranked, ...ordered.filter((oi) => !inRank.has(oi))];
  }
  const shown = ordered.slice(0, SEARCH_LIMIT);
  if (!covers.size) covers = coversOf(c, shown);
  return { hits: shown, covers, total: found.length, remote: false };
}

interface ScryfallPage {
  total_cards?: number;
  data?: { id: string; oracle_id?: string }[];
  details?: string;
}

/** Scryfall's /cards/search (one card per Oracle card, by name), matched to the local data by printing id. */
export async function scryfallSearch(q: string, node: QueryNode | null, c: Catalog, signal?: AbortSignal): Promise<SearchResult> {
  const url = `https://api.scryfall.com/cards/search?${new URLSearchParams({ q, unique: "cards", order: "name" })}`;
  let res: Response;
  let page: ScryfallPage;
  try {
    // Browsers send their own User-Agent (it can't be set from a page); Scryfall asks for Accept.
    res = await fetch(url, { headers: { Accept: "application/json" }, signal });
    page = (await res.json()) as ScryfallPage;
  } catch (e) {
    if (e instanceof DOMException && e.name === "AbortError") return { hits: [], covers: new Map(), total: 0, remote: true };
    return { hits: [], covers: new Map(), total: 0, remote: true, error: "Searching card text needs a connection to Scryfall." };
  }
  if (res.status === 404) return { hits: [], covers: new Map(), total: 0, remote: true };
  if (res.status !== 200) {
    return { hits: [], covers: new Map(), total: 0, remote: true, error: page.details ?? `Scryfall couldn't read that search (${res.status})` };
  }
  const idxs: number[] = [];
  const seen = new Set<number>();
  const shownPrinting = new Map<number, number>();
  for (const card of page.data ?? []) {
    const p = c.printingIndex.get(card.id.toLowerCase());
    if (p != null) {
      const oi = c.pOracle[p];
      if (!seen.has(oi)) { seen.add(oi); idxs.push(oi); shownPrinting.set(oi, p); }
    } else if (card.oracle_id) {
      const oi = c.oId.indexOf(card.oracle_id.toLowerCase());
      if (oi >= 0 && !seen.has(oi)) { seen.add(oi); idxs.push(oi); }
    }
  }
  const hits = idxs.slice(0, SEARCH_LIMIT);
  // Scryfall's printing only when the query names one (a set, a year, …); otherwise the usual cover.
  const covers = coversOf(c, hits);
  if (node == null || usesPrinting(node)) for (const [oi, p] of shownPrinting) if (covers.has(oi)) covers.set(oi, p);
  return { hits, covers, total: page.total_cards ?? hits.length, remote: true };
}

/* ── the Advanced form ───────────────────────────────────────────────── */

export type ColorMode = "exactly" | "including" | "atMost";

export interface AdvancedFields {
  name: string;
  text: string;
  type: string;
  /** W U B R G, or C for colorless. */
  colors: string[];
  colorMode: ColorMode;
  mvOp: string;
  mv: string;
  /** c u r m */
  rarities: string[];
  set: string;
  format: string;
}

export const EMPTY_ADVANCED: AdvancedFields = {
  name: "", text: "", type: "", colors: [], colorMode: "including", mvOp: "=", mv: "", rarities: [], set: "", format: "",
};

/** The form's fields as Scryfall syntax, written into the search box. */
export function advancedQuery(f: AdvancedFields): string {
  const quoted = (s: string) => {
    const t = s.trim().replace(/"/g, "");
    return t.includes(" ") ? `"${t}"` : t;
  };
  const parts: string[] = [];
  const n = f.name.trim();
  if (n) parts.push(n);
  if (f.text.trim()) parts.push(`o:${quoted(f.text)}`);
  for (const word of f.type.split(" ")) if (word) parts.push(`t:${word.toLowerCase()}`);
  if (f.colors.includes("C")) parts.push("c:c");
  else if (f.colors.length) {
    const letters = Array.from("WUBRG").filter((x) => f.colors.includes(x)).join("").toLowerCase();
    parts.push(`c${f.colorMode === "exactly" ? "=" : f.colorMode === "atMost" ? "<=" : ">="}${letters}`);
  }
  const mv = num(f.mv.replace(",", "."));
  if (mv != null) parts.push(`mv${f.mvOp}${String(mv)}`);
  const r = Array.from("curm").filter((x) => f.rarities.includes(x)).map((x) => `r:${x}`);
  if (r.length === 1) parts.push(r[0]);
  else if (r.length > 1) parts.push(`(${r.join(" or ")})`);
  const s = f.set.trim().toLowerCase();
  if (s) parts.push(`s:${s}`);
  if (f.format) parts.push(`f:${f.format}`);
  return parts.join(" ");
}
