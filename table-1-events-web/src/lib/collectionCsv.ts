// Collection CSV import and export (contract/collection-import-2026-10-17.md). parseCsv reads another app's export
// into rows (format detection, columns, each app's words for finish, condition and language); exportCsv writes the
// collection in Moxfield's or ManaBox's layout; ImportResolver matches rows to printings in the catalog.
// Same rules as apps/ios/Table1/Library/CollectionCSV.swift; the fixtures in testdata/collection-import test both.
import { coverPrinting, normName, type Catalog } from "./catalog";
import type { Condition, Finish } from "./collection";

export type CsvFormat = "manabox" | "moxfield" | "archidekt" | "deckbox" | "dragonshield" | "tcgplayer" | "delverlens" | "other";

export const FORMAT_LABEL: Record<CsvFormat, string> = {
  manabox: "ManaBox", moxfield: "Moxfield", archidekt: "Archidekt", deckbox: "Deckbox", dragonshield: "Dragon Shield",
  tcgplayer: "TCGplayer", delverlens: "Delver Lens", other: "CSV",
};

/** One line of an imported file, its values already mapped to ours. */
export interface ImportRow {
  /** 1-based line number in the file. */
  line: number;
  name: string;
  /** Lowercased. */
  setCode: string | null;
  setName: string | null;
  cn: string | null;
  scryfallId: string | null;
  qty: number;
  finish: Finish;
  condition: Condition;
  lang: string;
  /** Why the line can't be read at all (it's listed as unmatched). */
  problem: string | null;
}

export interface ParsedImport {
  format: CsvFormat;
  rows: ImportRow[];
}

export const rowSetLabel = (r: ImportRow) =>
  [r.setCode?.toUpperCase() ?? r.setName, r.cn ? `#${r.cn}` : null].filter(Boolean).join(" ");

/* ── reading ──────────────────────────────────────────────────────────── */

/** Lowercase, letters and digits only: `Collector's number` → `collectorsnumber`. */
export const headerKey = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");

export function detectFormat(h: Set<string>, sepLine = false): CsvFormat {
  if (h.has("quantityx") || h.has("delverlocalid")) return "delverlens";
  if ((h.has("foldername") && h.has("cardname")) || (sepLine && h.has("tradequantity"))) return "dragonshield";
  if (h.has("simplename") || (h.has("tcgplayerid") && h.has("productname"))) return "tcgplayer";
  if (h.has("manaboxid") || h.has("bindertype") || h.has("purchasepricecurrency")) return "manabox";
  if ((h.has("editioncode") && h.has("editionname")) || (h.has("dateadded") && h.has("finish"))) return "archidekt";
  if (h.has("tradelistcount") && h.has("cardnumber")) return "deckbox";
  if (h.has("tradelistcount") && h.has("edition")) return "moxfield";
  return "other";
}

/** Which column holds what, by format (contract table "Columns"). */
function columns(keys: string[], format: CsvFormat) {
  const col = (names: string[]) => {
    for (const n of names) {
      const i = keys.indexOf(n);
      if (i >= 0) return i;
    }
    return null;
  };
  let setCode: number | null, setName: number | null, setEither: number | null = null;
  switch (format) {
    case "moxfield":
      setCode = col(["edition", "setcode", "editioncode"]);
      setName = col(["setname", "editionname"]);
      break;
    case "deckbox":
    case "delverlens":
      setCode = col(["editioncode", "setcode"]);
      setName = col(["edition", "editionname", "setname"]);
      break;
    case "tcgplayer":
      setCode = col(["setcode"]);
      setName = col(["set", "setname"]);
      break;
    default:
      setCode = col(["setcode", "editioncode", "code"]);
      setName = col(["setname", "editionname", "expansion"]);
      if (setCode == null || setName == null) setEither = col(["set", "edition"]);
  }
  return {
    name: col(format === "tcgplayer" ? ["simplename", "productname", "name"] : ["name", "cardname", "card", "simplename", "productname"]),
    fullName: col(["name", "productname"]),
    qty: col(["quantity", "count", "qty", "quantityx", "totalquantity", "amount"]),
    setCode, setName, setEither,
    cn: col(["collectornumber", "cardnumber", "collectorsnumber", "number", "cn", "collectorno"]),
    finish: col(["foil", "finish", "printing", "foiling"]),
    condition: col(["condition"]),
    lang: col(["language", "lang"]),
    id: col(["scryfallid", "scryfalluuid"]),
  };
}

/** `2x` → 2, blank → 1, not a number → null. */
export function parseQuantity(v: string): number | null {
  const t = v.trim();
  if (!t) return 1;
  if (!/^[0-9x ]+$/i.test(t) || !/[0-9]/.test(t)) return null;
  return Number(t.replace(/[^0-9]/g, "").slice(0, 9));
}

export function parseFinish(v: string): Finish {
  const s = v.trim().toLowerCase();
  if (s.includes("etched")) return "etched";
  if (["", "normal", "nonfoil", "non-foil", "non foil", "no", "false", "0", "n", "regular"].includes(s)) return "nonfoil";
  if (s.includes("foil") || ["true", "yes", "1", "y"].includes(s)) return "foil";
  return "nonfoil";
}

const US_CONDITIONS: Record<string, Condition> = {
  m: "NM", mint: "NM", nm: "NM", nearmint: "NM", nmm: "NM",
  lp: "LP", lightlyplayed: "LP", goodlightlyplayed: "LP", slightlyplayed: "LP", sp: "LP",
  ex: "LP", excellent: "LP", good: "LP", gd: "LP", lightplayed: "LP",
  mp: "MP", moderatelyplayed: "MP", played: "MP", pl: "MP",
  hp: "HP", heavilyplayed: "HP",
  d: "DMG", dmg: "DMG", damaged: "DMG", poor: "DMG", po: "DMG",
};
const CARDMARKET_CONDITIONS: Record<string, Condition> = {
  m: "NM", mint: "NM", nm: "NM", nearmint: "NM",
  ex: "LP", excellent: "LP", gd: "LP", good: "LP",
  lp: "MP", lightplayed: "MP", lightlyplayed: "MP",
  pl: "HP", played: "HP",
  po: "DMG", poor: "DMG",
};

export function parseCondition(v: string, cardmarket: boolean): Condition {
  const k = headerKey(v);
  return (cardmarket ? CARDMARKET_CONDITIONS[k] : undefined) ?? US_CONDITIONS[k] ?? "NM";
}

const LANGUAGES: Record<string, string> = {
  en: "en", english: "en", de: "de", german: "de", deutsch: "de", fr: "fr", french: "fr",
  it: "it", italian: "it", es: "es", sp: "es", spanish: "es", pt: "pt", ptbr: "pt", portuguese: "pt",
  portuguesebrazil: "pt", ja: "ja", jp: "ja", japanese: "ja", ko: "ko", kr: "ko", korean: "ko",
  ru: "ru", russian: "ru", zhs: "zhs", zhcn: "zhs", zhhans: "zhs", cs: "zhs", chinese: "zhs",
  chinesesimplified: "zhs", simplifiedchinese: "zhs", zht: "zht", zhtw: "zht", zhhant: "zht", ct: "zht",
  chinesetraditional: "zht", traditionalchinese: "zht", he: "he", hebrew: "he", la: "la", latin: "la",
  grc: "grc", ancientgreek: "grc", ar: "ar", arabic: "ar", sa: "sa", sanskrit: "sa", ph: "ph",
  phyrexian: "ph", qya: "qya", quenya: "qya",
};

export const parseLanguage = (v: string) => LANGUAGES[headerKey(v)] ?? "en";

/** The delimiter that appears most in the first line, outside quotes. */
export function guessDelimiter(text: string, from = 0): string {
  const counts: Record<string, number> = { ",": 0, "\t": 0, ";": 0 };
  let quoted = false;
  for (let i = from; i < text.length; i++) {
    const ch = text[i];
    if (ch === "\n" && !quoted) break;
    if (ch === '"') quoted = !quoted;
    else if (!quoted && ch in counts) counts[ch]++;
  }
  return [",", "\t", ";"].reduce((a, b) => (counts[b] > counts[a] ? b : a));
}

/** RFC 4180 records (quotes, `""`, newlines in quotes, CRLF or LF), each with its first line number. */
export function csvRecords(text: string, delimiter: string, from = 0, firstLine = 1): { line: number; fields: string[] }[] {
  const out: { line: number; fields: string[] }[] = [];
  let fields: string[] = [];
  let field = "";
  let quoted = false, wasQuoted = false;
  let line = firstLine, recordLine = firstLine;
  let fieldStart = from;
  const endField = (end: number) => {
    let f = wasQuoted ? field : text.slice(fieldStart, end);
    if (!wasQuoted && f.endsWith("\r")) f = f.slice(0, -1);
    fields.push(f);
    field = "";
    wasQuoted = false;
  };
  const endRecord = (end: number) => {
    endField(end);
    if (!(fields.length === 1 && fields[0] === "")) out.push({ line: recordLine, fields });
    fields = [];
  };
  for (let i = from; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; } else quoted = false;
      } else {
        if (ch === "\n") line++;
        field += ch;
      }
    } else if (ch === '"' && i === fieldStart) {
      quoted = true;
      wasQuoted = true;
    } else if (ch === delimiter) {
      endField(i);
      fieldStart = i + 1;
    } else if (ch === "\n") {
      endRecord(i);
      fieldStart = i + 1;
      line++;
      recordLine = line;
    } else if (wasQuoted && !quoted && ch !== "\r") {
      field += ch; // text after a closing quote is kept, like the iOS reader
    }
  }
  if (fieldStart < text.length || fields.length) endRecord(text.length);
  return out;
}

export class CsvError extends Error {}

export function parseCsv(input: string): ParsedImport {
  const text = input.charCodeAt(0) === 0xfeff ? input.slice(1) : input;
  let from = 0, firstLine = 1;
  let delimiter: string | null = null;
  // Dragon Shield and Excel: a first line `sep=,` names the delimiter.
  const firstEnd = text.indexOf("\n") < 0 ? text.length : text.indexOf("\n");
  const first = text.slice(0, firstEnd).replace(/^["\r ]+|["\r ]+$/g, "").toLowerCase();
  if (first.startsWith("sep=") && first.length === 5) {
    delimiter = first[4];
    from = Math.min(firstEnd + 1, text.length);
    firstLine = 2;
  }
  const sepLine = delimiter != null;
  const records = csvRecords(text, delimiter ?? guessDelimiter(text, from), from, firstLine);
  if (!records.length) throw new CsvError("This file is empty.");
  const keys = records[0].fields.map(headerKey);
  const format = detectFormat(new Set(keys), sepLine);
  const cols = columns(keys, format);
  if (cols.name == null && cols.id == null) throw new CsvError("This file has no card name column.");
  const cardmarket = format === "manabox" || format === "dragonshield";

  const rows: ImportRow[] = [];
  for (let ri = 1; ri < records.length; ri++) {
    const r = records[ri];
    const at = (i: number | null) => (i == null || i >= r.fields.length ? "" : r.fields[i].trim());
    const name = at(cols.name), id = at(cols.id);
    if (!name && !id) continue;
    let problem: string | null = null;
    let qty = 1;
    if (cols.qty != null) {
      const q = parseQuantity(at(cols.qty));
      if (q == null) problem = "Quantity isn't a number";
      else qty = q;
    }
    if (qty === 0 && !problem) continue;
    let finish = parseFinish(at(cols.finish));
    let rawCondition = at(cols.condition);
    // TCGplayer seller exports grade foils as "Near Mint Foil"; its app marks etched in the name.
    if (rawCondition.toLowerCase().endsWith(" foil")) {
      rawCondition = rawCondition.slice(0, -5);
      if (finish === "nonfoil") finish = "foil";
    }
    if (format === "tcgplayer" && at(cols.fullName).toLowerCase().includes("etched")) finish = "etched";
    let setCode = at(cols.setCode).toLowerCase();
    if (format === "dragonshield") setCode = setCode.replace(/^(gk[12])_.*$/, "$1"); // GK2_AZORIU → gk2
    let setName = at(cols.setName);
    if (cols.setEither != null) {
      const v = at(cols.setEither);
      if (!setCode) setCode = v.toLowerCase();
      if (!setName) setName = v;
    }
    let cn = at(cols.cn);
    if (cn.includes("/")) cn = cn.slice(0, cn.indexOf("/"));
    rows.push({
      line: r.line, name, setCode: setCode || null, setName: setName || null, cn: cn || null,
      scryfallId: id ? id.toLowerCase() : null, qty, finish,
      condition: parseCondition(rawCondition, cardmarket), lang: parseLanguage(at(cols.lang)), problem,
    });
  }
  return { format, rows };
}

/* ── writing ──────────────────────────────────────────────────────────── */

export type ExportLayout = "moxfield" | "manabox";

export interface ExportCard {
  name: string;
  set: string;
  setName: string;
  cn: string;
  rarity: string;
  cardId: string;
  finish: Finish;
  condition: Condition;
  lang: string;
  qty: number;
}

const MOXFIELD_CONDITION: Record<Condition, string> = {
  NM: "Near Mint", LP: "Lightly Played", MP: "Moderately Played", HP: "Heavily Played", DMG: "Damaged",
};
const MANABOX_CONDITION: Record<Condition, string> = { NM: "near_mint", LP: "excellent", MP: "light_played", HP: "played", DMG: "poor" };
const LANGUAGE_NAME: Record<string, string> = {
  en: "English", de: "German", fr: "French", it: "Italian", es: "Spanish", pt: "Portuguese", ja: "Japanese", ko: "Korean",
  ru: "Russian", zhs: "Chinese Simplified", zht: "Chinese Traditional", he: "Hebrew", la: "Latin", grc: "Ancient Greek",
  ar: "Arabic", sa: "Sanskrit", ph: "Phyrexian", qya: "Quenya",
};
const RARITY: Record<string, string> = { c: "common", u: "uncommon", r: "rare", m: "mythic", s: "special", b: "bonus" };

const cmp = (a: string | number, b: string | number) => (a < b ? -1 : a > b ? 1 : 0);

/** Sorted by name, set and collector number; CRLF line ends. */
export function exportCsv(cards: ExportCard[], layout: ExportLayout): string {
  const sorted = [...cards].sort((a, b) =>
    cmp(a.name, b.name) || cmp(a.set, b.set) || cmp(a.cn.length, b.cn.length) || cmp(a.cn, b.cn)
    || cmp(`${a.finish}|${a.condition}|${a.lang}`, `${b.finish}|${b.condition}|${b.lang}`));
  const lines: string[] = [];
  if (layout === "moxfield") {
    const q = (s: string) => `"${s.replace(/"/g, '""')}"`;
    lines.push(["Count", "Tradelist Count", "Name", "Edition", "Condition", "Language", "Foil", "Tags", "Last Modified",
      "Collector Number", "Alter", "Proxy", "Purchase Price"].map(q).join(","));
    for (const c of sorted) {
      lines.push([String(c.qty), "0", c.name, c.set, MOXFIELD_CONDITION[c.condition] ?? "Near Mint", LANGUAGE_NAME[c.lang] ?? "English",
        c.finish === "nonfoil" ? "" : c.finish, "", "", c.cn, "False", "False", ""].map(q).join(","));
    }
  } else {
    const q = (s: string) => (/[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s);
    lines.push("Name,Set code,Set name,Collector number,Foil,Rarity,Quantity,ManaBox ID,Scryfall ID,Purchase price,Misprint,Altered,Condition,Language,Purchase price currency");
    for (const c of sorted) {
      lines.push([c.name, c.set.toUpperCase(), c.setName, c.cn, c.finish === "nonfoil" ? "normal" : c.finish, RARITY[c.rarity] ?? "common",
        String(c.qty), "", c.cardId, "", "false", "false", MANABOX_CONDITION[c.condition] ?? "near_mint", c.lang, "USD"].map(q).join(","));
    }
  }
  return lines.join("\r\n") + "\r\n";
}

/* ── matching ─────────────────────────────────────────────────────────── */

/** How a line found its printing (contract "Matching"). */
export type MatchHow = "id" | "setNumber" | "setName" | "name" | "fixed";

export interface ResolvedLine {
  row: ImportRow;
  /** Printing index in the catalog. */
  p: number;
  finish: Finish;
  how: MatchHow;
}

/** One collection item the import writes. */
export interface ImportItem {
  cardId: string;
  finish: Finish;
  condition: Condition;
  lang: string;
  qty: number;
}

export const importItemKey = (it: { cardId: string; finish: string; condition: string; lang: string }) =>
  `${it.cardId}|${it.finish}|${it.condition}|${it.lang}`;

/** Lines on the same item summed, in first-seen order. */
export function importItems(c: Catalog, lines: ResolvedLine[]): ImportItem[] {
  const by = new Map<string, ImportItem>();
  for (const l of lines) {
    const it: ImportItem = { cardId: c.pId[l.p], finish: l.finish, condition: l.row.condition, lang: l.row.lang, qty: l.row.qty };
    const k = importItemKey(it);
    const had = by.get(k);
    if (had) had.qty += it.qty;
    else by.set(k, it);
  }
  return [...by.values()];
}

const FINISH_CODE: Record<Finish, string> = { nonfoil: "n", foil: "f", etched: "e" };

/**
 * Matches imported rows to printings: Scryfall id, then set + collector number, then set + name, then the name's
 * original printing. Indexes are built once per catalog and file.
 */
export class ImportResolver {
  private setByName = new Map<string, string>();
  /** Set code → its printings. */
  private bySet = new Map<string, number[]>();
  private byFullName = new Map<string, number>();
  private byFace = new Map<string, number>();
  private faces: string[][] = [];
  private sets = new Map<string, { byCn: Map<string, number[]>; byOracle: Map<number, number[]> }>();
  private nameCache = new Map<string, number | null>();

  constructor(private c: Catalog, setNames: { code: string; name: string }[]) {
    for (const s of setNames) {
      const k = normName(s.name);
      if (!this.setByName.has(k)) this.setByName.set(k, s.code);
    }
    for (let p = 0; p < c.printings; p++) (this.bySet.get(c.pSet[p]) ?? this.bySet.set(c.pSet[p], []).get(c.pSet[p])!).push(p);
    // Two cards with one name: the non-token one with more printings.
    const token = (i: number) => c.oType[i].startsWith("Token");
    const better = (a: number, b: number | undefined) =>
      b === undefined || (token(a) !== token(b) ? !token(a) : c.pCount[a] > c.pCount[b]);
    for (let i = 0; i < c.oracles; i++) {
      const f = c.oFaces[i] ? c.oFaces[i].split(" // ").map(normName) : [];
      this.faces[i] = f;
      if (better(i, this.byFullName.get(c.oNorm[i]))) this.byFullName.set(c.oNorm[i], i);
      for (const k of f) if (better(i, this.byFace.get(k))) this.byFace.set(k, i);
    }
  }

  /** Matched lines in file order, and the rows that matched nothing. */
  resolveAll(rows: ImportRow[]): { matched: ResolvedLine[]; unmatched: ImportRow[] } {
    const matched: ResolvedLine[] = [], unmatched: ImportRow[] = [];
    for (const r of rows) {
      const m = this.resolve(r);
      if (m) matched.push(m);
      else unmatched.push(r);
    }
    return { matched, unmatched };
  }

  resolve(r: ImportRow): ResolvedLine | null {
    if (r.problem) return null;
    if (r.scryfallId) {
      const p = this.c.printingIndex.get(r.scryfallId);
      if (p !== undefined) return this.line(r, p, "id");
    }
    const idx = this.oracle(r.name);
    for (const code of this.setCandidates(r)) {
      const set = this.printingsOf(code);
      if (r.cn) {
        for (const v of [r.cn, r.cn.toLowerCase(), r.cn.replace(/^0+/, "")]) {
          if (!v) continue;
          const found = (set.byCn.get(v) ?? []).filter((p) => idx == null || !r.name || this.matches(this.c.pOracle[p], r.name, idx));
          const p = this.best(found, r.lang);
          if (p != null) return this.line(r, p, "setNumber");
        }
      }
      if (idx != null) {
        const p = this.best(set.byOracle.get(idx) ?? [], r.lang);
        if (p != null) return this.line(r, p, "setName");
      }
    }
    if (idx != null) return this.line(r, coverPrinting(this.c, idx), "name");
    return null;
  }

  /** A line fixed by hand: the picked card's printing in the line's set when it has one, else its original printing. */
  resolveAs(r: ImportRow, oracle: number): ResolvedLine {
    const row = { ...r, problem: null };
    for (const code of this.setCandidates(row)) {
      const p = this.best(this.printingsOf(code).byOracle.get(oracle) ?? [], row.lang);
      if (p != null) return this.line(row, p, "fixed");
    }
    return this.line(row, coverPrinting(this.c, oracle), "fixed");
  }

  /** Exact name, then a face, then the name without a trailing `[…]`/`(…)` or ` Token`/` Emblem`. */
  oracle(raw: string): number | null {
    const hit = this.nameCache.get(raw);
    if (hit !== undefined) return hit;
    const found = this.lookup(raw);
    this.nameCache.set(raw, found);
    return found;
  }

  private lookup(raw: string): number | null {
    const n = normName(raw);
    if (!n) return null;
    const i = this.byFullName.get(n) ?? this.byFace.get(n);
    if (i !== undefined) return i;
    let s = raw.trim();
    for (;;) {
      const t = s.replace(/\s*[[(][^[\]()]*[\])]$/, "");
      if (t === s) break;
      s = t;
    }
    s = s.replace(/\s+(token|emblem)$/i, "");
    const n2 = normName(s);
    if (n2 === n || !n2) return null;
    return this.byFullName.get(n2) ?? this.byFace.get(n2) ?? null;
  }

  private matches(oracle: number, name: string, nameIdx: number | null): boolean {
    if (oracle === nameIdx) return true;
    const n = normName(name);
    return this.c.oNorm[oracle] === n || this.faces[oracle].includes(n);
  }

  /** The set code if the catalog has it, else the set name's code (Deckbox token sets "Extras: X" → tX first). */
  private setCandidates(r: ImportRow): string[] {
    const out: string[] = [];
    if (r.setCode && this.bySet.has(r.setCode)) out.push(r.setCode);
    if (r.setName) {
      let n = r.setName;
      let extras = false;
      if (n.toLowerCase().startsWith("extras:")) {
        n = n.slice(7);
        extras = true;
      }
      const k = normName(n);
      const code = this.setByName.get(k) ?? (this.bySet.has(n.toLowerCase()) ? n.toLowerCase() : undefined)
        ?? (k.endsWith(" edition") ? this.setByName.get(k.slice(0, -8)) : undefined);
      if (code) {
        if (extras && this.bySet.has("t" + code)) out.push("t" + code);
        if (this.bySet.has(code)) out.push(code);
      }
    }
    return [...new Set(out)];
  }

  private printingsOf(code: string) {
    let s = this.sets.get(code);
    if (!s) {
      s = { byCn: new Map(), byOracle: new Map() };
      for (const p of this.bySet.get(code) ?? []) {
        const cn = this.c.pCn[p], o = this.c.pOracle[p];
        (s.byCn.get(cn) ?? s.byCn.set(cn, []).get(cn)!).push(p);
        (s.byOracle.get(o) ?? s.byOracle.set(o, []).get(o)!).push(p);
      }
      this.sets.set(code, s);
    }
    return s;
  }

  /** The copy's language printed, then English, then the original printing, then the lowest collector number. */
  private best(ps: number[], lang: string): number | null {
    const c = this.c;
    const num = (p: number) => {
      const m = /^\d+/.exec(c.pCn[p]);
      return m ? Number(m[0]) : Number.MAX_SAFE_INTEGER;
    };
    const key = (p: number): [number, number, number, number] => [
      c.pLang[p] === lang ? 0 : c.pLang[p] === "en" ? 1 : 2, c.oOriginal[c.pOracle[p]] === p ? 0 : 1, num(p), p,
    ];
    const less = (a: number[], b: number[]) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2] || a[3] - b[3];
    let best: number | null = null;
    let bk: number[] | null = null;
    for (const p of ps) {
      const k = key(p);
      if (!bk || less(k, bk) < 0) {
        best = p;
        bk = k;
      }
    }
    return best;
  }

  /** The file's finish when the printing has it; etched falls back to foil, then the printing's first finish. */
  private line(r: ImportRow, p: number, how: MatchHow): ResolvedLine {
    const have = this.c.pFinishes[p];
    const first: Finish = have.includes("n") ? "nonfoil" : have.includes("f") ? "foil" : have.includes("e") ? "etched" : "nonfoil";
    const finish: Finish = have.includes(FINISH_CODE[r.finish]) ? r.finish : r.finish === "etched" && have.includes("f") ? "foil" : first;
    return { row: r, p, finish, how };
  }
}
