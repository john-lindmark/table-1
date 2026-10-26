// Builds the constructed pack from the database's facts (meta_pack_* RPCs) and writes the facts sheets the briefs
// are drawn from (contract/insights-2026-10-24.md § Constructed pack, § Briefs). Pure, so tests run on fixtures.
import type { Facts } from "../insight-brief/brief.ts";
import type { Archetype, BanStudy, Base, Change, ConstructedPack, Matchups, Tier, View, Window } from "./types.ts";

/** 21% / 3.4% (shares under 10% keep one decimal so small decks don't all read 0% or 1%). */
export const pct = (x: number) => x >= 0.0995 || x === 0 ? `${Math.round(x * 100)}%` : `${(x * 100).toFixed(1)}%`;
/** +6 pts / -0.4 pts: a change in percentage points. */
export const pts = (d: number) => {
  const v = Math.abs(d * 100) >= 10 ? Math.round(d * 100).toString() : (d * 100).toFixed(1);
  return `${d >= 0 ? "+" : "-"}${v.replace("-", "")} pts`;
};
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
export const day = (iso: string) => { const [, m, d] = iso.split("-").map(Number); return `${MONTHS[m - 1]} ${d}`; };

/**
 * Days after a change until the meta settled: the first day from which every line's 7-day share stays within
 * 2 points for 7 days running. Null when that hasn't happened in the days we have.
 */
export function settledDays(lines: { v: (number | null)[] }[], band = 0.02, span = 7): number | null {
  const n = Math.max(0, ...lines.map((l) => l.v.length));
  for (let d = 0; d + span <= n; d++) {
    const ok = lines.every((l) => {
      const w = l.v.slice(d, d + span).filter((x): x is number => x != null);
      return w.length >= span - 1 && Math.max(...w) - Math.min(...w) <= band;
    });
    if (ok) return d;
  }
  return null;
}

export function assemble(base: Base, tiers: Record<Tier, View>, bans: BanStudy[], matchups: Matchups, builtAt: string): ConstructedPack {
  return {
    v: 1, kind: "constructed", ...base, built_at: builtAt, tiers,
    // a change from before the data starts (nothing before it and nothing after) has nothing to show
    bans: bans.filter((b) => b.before.length || Object.values(b.after).some((a) => a.length))
      .map(({ daily, after_days: _d, ...b }) => ({ ...b, settled_days: daily ? settledDays(daily.lines) : null })),
    matchups,
  };
}

const names = (archetypes: Archetype[]) => {
  const m = new Map(archetypes.map((a) => [a.id, a.name]));
  return (id: number) => m.get(id) ?? "Other";
};

/** The facts for a tier × window's brief: the top decks and their change, the biggest movers, rising cards. */
export function windowFacts(pack: Pick<ConstructedPack, "format" | "name" | "archetypes" | "changes">, tier: Tier, days: number, w: Window): Facts {
  const name = names(pack.archetypes);
  const lines: string[] = [];
  const scope = tier === "big" ? "big events" : "all events";
  lines.push(`Window: the last ${days} days of ${pack.name} ${scope}, ${w.decks} decks from ${w.events} event${w.events === 1 ? "" : "s"} (shares are of top finishes)`);
  const named = w.share.filter((s) => s.a !== 0);
  for (const s of named.slice(0, 6)) {
    lines.push(`${name(s.a)}: ${pct(s.share)}` + (s.prev != null ? ` (was ${pct(s.prev)}, ${pts(s.share - s.prev)})` : " (new in this window)")
      + (s.conv != null ? `, converts to top 8 at ${s.conv}x its share` : ""));
  }
  const other = w.share.find((s) => s.a === 0);
  if (other) lines.push(`Decks with no named archetype: ${pct(other.share)}`);
  const movers = named.filter((s) => s.prev != null).map((s) => ({ s, d: s.share - (s.prev ?? 0) }));
  const up = [...movers].sort((a, b) => b.d - a.d)[0], down = [...movers].sort((a, b) => a.d - b.d)[0];
  if (up && up.d >= 0.01) lines.push(`Biggest gain: ${name(up.s.a)} ${pts(up.d)}`);
  if (down && down.d <= -0.01) lines.push(`Biggest drop: ${name(down.s.a)} ${pts(down.d)}`);
  for (const c of w.cards.main.up.slice(0, 3)) {
    lines.push(`Rising card: ${c.n} in ${pct(c.rate)} of decks (was ${pct(c.prev ?? 0)})`);
  }
  for (const c of w.cards.main.down.slice(0, 2)) {
    lines.push(`Falling card: ${c.n} in ${pct(c.rate)} of decks (was ${pct(c.prev ?? 0)})`);
  }
  for (const c of w.cards.side.up.slice(0, 1)) lines.push(`Rising sideboard card: ${c.n} in ${pct(c.rate)} of sideboards (was ${pct(c.prev ?? 0)})`);
  const recent = pack.changes.filter((c) => c.kind !== "set_release" && daysBetween(c.on, pack) <= days);
  for (const c of recent) lines.push(`${changeWords(c)} on ${day(c.on)}`);
  return { view: `constructed:${pack.format}:${tier}:${days}`, title: `${pack.name} metagame, last ${days} days, ${scope}`, lines, thin: w.thin };
}

const daysBetween = (iso: string, pack: { changes: Change[] } & { through?: string }) => {
  const through = (pack as { through?: string }).through ?? new Date().toISOString().slice(0, 10);
  return Math.round((Date.parse(through) - Date.parse(iso)) / 86400000);
};

export function changeWords(c: Change): string {
  const cards = c.cards.length > 3 ? `${c.cards.slice(0, 3).join(", ")} and others` : c.cards.join(" and ");
  switch (c.kind) {
    case "ban": return `Banned: ${cards}`;
    case "unban": return `Unbanned: ${cards}`;
    case "restrict": return `Restricted: ${cards}`;
    case "unrestrict": return `Unrestricted: ${cards}`;
    case "rotation": return "Rotation";
    case "points": return `Points: ${c.note ?? cards}`;
    default: return `Released: ${c.note ?? c.set_code ?? "a new set"}`;
  }
}

/** The facts for a ban study's brief. */
export function banFacts(pack: Pick<ConstructedPack, "format" | "name" | "archetypes" | "changes">, b: BanStudy): Facts | null {
  const ch = pack.changes.find((c) => c.id === b.change);
  if (!ch) return null;
  const name = names(pack.archetypes);
  const lines = [`${changeWords(ch)} in ${pack.name} on ${day(ch.on)}`];
  for (const l of b.losers.slice(0, 3)) lines.push(`${name(l.a)} went from ${pct(l.before)} to ${pct(l.after)} of top finishes`);
  for (const g of b.gainers.slice(0, 3)) lines.push(`${name(g.a)} went from ${pct(g.before)} to ${pct(g.after)} (${pts(g.after - g.before)})`);
  for (const r of b.replacements.slice(0, 3)) {
    lines.push(ch.kind === "unban" || ch.kind === "unrestrict" || (ch.kind === "points" && r.before === 0)
      ? `${r.n} is in ${pct(r.after)} of ${name(r.in)} lists since`
      : `In ${name(r.in)}, ${r.n} went from ${pct(r.before)} to ${pct(r.after)} of lists`);
  }
  lines.push(b.settled_days != null ? `The shares settled after ${b.settled_days} days` : "The shares haven't settled yet");
  const thin = !b.before.length || !Object.keys(b.after).length;
  return { view: `ban:${pack.format}:${b.change}`, title: `${pack.name}: what changed after ${changeWords(ch).toLowerCase()}`, lines, thin };
}

/** The facts for an archetype page's brief (meta_archetype's answer, All events, 30 days). */
export function archetypeFacts(pack: Pick<ConstructedPack, "format" | "name" | "archetypes">, a: {
  archetype: Archetype; decks: number; record: { wins: number; losses: number; basis: string } | null;
  conv: number | null; core: { n: string }[]; flex: { n: string; rate: number }[]; side: { n: string; rate: number }[];
  matchups: { vs: number; wins: number; losses: number; draws: number }[];
}, share: { share: number; prev: number | null } | undefined): Facts {
  const name = names(pack.archetypes);
  const lines = [`${a.archetype.name} in ${pack.name}, last 30 days: ${a.decks} decks`];
  if (share) lines.push(`Share of top finishes: ${pct(share.share)}` + (share.prev != null ? ` (was ${pct(share.prev)})` : ""));
  if (a.record && a.record.wins + a.record.losses >= 20) {
    const wr = a.record.wins / (a.record.wins + a.record.losses);
    lines.push(`Match record ${a.record.basis === "topdeck" ? "at paper events" : "of top-32 finishers"}: ${a.record.wins}-${a.record.losses} (${pct(wr)})`);
  }
  if (a.conv != null) lines.push(`Converts to top 8 at ${a.conv}x its share`);
  if (a.core.length) lines.push(`Core cards: ${a.core.slice(0, 5).map((c) => c.n).join(", ")}`);
  for (const f of a.flex.slice(0, 3)) lines.push(`Flex card: ${f.n} in ${pct(f.rate)} of lists`);
  for (const s of a.side.slice(0, 2)) lines.push(`Sideboard: ${s.n} in ${pct(s.rate)} of lists`);
  for (const m of a.matchups.filter((m) => m.wins + m.losses >= 30).slice(0, 2)) {
    lines.push(`Against ${name(m.vs)}: ${m.wins}-${m.losses} in matches (${pct(m.wins / (m.wins + m.losses))})`);
  }
  return { view: `arch:${pack.format}:${a.archetype.id}`, title: `${a.archetype.name} in ${pack.name}`, lines, thin: a.decks < 20 };
}
