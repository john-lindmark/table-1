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

/** What a tapped New in Insights push opens (the web has no pushes; the shared cases keep the rule in step). */
export interface InsightsPush { section: "constructed" | "limited"; key: string; what: "data" | "rank" }
export function insightsPush(info: Record<string, unknown>): InsightsPush | null {
  const section = info.insights_section, key = info.insights_key;
  if (info.kind !== "insights.new" || (section !== "constructed" && section !== "limited") || typeof key !== "string" || !key) return null;
  return { section, key, what: info.what === "rank" ? "rank" : "data" };
}
