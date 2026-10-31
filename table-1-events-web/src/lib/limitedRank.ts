// A Limited set (or Arena cube version) as a ranking subject (contract/cube-rankings-2026-10-21.md § Sets, cases
// testdata/limited-rankings/cases.json): "set:FRA" where a cube's list id goes, so the Rankings screens open either by
// one id, plus the New in Insights push's route (contract/insights-2026-10-24.md § New in Insights). No imports, so
// Insights can use it without the ranking engine. Same as iOS RankSubject / Android RankSubject.

/** A set or Arena cube version as a ranking subject: "set:FRA". */
export const setSubjectId = (key: string) => `set:${key.toUpperCase()}`;
export const setKeyOf = (id: string | null | undefined): string | null =>
  id && id.startsWith("set:") && id.length > 4 ? id.slice(4) : null;
/** "Shared with the cube" reaches a set ranking's maker's friends (everyone can see a set). */
export const sharingLabel = (sharing: "cube" | "private", set: boolean) =>
  sharing === "private" ? "Only me" : set ? "Shared with friends" : "Shared with the cube";
/** A row from the server with its subject in list_id, whichever kind it ranks. */
export function subjectRow<T extends { list_id: string | null; set_key?: string | null }>(r: T): T & { list_id: string } {
  return (r.list_id || !r.set_key ? r : { ...r, list_id: setSubjectId(r.set_key) }) as T & { list_id: string };
}

/** A set or Arena cube version you can rank (limited_rankable), newest first. */
export interface RankableSet { key: string; name: string; released: string | null; kind: "set" | "cube"; cards: number; pack: boolean; mine: number; rankings: number }
/** "Arena cube · 540 cards · 3 rankings (1 yours)", "Out Nov 14 · 286 cards". */
export function rankableDetail(s: RankableSet, today = new Date()): string {
  const parts: string[] = [];
  if (s.kind === "cube") parts.push("Arena cube");
  else if (s.released && new Date(`${s.released}T00:00:00Z`) > today) {
    parts.push(`Out ${new Date(`${s.released}T00:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" })}`);
  }
  parts.push(`${s.cards} cards`);
  if (s.rankings > 0) parts.push(`${s.rankings} ranking${s.rankings === 1 ? "" : "s"}${s.mine > 0 ? ` (${s.mine} yours)` : ""}`);
  return parts.join(" · ");
}

/** A Limited key as the set picker shows it: an Arena cube version by its name ("Arena Powered Cube · Oct 2025"), a set
 *  by its code. */
export function limitedLabel(key: string, name: string | null | undefined): string {
  return /^[A-Z0-9]+-[0-9]{4}$/.test(key) && name ? name : key;
}

/** One chip of the Limited set picker; `pack` false for a set with no 17Lands data yet (it opens Rank this set). */
export interface LimitedChip { key: string; label: string; pack: boolean }
const shiftDay = (day: string, days: number) => new Date(Date.parse(`${day}T00:00:00Z`) + days * 86400000).toISOString().slice(0, 10);
/** Sets with no 17Lands data that came out in the last 28 days or are still to come (spoiler season), newest first,
 *  then the packs in the index's order. `today` is a UTC day, "2026-10-30". */
export function limitedPicker(packs: { key: string; name?: string | null }[], rankable: RankableSet[], today: string): LimitedChip[] {
  const from = shiftDay(today, -28), have = new Set(packs.map((p) => p.key));
  const fresh = rankable.filter((s) => s.kind === "set" && !s.pack && !!s.released && s.released >= from && !have.has(s.key));
  return [...fresh.map((s) => ({ key: s.key, label: s.key, pack: false })),
          ...packs.map((p) => ({ key: p.key, label: limitedLabel(p.key, p.name), pack: true }))];
}
/** The chips Insights → Edit leaves shown: sets with no data yet hide like the packs, and all show if all are hidden
 *  (the same rule as `visibleKeys`). */
export function shownChips(chips: LimitedChip[], hidden: string[]): LimitedChip[] {
  const shown = chips.filter((c) => !hidden.includes(c.key));
  return shown.length ? shown : chips;
}

const dayLabel = (day: string) => new Date(`${day}T00:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
/** What a set with no 17Lands data yet says above Rank this set. */
export function soonText(s: RankableSet, today: string): string {
  const coming = !!s.released && s.released > today;
  const when = s.released ? ` ${coming ? "comes" : "came"} out ${dayLabel(s.released)}.` : " has no draft data yet.";
  return `${s.name}${when} Draft data from 17Lands follows about three weeks after a set reaches Arena, and some sets never do. `
    + (coming ? `Rank it now from the ${s.cards} cards on Scryfall so far: cards spoiled later join your ranking for you to place.`
              : `Rank its ${s.cards} cards now.`);
}

/** What a tapped New in Insights push opens (the web has no pushes; the shared cases keep the rule in step). */
export interface InsightsPush { section: "constructed" | "limited"; key: string; what: "data" | "rank" }
export function insightsPush(info: Record<string, unknown>): InsightsPush | null {
  const section = info.insights_section, key = info.insights_key;
  if (info.kind !== "insights.new" || (section !== "constructed" && section !== "limited") || typeof key !== "string" || !key) return null;
  return { section, key, what: info.what === "rank" ? "rank" : "data" };
}
