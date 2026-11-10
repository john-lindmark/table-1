// The Limited page's cards, the grid's Overall column, mana symbols and pasted event codes
// (contract/insights-2026-10-24.md § The Limited page / § Matchups "Overall"; contract/qr-sign-up-2026-10-23.md
// § Enter or paste a code). Shared cases: testdata/insights/limited-home.json, overall.json,
// testdata/mana-symbols/cases.json, testdata/join-code/cases.json.
import { delta, pct1 } from "./insightCharts";
import { matchup, matchupRows, type LCard, type Matchups } from "./insights";

/** Cards shown before Show all; hits from other sets once the picked set has none; the shortest query searched. */
export const LIMITED_TOP = 10;
export const OTHERS_MAX = 20;
export const MIN_QUERY = 2;

export const LIMITED_SORTS = [
  { value: "gih", label: "Win rate in hand", code: "GIH WR" }, { value: "oh", label: "Win rate in opening hand", code: "OH WR" },
  { value: "iwd", label: "Improvement when drawn", code: "IWD" }, { value: "ata", label: "Average pick taken", code: "ATA" },
] as const;
export const LIMITED_RARITIES = [
  { value: "all", label: "Any rarity" }, { value: "common", label: "Common" }, { value: "uncommon", label: "Uncommon" },
  { value: "rare", label: "Rare" }, { value: "mythic", label: "Mythic" },
];
export const LIMITED_COLORS = [
  { value: "all", label: "Any color", code: "Any color" }, { value: "W", label: "White", code: "W" }, { value: "U", label: "Blue", code: "U" },
  { value: "B", label: "Black", code: "B" }, { value: "R", label: "Red", code: "R" }, { value: "G", label: "Green", code: "G" },
  { value: "M", label: "Multicolor", code: "Multi" }, { value: "C", label: "Colorless", code: "C" },
];

type Sortable = Pick<LCard, "n" | "r" | "col" | "gih" | "gih_n" | "oh" | "iwd" | "ata">;

/** The cards the filters keep, best first: the sort's value high to low (ATA low to high), cards without one last;
 *  ties by games in hand, then name. A cube's cards have no rarity, so the rarity filter is ignored there. */
export function limitedCards<T extends Sortable>(cards: T[], sort: string, rarity: string, color: string): T[] {
  const rated = cards.some((c) => c.r);
  const kept = cards.filter((c) => {
    if (rated && rarity !== "all" && c.r !== rarity) return false;
    const col = c.col || "C";
    if (color === "all") return true;
    if (color === "M") return col.length > 1 && col !== "C";
    return col === color;
  });
  const key = (c: T) => (sort === "oh" ? c.oh : sort === "iwd" ? c.iwd : sort === "ata" ? (c.ata == null ? null : -c.ata) : c.gih);
  return [...kept].sort((a, b) => {
    const x = key(a), y = key(b);
    if (x != null && y != null && x !== y) return y - x;
    if (x != null && y == null) return -1;
    if (x == null && y != null) return 1;
    return a.gih_n !== b.gih_n ? b.gih_n - a.gih_n : a.n < b.n ? -1 : a.n > b.n ? 1 : 0;
  });
}

/** A row's number for the sort, and for the win rates how far it sits from the view's average, in points. */
export function limitedValue(c: Sortable, sort: string, average: number): { value: string; vs: string | null } {
  if (sort === "ata") return { value: c.ata == null ? "–" : c.ata.toFixed(1), vs: null };
  if (sort === "iwd") return { value: c.iwd == null ? "–" : delta(c.iwd), vs: null };
  const x = sort === "oh" ? c.oh : c.gih;
  return { value: pct1(x), vs: x == null ? null : delta(x - average) };
}

/** Lower case, accents and apostrophes gone, everything else but letters and digits a single space. */
export function searchNorm(s: string): string {
  return s.toLowerCase().replace(/æ/g, "ae").normalize("NFKD").replace(/[̀-ͯ]/g, "").replace(/['’]/g, "")
    .replace(/[^a-z0-9]+/g, " ").trim();
}

function rank(name: string, q: string): number | null {
  const n = searchNorm(name);
  if (n.startsWith(q)) return 0;
  if ((" " + n).includes(" " + q)) return 1;
  return n.includes(q) ? 2 : null;
}

const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/** The picked set's cards whose name holds the query (all of them, whatever the filters), starts first; when none
 *  does, the other sets' (up to OTHERS_MAX), with the set each is in. */
export function limitedSearch(query: string, here: string[], others: { key: string; names: string[] }[]): { here: string[]; elsewhere: [string, string][] } {
  const q = searchNorm(query);
  if (q.length < MIN_QUERY) return { here: [], elsewhere: [] };
  const hits = here.flatMap((n) => { const r = rank(n, q); return r == null ? [] : [{ r, n }]; })
    .sort((a, b) => a.r - b.r || cmp(a.n, b.n));
  if (hits.length) return { here: hits.map((h) => h.n), elsewhere: [] };
  const more: { r: number; n: string; i: number; k: string }[] = [];
  others.forEach((s, i) => { for (const n of s.names) { const r = rank(n, q); if (r != null) more.push({ r, n, i, k: s.key }); } });
  more.sort((a, b) => a.r - b.r || cmp(a.n, b.n) || a.i - b.i);
  return { here: [], elsewhere: more.slice(0, OTHERS_MAX).map((m) => [m.k, m.n]) };
}

/** A grid row's overall match record: the window's Meta now record for the archetype when it has one, else the sum
 *  of its squares against every other row. */
export function overall(share: { a: number; rec?: [number, number, number] | number[] | null }[], m: Matchups, a: number):
  { wins: number; losses: number; draws: number; from: "meta" | "grid" } | null {
  const rec = share.find((s) => s.a === a)?.rec;
  if (rec && rec.length === 3 && rec[0] + rec[1] > 0) return { wins: rec[0], losses: rec[1], draws: rec[2], from: "meta" };
  let wins = 0, losses = 0, draws = 0;
  for (const b of matchupRows(m)) {
    if (b === a) continue;
    const v = matchup(m, a, b);
    if (v) { wins += v.wins; losses += v.losses; draws += v.draws; }
  }
  return wins + losses ? { wins, losses, draws, from: "grid" } : null;
}

/** "{2}{W}{U/B}" → ["2", "W", "UB"]; a second face's cost after " // " comes after "//". */
export function manaSymbols(cost: string): string[] {
  const out: string[] = [];
  cost.split(" // ").forEach((face, i) => {
    if (i) out.push("//");
    for (const m of face.matchAll(/\{([^}]+)\}/g)) out.push(m[1].replace(/\//g, "").toUpperCase());
  });
  return out;
}

/** The symbols public/mana holds (tools/mana/make.py); another draws as a grey circle with its text. */
export const MANA_SYMBOLS = new Set(["0", "1", "10", "11", "12", "13", "14", "15", "16", "2", "2B", "2G", "2R", "2U", "2W", "3", "4", "5", "6", "7", "8", "9",
  "B", "BG", "BP", "BR", "C", "CB", "CG", "CP", "CR", "CU", "CW", "D", "G", "GP", "GU", "GUP", "GW", "GWP", "L", "R", "RG", "RP", "RW", "S", "U", "UB", "UP",
  "UR", "W", "WB", "WP", "WU", "X", "Y", "Z"]);

export type JoinCode = { kind: "code"; code: string } | { kind: "qr"; code: string; secret: string };
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const isCode = (s: string) => /^[A-Za-z0-9]{4}$/.test(s);

/** An event code read out of pasted text: a table-1.site link wins (/j/<code>?s=… the QR's join, /join/<code>), then the
 *  whole text without spaces and dashes, then a word after "code", then a word of capitals and digits with a digit. */
export function parseJoinCode(text: string | null | undefined): JoinCode | null {
  if (text == null) return null;
  const m = text.match(/(?:https?:\/\/)?(?:www\.)?table-1\.site(\/[^\s<>"']*)/i);
  if (m) {
    let u: URL;
    try { u = new URL("https://table-1.site" + m[1]); } catch { return null; }
    const parts = u.pathname.split("/").filter(Boolean);
    if (parts.length >= 2 && parts[0] === "j" && isCode(parts[1])) {
      const s = u.searchParams.get("s");
      if (s) return { kind: "qr", code: parts[1].toUpperCase(), secret: s };
    }
    if (parts.length >= 2 && parts[0] === "join" && isCode(parts[1])) return { kind: "code", code: parts[1].toUpperCase() };
    return null;
  }
  const plain = text.replace(/https?:\/\/\S+/g, " ");   // another site's link says nothing about the code
  const bare = plain.replace(/[\s-]/g, "");
  if (isCode(bare)) return { kind: "code", code: bare.toUpperCase() };
  const c = plain.match(/\bcode\b\W{0,3}(?:is\W{1,3})?([A-Za-z0-9]{4})\b/i);
  if (c) return { kind: "code", code: c[1].toUpperCase() };
  for (const w of plain.split(/[^A-Za-z0-9]+/)) {
    if (w.length === 4 && [...w].every((ch) => ALPHABET.includes(ch)) && /\d/.test(w)) return { kind: "code", code: w };
  }
  return null;
}
