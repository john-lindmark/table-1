// 17Lands public data rows → sums (contract/insights-2026-10-24.md § Limited pack). Bytes in, no strings per
// field: the game files have ~1,500 columns per row, almost all single digits, so each slice is scanned once.
// Keys (g = games, w = wins unless noted; grp a = all players, t = top players):
//   T|grp  P|grp (on the play)  D|grp (on the draw)  M|grp (mulliganed)  MP|grp (mulliganed on the play)
//   K|grp (kept 7)  N|grp (g games, w = sum of turns)
//   p|pair|grp  pp|pair|grp (on the play)  ps|pair|grp (splashed)  pw|pair|week|grp
//   dc|main|splash|grp  each deck's exact colours as 17Lands writes them (main WUBRG order, splash '' when none)
//   cd|card|grp (in deck)  ch|card|grp (in hand: opening hand or drawn)  co|card|grp (opening hand)
//   cg|card|grp (drawn, not in the opening hand)  cn|card|grp (in deck, never seen)
//   cw|card|week (in hand, all players)  cp|card|pair (in hand, all players, two-colour pairs)
//   a|card|grp     draft data: g = times taken, w = sum of the pick position (1-14)

export type Acc = Map<string, [number, number]>;

/** Column names from a header line (CSV with quoted names that hold commas). */
export function headerColumns(line: string): string[] {
  const out: string[] = [];
  let cur = "", q = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (q) {
      if (ch === '"' && line[i + 1] === '"') { cur += '"'; i++; }
      else if (ch === '"') q = false;
      else cur += ch;
    } else if (ch === '"') q = true;
    else if (ch === ",") { out.push(cur); cur = ""; }
    else cur += ch;
  }
  out.push(cur.replace(/\r$/, ""));
  return out;
}

const TOP_WR = 0.6, TOP_GAMES = 50;
/** Draft rows are read for these only; the ~600 pack and pool columns are skipped without decoding. */
const DRAFT_FIELDS = ["pick", "pick_number", "user_n_games_bucket", "user_game_win_rate_bucket"];
const SKIP = -2;
const PREFIXES = ["opening_hand_", "drawn_", "tutored_", "deck_", "sideboard_"] as const;

export interface Layout {
  kind: "game" | "draft";
  cols: string[];
}

/** A two-colour pair, a mono colour, or 3C for three or more (17Lands writes colours in WUBRG order). */
export const pairOf = (c: string) => c.length >= 3 ? "3C" : c || "C";

export const PAIRS = ["WU", "WB", "WR", "WG", "UB", "UR", "UG", "BR", "BG", "RG"];
const MAX_WEEKS = 26;
// per card, per group: in deck, in hand, opening hand, drawn, never seen; each as games then wins
const CD = 0, CH = 1, CO = 2, CG = 3, CN = 4, METRICS = ["cd", "ch", "co", "cg", "cn"];

export class Rows {
  rows = 0;
  private small: Acc = new Map();
  private base = new Map<string, number>();
  private cardOf: Int32Array;           // column → card index, or -1
  private partOf: Int8Array;            // column → 0 oh, 1 drawn, 2 tutored, 3 deck, 4 side; -1 base
  private cards: string[] = [];
  private vals: Uint16Array[];          // per part, per card
  private stats: Float64Array;          // [card][grp][metric][g, w]
  private weeks: Float64Array;          // [card][week][g, w], all players
  private pairs: Float64Array;          // [card][pair][g, w], all players
  private fields: string[];             // base fields of the current row
  private dec = new TextDecoder();

  constructor(private layout: Layout, private releasedMs: number | null) {
    const n = layout.cols.length;
    this.cardOf = new Int32Array(n).fill(-1);
    this.partOf = new Int8Array(n).fill(-1);
    const index = new Map<string, number>();
    layout.cols.forEach((c, i) => {
      if (layout.kind === "draft") {
        if (DRAFT_FIELDS.includes(c)) this.base.set(c, i); else this.partOf[i] = SKIP;
        return;
      }
      const p = PREFIXES.findIndex((x) => c.startsWith(x));
      if (p < 0) { this.base.set(c, i); return; }
      const name = c.slice(PREFIXES[p].length);
      let k = index.get(name);
      if (k == null) { k = this.cards.length; index.set(name, k); this.cards.push(name); }
      this.cardOf[i] = k;
      this.partOf[i] = p;
    });
    const nc = this.cards.length;
    this.vals = PREFIXES.map(() => new Uint16Array(nc));
    this.stats = new Float64Array(nc * 2 * METRICS.length * 2);
    this.weeks = new Float64Array(nc * MAX_WEEKS * 2);
    this.pairs = new Float64Array(nc * PAIRS.length * 2);
    this.fields = new Array(n);
  }

  private add(k: string, won: boolean, w = won ? 1 : 0) {
    const v = this.small.get(k);
    if (v) { v[0]++; v[1] += w; } else this.small.set(k, [1, w]);
  }

  private field(name: string): string { const i = this.base.get(name); return i == null ? "" : this.fields[i] ?? ""; }

  /** One line of bytes (no newline). */
  line(b: Uint8Array) {
    if (!b.length) return;
    for (const v of this.vals) v.fill(0);
    const n = this.layout.cols.length;
    let col = 0, i = 0;
    while (i <= b.length && col < n) {
      const part = this.partOf[col];
      if (part === SKIP) {
        if (b[i] === 34) { let j = i + 1; for (;;) { const q = b.indexOf(34, j); if (q < 0) { j = b.length; break; } if (b[q + 1] === 34) { j = q + 2; continue; } j = q + 1; break; } i = j; }
        while (i < b.length && b[i] !== 44) i++;
      } else if (part >= 0) {
        // a small integer (or empty)
        let v = 0;
        while (i < b.length && b[i] !== 44) { const d = b[i] - 48; if (d >= 0 && d <= 9) v = v * 10 + d; i++; }
        if (v) this.vals[part][this.cardOf[col]] = v;
      } else {
        let s: string;
        if (b[i] === 34) {               // quoted
          let j = i + 1, out = "";
          for (;;) {
            const q = b.indexOf(34, j);
            if (q < 0) { out += this.dec.decode(b.subarray(j)); j = b.length; break; }
            out += this.dec.decode(b.subarray(j, q));
            if (b[q + 1] === 34) { out += '"'; j = q + 2; continue; }
            j = q + 1; break;
          }
          s = out; i = j;
          while (i < b.length && b[i] !== 44) i++;
        } else {
          const start = i;
          while (i < b.length && b[i] !== 44) i++;
          s = this.dec.decode(b.subarray(start, i));
        }
        this.fields[col] = s;
      }
      i++; col++;
    }
    if (col < n) return;                 // a short or broken line
    this.rows++;
    if (this.layout.kind === "draft") this.draftRow(); else this.gameRow();
  }

  private top(): boolean {
    return Number(this.field("user_game_win_rate_bucket")) >= TOP_WR && Number(this.field("user_n_games_bucket")) >= TOP_GAMES;
  }

  private draftRow() {
    const pick = this.field("pick");
    if (!pick) return;
    const pos = Number(this.field("pick_number")) + 1;
    for (const g of this.top() ? ["a", "t"] : ["a"]) this.add(`a|${pick}|${g}`, false, pos);
  }

  private gameRow() {
    const won = this.field("won") === "True";
    const w = won ? 1 : 0;
    const onPlay = this.field("on_play") === "True";
    const mull = Number(this.field("num_mulligans")) > 0;
    const turns = Number(this.field("num_turns")) || 0;
    const main = this.field("main_colors");
    const splashColors = this.field("splash_colors");
    const pair = pairOf(main);
    const pairIx = PAIRS.indexOf(pair);
    const splash = splashColors !== "";
    const t = Date.parse(this.field("game_time").replace(" ", "T") + "Z");
    const week = Math.min(MAX_WEEKS, this.releasedMs != null && Number.isFinite(t)
      ? Math.max(1, Math.floor((t - this.releasedMs) / (7 * 86400000)) + 1) : 1);
    const [oh, drawn, tut, deck] = this.vals;
    const groups = this.top() ? [0, 1] : [0];
    for (const gi of groups) {
      const g = gi ? "t" : "a";
      this.add(`T|${g}`, won);
      this.add(`${onPlay ? "P" : "D"}|${g}`, won);
      if (mull) { this.add(`M|${g}`, won); if (onPlay) this.add(`MP|${g}`, won); } else this.add(`K|${g}`, won);
      this.add(`N|${g}`, false, turns);
      this.add(`p|${pair}|${g}`, won);
      if (onPlay) this.add(`pp|${pair}|${g}`, won);
      if (splash) this.add(`ps|${pair}|${g}`, won);
      this.add(`pw|${pair}|${week}|${g}`, won);
      this.add(`dc|${main || "C"}|${splashColors}|${g}`, won);
    }
    const nm = METRICS.length;
    for (let c = 0; c < this.cards.length; c++) {
      if (!deck[c]) continue;
      const inHand = oh[c] > 0 || drawn[c] > 0;
      for (const gi of groups) {
        const o = ((c * 2 + gi) * nm) * 2;
        this.stats[o + CD * 2]++; this.stats[o + CD * 2 + 1] += w;
        if (inHand) { this.stats[o + CH * 2]++; this.stats[o + CH * 2 + 1] += w; }
        if (oh[c] > 0) { this.stats[o + CO * 2]++; this.stats[o + CO * 2 + 1] += w; }
        else if (drawn[c] > 0) { this.stats[o + CG * 2]++; this.stats[o + CG * 2 + 1] += w; }
        if (!inHand && !tut[c]) { this.stats[o + CN * 2]++; this.stats[o + CN * 2 + 1] += w; }
      }
      if (inHand) {
        const wo = (c * MAX_WEEKS + week - 1) * 2;
        this.weeks[wo]++; this.weeks[wo + 1] += w;
        if (pairIx >= 0) { const po = (c * PAIRS.length + pairIx) * 2; this.pairs[po]++; this.pairs[po + 1] += w; }
      }
    }
  }

  /** Every non-zero sum, by key. */
  get acc(): Acc {
    const out: Acc = new Map(this.small);
    const nm = METRICS.length;
    this.cards.forEach((name, c) => {
      for (let gi = 0; gi < 2; gi++) {
        for (let m = 0; m < nm; m++) {
          const o = ((c * 2 + gi) * nm + m) * 2;
          if (this.stats[o]) out.set(`${METRICS[m]}|${name}|${gi ? "t" : "a"}`, [this.stats[o], this.stats[o + 1]]);
        }
      }
      for (let wk = 0; wk < MAX_WEEKS; wk++) {
        const o = (c * MAX_WEEKS + wk) * 2;
        if (this.weeks[o]) out.set(`cw|${name}|${wk + 1}`, [this.weeks[o], this.weeks[o + 1]]);
      }
      PAIRS.forEach((p, pi) => {
        const o = (c * PAIRS.length + pi) * 2;
        if (this.pairs[o]) out.set(`cp|${name}|${p}`, [this.pairs[o], this.pairs[o + 1]]);
      });
    });
    return out;
  }
}

/** Splits inflated output into lines across calls; the first line of a file is its header. */
export class Lines {
  carry: Uint8Array;
  constructor(carry: Uint8Array, private onLine: (b: Uint8Array) => void) { this.carry = carry; }
  push(out: Uint8Array) {
    let p = 0;
    for (let i = out.indexOf(10); i >= 0; i = out.indexOf(10, p)) {
      if (this.carry.length) {
        const j = new Uint8Array(this.carry.length + i - p);
        j.set(this.carry); j.set(out.subarray(p, i), this.carry.length);
        this.carry = new Uint8Array(0);
        this.onLine(j);
      } else this.onLine(out.subarray(p, i));
      p = i + 1;
    }
    if (p < out.length) {
      const j = new Uint8Array(this.carry.length + out.length - p);
      j.set(this.carry); j.set(out.subarray(p), this.carry.length);
      this.carry = j;
    }
  }
  end() { if (this.carry.length) { const c = this.carry; this.carry = new Uint8Array(0); this.onLine(c); } }
}

export const accJson = (acc: Acc) => Object.fromEntries([...acc].map(([k, v]) => [k, v]));
