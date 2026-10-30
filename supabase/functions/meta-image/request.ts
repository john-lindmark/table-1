// What a meta-image address asks for (index.ts serves it). Pure, for the tests.
import { deckPicture, matchupsPicture, type Pack, type Picture, type Tier, winratesPicture } from "./charts.ts";

export const KINDS = ["matchups", "winrates", "deck"] as const;
export type Kind = typeof KINDS[number];
export const WINDOWS = [7, 14, 30, 90];

export interface MetaRequest { format: string; kind: Kind; tier: Tier; days: number; a: number | null }
/** The picture asked for, or null for a malformed address (404). Defaults: All events, 30 days. */
export function parseRequest(u: URL): MetaRequest | null {
  const m = /\/meta-image\/([a-z]{3,20})\/(matchups|winrates|deck)(?:\.png)?\/?$/.exec(u.pathname);
  if (!m) return null;
  const tier = u.searchParams.get("tier") === "big" ? "big" : "all";
  const days = Number(u.searchParams.get("days") ?? 30);
  const aRaw = u.searchParams.get("a");
  const a = aRaw != null && /^[0-9]{1,6}$/.test(aRaw) ? Number(aRaw) : null;
  if (m[2] === "deck" && a == null) return null;
  return { format: m[1], kind: m[2] as Kind, tier, days: WINDOWS.includes(days) ? days : 30, a };
}

export function draw(p: Pack, q: MetaRequest): Picture {
  if (q.kind === "matchups") return matchupsPicture(p, q.tier, q.days);
  if (q.kind === "winrates") return winratesPicture(p, q.tier, q.days);
  return deckPicture(p, q.tier, q.days, q.a ?? 0);
}
