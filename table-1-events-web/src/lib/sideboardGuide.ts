// Sideboard guides (contract/sideboard-guide-2026-11-04.md): per matchup, what comes in (sideboard or Considering),
// what goes out (main deck) and notes; printed for Competitive REL (MTR 2.11). The rules are
// testdata/sideboard-guide/make_cases.py; iOS SideboardGuide.swift and Android SideboardGuide.kt match it.

export type GuideCard = [oracle: string, qty: number];
export interface Matchup { id: string; name: string; archetype?: number | null; in: GuideCard[]; out: GuideCard[]; notes: string }
export interface SideboardGuide { matchups: Matchup[] }
export type Side = "in" | "out";

export const MAX_MATCHUPS = 40;
export const MAX_CARDS = 40;
export const MAX_NAME = 40;
export const MAX_NOTES = 1000;
export const SIDEBOARD_MAX = 15;
const CAPPED = new Set(["modern", "pioneer", "standard", "legacy", "vintage", "pauper", "canlander"]);
const NO_GUIDE = new Set(["commander", "oathbreaker"]);

/** A deck line by card: what the rules need. */
export interface GuideLine { oracle: string; name: string; board: string; qty: number }
export interface Copies { name: string; main: number; side: number; maybe: number }
export type Issue =
  | { code: "gone"; side: Side; oracle: string }
  | { code: "in_over"; oracle: string; have: number }
  | { code: "out_over"; oracle: string; have: number }
  | { code: "considering"; oracle: string; qty: number }
  | { code: "below_min"; deck: number; min: number };
export interface Check { in: number; out: number; deck: number; label: string; issues: Issue[] }

export const hasGuide = (format: string) => !NO_GUIDE.has(format);
export const deckMin = (format: string): number | null => (format === "canlander" ? 100 : CAPPED.has(format) ? 60 : null);

/** A guide from the wire (null when there's none); tolerant of missing sides and notes. */
export function guideFromWire(w: unknown): SideboardGuide | null {
  const ms = (w as { matchups?: unknown[] } | null)?.matchups;
  if (!Array.isArray(ms) || !ms.length) return null;
  return {
    matchups: ms.map((m) => {
      const x = m as Partial<Matchup>;
      return { id: String(x.id), name: String(x.name ?? ""), archetype: x.archetype ?? null, in: x.in ?? [], out: x.out ?? [], notes: x.notes ?? "" };
    }),
  };
}

/** Copies per card in the main deck, sideboard and Considering (the command zone isn't the deck here). */
export function pool(lines: GuideLine[]): Map<string, Copies> {
  const out = new Map<string, Copies>();
  for (const l of lines) {
    const c = out.get(l.oracle) ?? { name: l.name, main: 0, side: 0, maybe: 0 };
    if (l.board === "main") c.main += l.qty;
    else if (l.board === "side") c.side += l.qty;
    else if (l.board === "maybe") c.maybe += l.qty;
    out.set(l.oracle, c);
  }
  return out;
}

export const label = (nIn: number, nOut: number) => (nIn === 0 && nOut === 0 ? "NO CHANGES" : `IN ${nIn} · OUT ${nOut}`);
const sum = (cards: GuideCard[]) => cards.reduce((n, [, q]) => n + q, 0);

export function check(m: Pick<Matchup, "in" | "out">, lines: GuideLine[], format: string): Check {
  const p = pool(lines);
  const mainTotal = lines.filter((l) => l.board === "main").reduce((n, l) => n + l.qty, 0);
  const issues: Issue[] = [];
  let tookIn = 0;
  for (const [oracle, asked] of m.in) {
    const c = p.get(oracle) ?? { name: "", main: 0, side: 0, maybe: 0 };
    const avail = c.side + c.maybe;
    if (avail === 0) { issues.push({ code: "gone", side: "in", oracle }); continue; }
    if (asked > avail) issues.push({ code: "in_over", oracle, have: avail });
    const took = Math.min(asked, avail);
    tookIn += took;
    if (took - c.side > 0) issues.push({ code: "considering", oracle, qty: took - c.side });
  }
  let tookOut = 0;
  for (const [oracle, asked] of m.out) {
    const have = p.get(oracle)?.main ?? 0;
    if (have === 0) { issues.push({ code: "gone", side: "out", oracle }); continue; }
    if (asked > have) issues.push({ code: "out_over", oracle, have });
    tookOut += Math.min(asked, have);
  }
  const deck = mainTotal + tookIn - tookOut;
  const min = deckMin(format);
  if (min != null && deck < min) issues.push({ code: "below_min", deck, min });
  return { in: sum(m.in), out: sum(m.out), deck, label: label(sum(m.in), sum(m.out)), issues };
}

export const sideboardCount = (lines: GuideLine[]) => lines.filter((l) => l.board === "side").reduce((n, l) => n + l.qty, 0);

/** The sideboard's size when it's over 15 in a capped format (CR 100.4a), else null. */
export function overSideboard(lines: GuideLine[], format: string): number | null {
  const n = sideboardCount(lines);
  return CAPPED.has(format) && n > SIDEBOARD_MAX ? n : null;
}

/** How many matchups bring each card in. */
export function uses(g: SideboardGuide): Record<string, number> {
  const out: Record<string, number> = {};
  for (const m of g.matchups) for (const [o, q] of m.in) if (q > 0) out[o] = (out[o] ?? 0) + 1;
  return out;
}

export function qtyOf(m: Matchup, oracle: string, side: Side): number {
  return m[side].find(([o]) => o === oracle)?.[1] ?? 0;
}

/** A card's count on one side (0 takes it off), keeping the order cards were added. */
export function setQty(m: Matchup, oracle: string, qty: number, side: Side): Matchup {
  const cards = m[side].slice();
  const i = cards.findIndex(([o]) => o === oracle);
  if (i >= 0) {
    if (qty <= 0) cards.splice(i, 1);
    else cards[i] = [oracle, Math.min(99, qty)];
  } else if (qty > 0) cards.push([oracle, Math.min(99, qty)]);
  return { ...m, [side]: cards };
}

/** A matchup name as the server keeps it: trimmed, at most 40 characters. */
export const matchupName = (raw: string) => raw.trim().slice(0, MAX_NAME);

/** One issue as a sentence for the matchup screen. */
export function issueText(i: Issue, names: Map<string, Copies>): string {
  const name = (o: string) => names.get(o)?.name ?? "A card";
  switch (i.code) {
    case "gone": return i.side === "in" ? `${name(i.oracle)} isn't in the sideboard or Considering anymore.` : `${name(i.oracle)} isn't in the main deck anymore.`;
    case "in_over": return `Only ${i.have} ${name(i.oracle)} to bring in.`;
    case "out_over": return `Only ${i.have} ${name(i.oracle)} in the main deck.`;
    case "considering": return `${i.qty} ${name(i.oracle)} from Considering: not printed until it's in the sideboard.`;
    case "below_min": return `The deck goes to ${i.deck} cards, under ${i.min}.`;
  }
}

/* ── printing ─────────────────────────────────────────────────────────── */

export type PrintCard = [qty: number, name: string];
export interface PrintMatchup { name: string; in: PrintCard[]; out: PrintCard[]; notes: string }
export interface PrintModel { deck: string; format: string; date: string; sideboard: PrintCard[]; matchups: PrintMatchup[] }
export type Warning = { code: "considering" | "gone" | "sheets"; qty: number } | { code: "sideboard_over"; qty: number; max: number };

/** What the printed guide shows: only sideboard copies come in, outs capped at the main deck's copies, cards no
 *  longer in the deck left out. */
export function printModel(deck: string, formatName: string, date: string, lines: GuideLine[], guide: SideboardGuide,
                           format: string): { model: PrintModel; warnings: Warning[]; sheets: number } {
  const p = pool(lines);
  let leftConsidering = 0, leftGone = 0;
  const matchups: PrintMatchup[] = guide.matchups.map((m) => {
    const ins: PrintCard[] = [];
    for (const [o, asked] of m.in) {
      const c = p.get(o);
      if (!c || c.side + c.maybe === 0) { leftGone += asked; continue; }
      const took = Math.min(asked, c.side);
      leftConsidering += Math.min(asked, c.side + c.maybe) - took;
      if (took > 0) ins.push([took, c.name]);
    }
    const outs: PrintCard[] = [];
    for (const [o, asked] of m.out) {
      const c = p.get(o);
      if (!c || c.main === 0) { leftGone += asked; continue; }
      outs.push([Math.min(asked, c.main), c.name]);
    }
    return { name: m.name, in: ins, out: outs, notes: m.notes };
  });
  const lower = (s: string) => s.toLowerCase();
  const sideboard = [...p.values()].filter((c) => c.side > 0).map((c): PrintCard => [c.side, c.name])
    .sort((a, b) => (lower(a[1]) < lower(b[1]) ? -1 : lower(a[1]) > lower(b[1]) ? 1 : 0));
  const model: PrintModel = { deck, format: formatName, date, sideboard, matchups };
  const warnings: Warning[] = [];
  if (leftConsidering) warnings.push({ code: "considering", qty: leftConsidering });
  if (leftGone) warnings.push({ code: "gone", qty: leftGone });
  const over = overSideboard(lines, format);
  if (over != null) warnings.push({ code: "sideboard_over", qty: over, max: SIDEBOARD_MAX });
  const s = sheets(model);
  if (s > 2) warnings.push({ code: "sheets", qty: s });
  return { model, warnings, sheets: s };
}

const LINES_PER_PAGE = 120, HEADER_LINES = 10, NOTE_CHARS_PER_LINE = 40;

/** About how many pages the printed guide takes (MTR 2.11 allows a sheet or two). */
export function sheets(m: PrintModel): number {
  let total = HEADER_LINES;
  for (const x of m.matchups) {
    const notes = x.notes ? 1 + x.notes.split("\n").reduce((n, part) => n + Math.max(1, Math.ceil([...part].length / NOTE_CHARS_PER_LINE)), 0) : 0;
    total += 4 + Math.max(x.in.length, x.out.length, 1) + notes;
  }
  total += 4 + Math.max(m.sideboard.length, 1);
  return Math.max(1, Math.ceil(total / LINES_PER_PAGE));
}

export function warningText(w: Warning): string {
  switch (w.code) {
    case "considering": return `${w.qty} ${w.qty === 1 ? "card" : "cards"} from Considering left out: only the sideboard can come in.`;
    case "gone": return `${w.qty} ${w.qty === 1 ? "card" : "cards"} no longer in the deck left out.`;
    case "sideboard_over": return `The sideboard has ${w.qty} cards: Constructed allows 15.`;
    case "sheets": return `About ${w.qty} pages: the rules allow a sheet or two.`;
  }
}

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");

const CSS = "@page{margin:12mm}"
  + "*{box-sizing:border-box;margin:0;padding:0}"
  + "html{-webkit-print-color-adjust:exact;print-color-adjust:exact}"
  + "body{font-family:ui-monospace,\"SF Mono\",\"JetBrains Mono\",Menlo,Consolas,monospace;color:#171725;"
  + "background:#fff;font-size:9pt;line-height:1.35}"
  + "header{border-bottom:2px solid #00ffd9;padding-bottom:6pt;margin-bottom:8pt}"
  + ".mark,.meta,.rule,.lab,h2{text-transform:uppercase;letter-spacing:.15em}"
  + ".mark{font-size:7pt;color:#545461}"
  + "h1{font-size:16pt;font-weight:600;margin:2pt 0}"
  + ".meta{font-size:7.5pt;color:#545461}"
  + ".rule{font-size:6.5pt;color:#545461;margin-top:2pt}"
  + "main{columns:2;column-gap:8pt}"
  + "section{break-inside:avoid;border:1px solid #c4c4ca;margin-bottom:8pt;padding:6pt}"
  + "h2{font-size:8pt;font-weight:600;padding-bottom:4pt;border-bottom:1px solid #c4c4ca;margin-bottom:4pt}"
  + ".io{display:flex;gap:6pt}"
  + ".col{flex:1;min-width:0}"
  + ".lab{font-size:6.5pt;color:#545461;margin-bottom:2pt}"
  + ".row{display:flex;gap:4pt}"
  + ".q{width:2.4em;flex:none;font-weight:600}"
  + ".none{color:#545461}"
  + ".notes{margin-top:4pt;padding-top:4pt;border-top:1px solid #c4c4ca;font-size:8pt;white-space:pre-wrap}";

const RULE = "MTR 2.11 · Between games only · Remove from the play area before each game";

const rows = (cards: PrintCard[], sign: string) =>
  cards.length ? cards.map(([q, n]) => `<div class="row"><span class="q">${sign}${q}</span><span>${esc(n)}</span></div>`).join("")
    : '<div class="none">—</div>';

/** The printed page (light paper in Table 1's type and grid); must equal testdata/sideboard-guide/guide.html. */
export function guideHtml(m: PrintModel): string {
  let out = '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
    + `<title>${esc(m.deck)} · Sideboard guide</title>\n`
    + `<style>${CSS}</style>\n</head>\n<body>\n<header>\n`
    + '<div class="mark">Table 1</div>\n'
    + `<h1>${esc(m.deck)}</h1>\n`
    + `<div class="meta">${esc(m.format)} · Sideboard guide · ${esc(m.date)}</div>\n`
    + `<div class="rule">${RULE}</div>\n</header>\n<main>\n`;
  for (const x of m.matchups) {
    out += `<section>\n<h2>${esc(x.name)}</h2>\n<div class="io">\n`
      + `<div class="col"><div class="lab">In · ${x.in.reduce((n, [q]) => n + q, 0)}</div>${rows(x.in, "+")}</div>\n`
      + `<div class="col"><div class="lab">Out · ${x.out.reduce((n, [q]) => n + q, 0)}</div>${rows(x.out, "−")}</div>\n</div>\n`;
    if (x.notes) out += `<p class="notes">${esc(x.notes)}</p>\n`;
    out += "</section>\n";
  }
  out += `<section>\n<h2>Sideboard · ${m.sideboard.reduce((n, [q]) => n + q, 0)}</h2>\n${rows(m.sideboard, "")}\n</section>\n`;
  return out + "</main>\n</body>\n</html>\n";
}

/** Today in the viewer's own time zone, as the page prints it. */
export function printDate(d = new Date()): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}
