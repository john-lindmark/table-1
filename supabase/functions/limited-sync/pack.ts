// The Limited pack's shape (limited_pack_facts) and the facts sheet its briefs are drawn from. Pure.
import type { Facts } from "../insight-brief/brief.ts";

export interface LCard {
  c: string | null; n: string; r: string | null; col: string | null;
  gih: number | null; gih_n: number; oh: number | null; gd: number | null; gns: number | null; iwd: number | null;
  ata: number | null; deck: number; week_gih: (number | null)[] | null; pair_gih: Record<string, number> | null;
}
export interface LPair {
  p: string; games: number; wr: number; share: number; splash: number; play_wr: number | null; draw_wr: number | null;
  week_wr: (number | null)[]; week_share: (number | null)[];
}
/** One exact colour combination: main colours as 17Lands writes them (WUBRG order) and the splash ('' for none). */
export interface LColors { m: string; s: string; games: number; wr: number; share: number }
export interface LView {
  games: number; wr: number; weeks: number; brief?: string | null;
  pairs: LPair[]; cards: LCard[]; colors: LColors[];
  facts: { play_wr: number | null; draw_wr: number | null; mull_rate: number | null; mull_wr: number | null; keep7_wr: number | null; mull_play: number | null; turns: number | null };
}
export interface LimitedPack {
  v: 1; kind: "limited"; set_code: string; name: string | null; released: string | null;
  credit: { name: string; url: string };
  events: Record<string, { updated: string; groups: { all?: LView; top?: LView } }>;
}

const p1 = (x: number) => `${(x * 100).toFixed(1)}%`;
/** A main-colour string as a pair key (3+ colours read as 3C). */
const c2 = (m: string) => (m.length >= 3 ? "3C" : m);
export const EVENT_NAMES: Record<string, string> = {
  PremierDraft: "Premier Draft", TradDraft: "Traditional Draft", PickTwoDraft: "Pick Two Draft", Sealed: "Sealed", TradSealed: "Traditional Sealed",
};
export const PAIR_NAMES: Record<string, string> = {
  WU: "white-blue", WB: "white-black", WR: "white-red", WG: "white-green", UB: "blue-black", UR: "blue-red", UG: "blue-green",
  BR: "black-red", BG: "black-green", RG: "red-green", W: "mono-white", U: "mono-blue", B: "mono-black", R: "mono-red", G: "mono-green",
  "3C": "three or more colours", C: "colourless",
};

/** Pairs, standout commons and uncommons, the most underdrafted cards and the play/draw gap. */
export function limitedFacts(pack: LimitedPack, event: string, grp: "all" | "top", v: LView): Facts {
  const who = grp === "top" ? "top players (60%+ win rate)" : "all players";
  const lines = [`${pack.name ?? pack.set_code} ${EVENT_NAMES[event] ?? event}, ${who}: ${v.games} games over ${v.weeks} weeks, average game win rate ${p1(v.wr)}`];
  const pairs = v.pairs.filter((p) => p.p.length === 2 && p.p !== "3C" && p.games >= 500).sort((a, b) => b.wr - a.wr);
  for (const p of pairs.slice(0, 3)) {
    const trend = p.week_wr.filter((x): x is number => x != null);
    lines.push(`${PAIR_NAMES[p.p] ?? p.p}: ${p1(p.wr)} win rate, ${p1(p.share)} of games`
      + (trend.length >= 2 ? ` (week 1 ${p1(trend[0])}, latest week ${p1(trend[trend.length - 1])})` : ""));
  }
  const splashed = (v.colors ?? []).filter((c) => c.s && c.share >= 0.01).sort((a, b) => b.wr - a.wr)[0];
  if (splashed) lines.push(`Best splash: ${PAIR_NAMES[c2(splashed.m)] ?? splashed.m} splashing ${splashed.s} at ${p1(splashed.wr)} (${p1(splashed.share)} of games)`);
  const worst = pairs[pairs.length - 1];
  if (worst && pairs.length > 3) lines.push(`Weakest pair: ${PAIR_NAMES[worst.p] ?? worst.p} at ${p1(worst.wr)}`);
  const rated = v.cards.filter((c) => c.gih != null);
  for (const r of ["common", "uncommon"]) {
    const best = rated.filter((c) => c.r === r).sort((a, b) => b.gih! - a.gih!).slice(0, 2);
    for (const c of best) lines.push(`Top ${r}: ${c.n} at ${p1(c.gih!)} in hand`);
  }
  // underdrafted: high win rate, taken late (only with draft data)
  const withAta = rated.filter((c) => c.ata != null && c.gih_n >= 2000);
  if (withAta.length >= 20) {
    const sorted = [...withAta].sort((a, b) => b.gih! - a.gih!);
    const late = sorted.slice(0, Math.ceil(sorted.length / 4)).sort((a, b) => b.ata! - a.ata!)[0];
    if (late) lines.push(`Taken late for its win rate: ${late.n}, ${p1(late.gih!)} in hand, taken on average at pick ${late.ata!.toFixed(1)}`);
  }
  const f = v.facts;
  if (f.play_wr != null && f.draw_wr != null) lines.push(`On the play ${p1(f.play_wr)}, on the draw ${p1(f.draw_wr)}`);
  return { view: `limited:${pack.set_code}:${event}:${grp}`, title: `${pack.name ?? pack.set_code} ${EVENT_NAMES[event] ?? event}`, lines, thin: v.games < 20000 };
}
