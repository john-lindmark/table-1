// Insights charts as pictures, for the Discord bot's /meta commands (contract/discord-2026-10-29.md § Insights images):
// the matchup grid, one archetype's matchups, and the win-rate chart (Frank Karsten's left panel). Drawn as SVG from a
// constructed pack (contract/insights-2026-10-24.md § Constructed pack) in the apps' dark look; index.ts rasterizes it.
// Pure: tests read the markup.

export const C = {
  bg: "#171725", surface: "#282839", hover: "#33334a", text: "#ffffff", muted: "#c4c4ca", accent: "#00ffd9", error: "#f2a3e5",
  ink: "#171725",
};
export const FONT = "JetBrains Mono";
export const WIDTH = 1600;
const PAD = 48;
const EM = 0.6; // a mono font's width per character, in ems

// ---------------------------------------------------------------- the pack, as far as the pictures read it

export type Tier = "big" | "all";
export type Cell = [number, number, number, number, number];
export interface Matchups { archetypes: number[]; rows?: number[]; cells: Cell[] }
export interface ShareRow { a: number; share: number; decks: number; wr?: number | null; rec?: [number, number, number] | null }
export interface Window { decks: number; events: number; share: ShareRow[]; matchups?: Matchups }
export interface Pack {
  format: string; name: string; built_at: string; sources: string[];
  archetypes: { id: number; name: string }[];
  tiers: Record<Tier, { windows: Record<string, Window> }>;
  matchups: Matchups;
}

export interface Picture { svg: string; width: number; height: number }

// ---------------------------------------------------------------- maths shared with the apps

/** A matchup cell's tone (testdata/insight-charts make_cases.py `heat`; the apps' Heatmap). */
export function heat(wins: number, losses: number, minimum = 30) {
  const n = wins + losses;
  if (n === 0) return { label: "", tone: "none", strength: 0, dim: false, ink: false };
  const wr = wins / n, d = wr - 0.5;
  const tone = Math.abs(d) < 0.03 ? "even" : d > 0 ? "up" : "down";
  const dim = n < minimum;
  const strength = (tone === "even" ? 0 : Math.min(1, 0.25 + Math.abs(d) * 4)) * (dim ? 0.5 : 1);
  return { label: String(Math.floor(wr * 100 + 0.5)), tone, strength: Math.round(strength * 10000) / 10000, dim, ink: Math.abs(d) >= 0.08 && !dim };
}

/** Wilson interval for a rate; 95% by default, as on the win-rate chart. */
export function wilson(wins: number, n: number, z = 1.96): [number, number] {
  if (n <= 0) return [0, 1];
  const p = wins / n, d = 1 + (z * z) / n;
  const c = (p + (z * z) / (2 * n)) / d;
  const h = (z * Math.sqrt((p * (1 - p)) / n + (z * z) / (4 * n * n))) / d;
  return [Math.max(0, c - h), Math.min(1, c + h)];
}

/** A matchup read from the row archetype's side. */
export function cellOf(m: Matchups, a: number, b: number): { wins: number; losses: number; draws: number } | null {
  const ab = m.cells.find((c) => c[0] === a && c[1] === b);
  if (ab) return { wins: ab[2], losses: ab[3], draws: ab[4] };
  const ba = m.cells.find((c) => c[0] === b && c[1] === a);
  return ba ? { wins: ba[3], losses: ba[2], draws: ba[4] } : null;
}

/** The window's own grid, or the pack's 90-day All events grid in an older pack (the apps' gridFor). */
export function gridFor(p: Pack, tier: Tier, days: number): { m: Matchups; tier: Tier; days: number } {
  const m = p.tiers[tier]?.windows[String(days)]?.matchups;
  return m ? { m, tier, days } : { m: p.matchups, tier: "all", days: 90 };
}

export const rowsOf = (m: Matchups) => (m.rows?.length ? m.rows : m.archetypes);
export const nameOf = (p: Pack, id: number) => p.archetypes.find((a) => a.id === id)?.name ?? "Other";
export const scope = (tier: Tier, days: number) => `${tier === "big" ? "Big events" : "All events"} · last ${days} days`;
const SOURCES: Record<string, string> = { mtgo: "Magic Online", topdeck: "TopDeck.gg", melee: "Melee" };
export function credit(sources: string[]): string {
  const names = (sources.length ? sources : ["mtgo"]).map((s) => SOURCES[s] ?? s);
  return `Results from ${names.length < 2 ? names.join("") : `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`}`;
}
export const pct1 = (x: number) => `${(x * 100).toFixed(1)}%`;
export const pct0 = (x: number) => `${Math.floor(x * 100 + 0.5)}%`;

// ---------------------------------------------------------------- drawing helpers

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/** Cuts a line to a width at a font size, with an ellipsis. */
export function clip(s: string, size: number, maxWidth: number): string {
  const max = Math.max(1, Math.floor(maxWidth / (size * EM)));
  return s.length <= max ? s : s.slice(0, Math.max(1, max - 1)) + "…";
}

interface TextOpts { weight?: number; tracking?: number; anchor?: "start" | "middle" | "end"; max?: number; opacity?: number }
/** y is the text's top, as on the apps' canvases. */
function text(s: string, x: number, y: number, size: number, color: string, o: TextOpts = {}): string {
  const line = o.max ? clip(s, size, o.max) : s;
  return `<text x="${x.toFixed(1)}" y="${(y + size * 0.78).toFixed(1)}" font-family="${FONT}" font-weight="${o.weight ?? 400}" font-size="${size}" fill="${color}"` +
    `${o.tracking ? ` letter-spacing="${o.tracking}"` : ""}${o.anchor ? ` text-anchor="${o.anchor}"` : ""}${o.opacity != null ? ` fill-opacity="${o.opacity}"` : ""}>${esc(line)}</text>`;
}
const rect = (x: number, y: number, w: number, h: number, fill: string, extra = "") =>
  `<rect x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${Math.max(0, w).toFixed(1)}" height="${h.toFixed(1)}" fill="${fill}"${extra}/>`;

/** color-mix(in srgb, a p, b): the apps' heat fill. */
export function mix(a: string, b: string, p: number): string {
  const n = (h: string) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
  const [x, y] = [n(a), n(b)];
  return "#" + x.map((v, i) => Math.round(v * p + y[i] * (1 - p)).toString(16).padStart(2, "0")).join("");
}

/** The Table 1 mark: eleven tiles on a 6 × 3 grid, right-aligned at `right`, `h` tall. */
const TILES: [number, number][] = [[0, 0], [1, 0], [2, 0], [3, 0], [4, 0], [1, 1], [4, 1], [1, 2], [3, 2], [4, 2], [5, 2]];
function logo(right: number, top: number, h: number): string {
  const w = (h * 393) / 192.69, sx = w / 393, sy = h / 192.69, x0 = right - w;
  return TILES.map(([c, r]) => rect(x0 + c * 65.8036 * sx, top + r * 64.8302 * sy, 63.982 * sx, 63.0294 * sy, C.text)).join("");
}

/** Title in tracked capitals, a muted line under it, the mark on the right; returns the markup and the height used. */
function header(title: string, sub: string): { svg: string; h: number } {
  return {
    svg: text(title.toUpperCase(), PAD, PAD, 34, C.text, { weight: 600, tracking: 2, max: WIDTH - 2 * PAD - 160 }) +
      text(sub, PAD, PAD + 52, 20, C.muted, { max: WIDTH - 2 * PAD - 160 }) + logo(WIDTH - PAD, PAD + 4, 56),
    h: PAD + 100,
  };
}

function footer(lines: string[], top: number): { svg: string; h: number } {
  return { svg: lines.map((l, i) => text(l, PAD, top + 24 + i * 26, 16, C.muted, { max: WIDTH - 2 * PAD })).join(""), h: 24 + lines.length * 26 + PAD };
}

function wrap(body: string, height: number): Picture {
  const h = Math.ceil(height);
  return {
    svg: `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${h}" viewBox="0 0 ${WIDTH} ${h}">${rect(0, 0, WIDTH, h, C.bg)}${body}</svg>`,
    width: WIDTH, height: h,
  };
}

function empty(title: string, sub: string, note: string, sources: string[]): Picture {
  const hd = header(title, sub);
  const ft = footer([credit(sources) + " · table-1.site"], hd.h + 120);
  return wrap(hd.svg + rect(PAD, hd.h, WIDTH - 2 * PAD, 96, C.surface) + text(note, PAD + 24, hd.h + 36, 22, C.muted, { max: WIDTH - 2 * PAD - 48 }) + ft.svg, hd.h + 120 + ft.h);
}

// ---------------------------------------------------------------- the matchup grid

/** Every archetype (rows) against the most played (columns): the row's match win rate, its record under it. */
export function matchupsPicture(p: Pack, tier: Tier, days: number): Picture {
  const g = gridFor(p, tier, days);
  const rows = rowsOf(g.m), cols = g.m.archetypes;
  if (!g.m.cells.length || !rows.length) return empty(`${p.name} matchups`, scope(g.tier, g.days), "No matches between known decks in this window yet.", p.sources);
  const matches = g.m.cells.reduce((s, c) => s + c[2] + c[3] + c[4], 0);
  const hd = header(`${p.name} matchups`, `${scope(g.tier, g.days)} · ${matches.toLocaleString("en-US")} matches`);
  const labelW = 320, gap = 2, headH = 230, rowH = 58;
  const cellW = (WIDTH - 2 * PAD - labelW - gap * cols.length) / cols.length;
  let out = hd.svg;
  const top = hd.h;
  // column names, read upwards from the bottom of the header
  cols.forEach((b, c) => {
    const x = PAD + labelW + gap + c * (cellW + gap);
    out += rect(x, top, cellW, headH, C.surface);
    out += `<g transform="translate(${(x + cellW / 2 + 7).toFixed(1)} ${(top + headH - 14).toFixed(1)}) rotate(-90)">` +
      text(nameOf(p, b).toUpperCase(), 0, -9, 15, C.text, { tracking: 1, max: headH - 28 }) + `</g>`;
  });
  out += rect(PAD, top, labelW, headH, C.surface);
  rows.forEach((a, r) => {
    const y = top + headH + gap + r * (rowH + gap);
    out += rect(PAD, y, labelW, rowH, C.surface) + text(nameOf(p, a), PAD + 16, y + rowH / 2 - 11, 19, C.text, { max: labelW - 32 });
    cols.forEach((b, c) => {
      const x = PAD + labelW + gap + c * (cellW + gap);
      if (a === b) { out += rect(x, y, cellW, rowH, C.bg); return; }
      const v = cellOf(g.m, a, b);
      const h = heat(v?.wins ?? 0, v?.losses ?? 0);
      const fill = h.tone === "none" ? C.surface : h.tone === "even" ? C.hover : mix(h.tone === "up" ? C.accent : C.error, C.surface, h.strength);
      out += rect(x, y, cellW, rowH, fill);
      if (v && h.label) {
        const ink = h.ink ? C.ink : h.dim ? C.muted : C.text;
        out += text(`${h.label}%`, x + cellW / 2, y + 8, 21, ink, { weight: 600, anchor: "middle" });
        out += text(`${v.wins}-${v.losses}${v.draws ? `-${v.draws}` : ""}`, x + cellW / 2, y + 35, 14, ink, { anchor: "middle", opacity: 0.85, max: cellW - 8 });
      }
    });
  });
  const bottom = top + headH + gap + rows.length * (rowH + gap);
  const ft = footer([
    "Row's match win rate against each column; draws left out, mirrors blank. Faded: under 30 matches, a hint more than a verdict.",
    `${credit(p.sources)}. Rows: every archetype with 1% of decks and 20 matches, then Other. table-1.site`,
  ], bottom);
  return wrap(out + ft.svg, bottom + ft.h);
}

// ---------------------------------------------------------------- bars with a likely range (deck matchups, win rates)

interface Bar { label: string; wins: number; losses: number; draws: number; rate: number; n: number; faded?: boolean; allDraws?: boolean; a?: number }

/** One row per bar: name, record and rate on the bar, a 95% range, the 50% line dotted. */
function bars(list: Bar[], top: number): { svg: string; h: number } {
  const labelW = 360, rowH = 50, gap = 2, x0 = PAD + labelW + 16, w = WIDTH - PAD - x0;
  const axisH = 34;
  let out = "";
  list.forEach((b, i) => {
    const y = top + i * (rowH + gap);
    const [lo, hi] = wilson(b.wins, b.n);
    const tone = lo > 0.5 ? C.accent : hi < 0.5 ? C.error : C.muted;
    const op = b.faded ? 0.45 : 1;
    out += rect(PAD, y, labelW, rowH, C.surface) + text(b.label, PAD + labelW - 16, y + rowH / 2 - 10, 19, C.text, { anchor: "end", max: labelW - 32, opacity: b.faded ? 0.6 : 1 });
    out += rect(x0, y, w, rowH, C.surface);
    out += rect(x0, y + 8, w * b.rate, rowH - 16, mix(tone, C.surface, 0.35 * op));
    // the likely range: a line with end ticks, and a dot at the rate
    const ly = y + rowH / 2, l = x0 + w * lo, h = x0 + w * hi, m = x0 + w * b.rate;
    out += `<g stroke="${C.text}" stroke-opacity="${0.85 * op}" stroke-width="2"><line x1="${l.toFixed(1)}" y1="${ly}" x2="${h.toFixed(1)}" y2="${ly}"/>` +
      `<line x1="${l.toFixed(1)}" y1="${ly - 9}" x2="${l.toFixed(1)}" y2="${ly + 9}"/><line x1="${h.toFixed(1)}" y1="${ly - 9}" x2="${h.toFixed(1)}" y2="${ly + 9}"/></g>` +
      `<circle cx="${m.toFixed(1)}" cy="${ly}" r="5" fill="${C.text}" fill-opacity="${op}"/>`;
    // the record on a dark backing, over the range line
    const label = `${b.wins}-${b.losses}${b.draws || b.allDraws ? `-${b.draws}` : ""} (${pct1(b.rate)})`;
    out += rect(x0 + 4, y + 11, label.length * 18 * EM + 16, rowH - 22, C.bg, ` fill-opacity="0.72"`);
    out += text(label, x0 + 12, y + rowH / 2 - 10, 18, b.faded ? C.muted : C.text, { weight: 500 });
  });
  const bottom = top + list.length * (rowH + gap);
  // the 50% line over every row, dotted, and the axis under them
  const mid = x0 + w / 2;
  out += `<line x1="${mid}" y1="${top - 6}" x2="${mid}" y2="${bottom}" stroke="${C.text}" stroke-opacity="0.7" stroke-width="2" stroke-dasharray="3 6"/>`;
  for (const t of [0, 0.2, 0.4, 0.6, 0.8, 1]) {
    const x = x0 + w * t;
    out += text(pct0(t), x, bottom + 8, 15, C.muted, { anchor: t === 0 ? "start" : t === 1 ? "end" : "middle" });
  }
  return { svg: out, h: bottom + axisH - top };
}

/** Every archetype's match win rate against the others, best first, Other last (Frank Karsten's left panel). */
export function winratesPicture(p: Pack, tier: Tier, days: number, minimum = 20): Picture {
  const w = p.tiers[tier]?.windows[String(days)];
  const rated = (w?.share ?? []).filter((s) => s.rec && s.rec[0] + s.rec[1] + s.rec[2] >= minimum);
  if (!rated.length) {
    const why = w?.share?.some((s) => s.wr != null) ? "This pack predates win-rate records: they arrive with the next rebuild." : "Too few matches between known decks in this window yet.";
    return empty(`${p.name} win rates`, scope(tier, days), why, p.sources);
  }
  const list: Bar[] = rated.map((s) => {
    const [wins, losses, draws] = s.rec!;
    const n = wins + losses + draws;
    return { label: nameOf(p, s.a), wins, losses, draws, n, rate: wins / n, a: s.a, allDraws: true };
  });
  list.sort((x, y) => Number(x.a === 0) - Number(y.a === 0) || y.rate - x.rate || y.n - x.n);
  const hd = header(`${p.name} win rates`, `${scope(tier, days)} · ${w!.decks.toLocaleString("en-US")} decks · ${w!.events} events`);
  const b = bars(list, hd.h + 8);
  const ft = footer([
    "Match win rate against other archetypes (mirrors left out; draws count as not won), from 20 matches. Bars: 95% likely range.",
    `${credit(p.sources)}. Matches come from Magic Online top 8 brackets and every round of paper events. table-1.site`,
  ], hd.h + 8 + b.h);
  return wrap(hd.svg + b.svg + ft.svg, hd.h + 8 + b.h + ft.h);
}

/** One archetype against each other archetype in the grid, best first; faded under 30 matches. */
export function deckPicture(p: Pack, tier: Tier, days: number, a: number): Picture {
  const g = gridFor(p, tier, days);
  const name = nameOf(p, a);
  const sub = `Matchups · ${scope(g.tier, g.days)}`;
  const others = rowsOf(g.m).filter((b) => b !== a);
  const list: Bar[] = [];
  for (const b of others) {
    const v = cellOf(g.m, a, b);
    if (!v || v.wins + v.losses < 5) continue;   // a pairing of a few matches says nothing, even faded
    const n = v.wins + v.losses;
    list.push({ label: nameOf(p, b), wins: v.wins, losses: v.losses, draws: v.draws, n, rate: v.wins / n, faded: n < 30 });
  }
  if (!rowsOf(g.m).includes(a) || !list.length) {
    return empty(`${name}`, `${p.name} · ${sub}`, `Too few matches for ${name} in this window: try All events or a longer window.`, p.sources);
  }
  // the matchups with 30+ matches first, best to worst; the faded ones after them
  list.sort((x, y) => Number(Boolean(x.faded)) - Number(Boolean(y.faded)) || y.rate - x.rate || y.n - x.n);
  const own = p.tiers[g.tier]?.windows[String(g.days)]?.share.find((s) => s.a === a);
  const overall = own?.rec ? (() => {
    const [w, l, d] = own.rec!;
    return ` · overall ${w}-${l}-${d} (${pct1(w / (w + l + d))})`;
  })() : "";
  const hd = header(`${name} · ${p.name}`, `${sub}${overall}`);
  const b = bars(list, hd.h + 8);
  const ft = footer([
    "Match win rate against each archetype; draws left out. Bars: 95% likely range. Faded, and listed last: under 30 matches.",
    `${credit(p.sources)}. table-1.site`,
  ], hd.h + 8 + b.h);
  return wrap(hd.svg + b.svg + ft.svg, hd.h + 8 + b.h + ft.h);
}
