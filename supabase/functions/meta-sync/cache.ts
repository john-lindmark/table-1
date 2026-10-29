// Melee.gg results from fbettega/MTG_decklistcache (https://github.com/fbettega/MTG_decklistcache, GPL-3.0): an open
// cache of paper tournaments, one JSON file per event under Tournaments/MTGmelee/<yyyy>/<mm>/<dd>/, refreshed daily
// around 17:00 UTC by its own scraper. We read only the MTGmelee folder (MTGO and TopDeck we read at the source).
// Files are listed with GitHub's API (a contents call, then one tree per changed year) and read from
// raw.githubusercontent.com. Pure apart from the URLs, so tests run on saved files.
import type { DeckIn, EventIn, MatchIn } from "./types.ts";

export const CACHE_REPO = "fbettega/MTG_decklistcache";
export const CACHE_DIR = "Tournaments/MTGmelee";
export const CACHE_YEARS_URL = `https://api.github.com/repos/${CACHE_REPO}/contents/${CACHE_DIR}?ref=main`;
export const cacheTreeUrl = (sha: string) => `https://api.github.com/repos/${CACHE_REPO}/git/trees/${sha}?recursive=1`;
export const cacheRawUrl = (path: string) =>
  `https://raw.githubusercontent.com/${CACHE_REPO}/main/${CACHE_DIR}/${path.split("/").map(encodeURIComponent).join("/")}`;

interface GhEntry { path: string; type: string; sha: string; name?: string }

/** The year folders worth listing (the ones a `days`-long history reaches) whose tree changed since `state`
 *  (`cache_melee_<yyyy>` = the tree sha last queued). */
export function cacheYears(entries: GhEntry[], state: Record<string, string>, now: number, days = 365): { year: string; sha: string }[] {
  const from = new Date(now - days * 86_400_000).getUTCFullYear();
  return entries.filter((e) => e.type === "dir" && /^\d{4}$/.test(e.name ?? e.path.split("/").pop()!))
    .map((e) => ({ year: e.name ?? e.path.split("/").pop()!, sha: e.sha }))
    .filter((y) => Number(y.year) >= from && state[`cache_melee_${y.year}`] !== y.sha)
    .sort((a, b) => a.year.localeCompare(b.year));
}

/** Queue items for a year's files dated within `days` of `now`. The slug carries the file's blob sha, so a file the
 *  cache rewrites (lists published later, a fix) is read again; meta_ingest replaces the event by its file name. */
export function cacheItems(year: string, tree: GhEntry[], now: number, days = 365) {
  const from = new Date(now - days * 86_400_000).toISOString().slice(0, 10);
  return tree.flatMap((e) => {
    const m = /^(\d{2})\/(\d{2})\/[^/]+\.json$/.exec(e.path);
    if (e.type !== "blob" || !m || `${year}-${m[1]}-${m[2]}` < from) return [];
    const path = `${year}/${e.path}`;
    return [{ source: "melee", format: null, slug: `${path}@${e.sha.slice(0, 12)}`, url: cacheRawUrl(path) }];
  });
}

interface CacheCard { Count?: number; CardName?: string }
interface CacheDeck { Player?: string; Result?: string; AnchorUri?: string; Mainboard?: CacheCard[]; Sideboard?: CacheCard[] }
interface CacheMatch { Player1?: string; Player2?: string; Result?: string }
interface CacheStanding { Rank?: number; Player?: string; Wins?: number; Losses?: number; Draws?: number }
export interface CacheFile {
  Tournament?: { Date?: string; Name?: string; Uri?: string; Formats?: string | string[] };
  Decks?: CacheDeck[]; Rounds?: { RoundName?: string; Matches?: CacheMatch[] }[] | null; Standings?: CacheStanding[] | null;
}

const lines = (cards: CacheCard[] | undefined): [string, number][] => {
  const qty = new Map<string, number>();
  for (const c of cards ?? []) {
    const name = c.CardName?.trim();
    const n = Number(c.Count);
    if (name && n > 0) qty.set(name, (qty.get(name) ?? 0) + n);
  }
  return [...qty];
};

/** "2-1-0" → games for player 1, player 2; null for anything else. */
function games(result: string | undefined): [number, number] | null {
  const m = /^(\d+)-(\d+)(?:-\d+)?$/.exec((result ?? "").trim());
  return m ? [Number(m[1]), Number(m[2])] : null;
}
// The cache writes a bye as the player against "-".
const isBye = (p: string | undefined) => !p || /^(-+|bye)$/i.test(p.trim());

/** Whether the event ended in a top 8: Melee numbers playoff rounds like Swiss ones, so it's the last three rounds
 *  holding 4, then 1–2 (a semifinal can be missing from the export, or a third-place match added) and 1–2 matches,
 *  all among players ranked 8th or better, after a round of more than 4. Single-elimination events (24, 12, 6, 3)
 *  and day-two cuts don't count. */
export function hasTopEight(rounds: { matches: [string, string][] }[], rank: Map<string, number>): boolean {
  if (rounds.length < 4) return false;
  const [qf, sf, f] = rounds.slice(-3);
  const n = (r: { matches: unknown[] }) => r.matches.length;
  if (n(qf) !== 4 || n(sf) < 1 || n(sf) > 2 || n(f) < 1 || n(f) > 2 || n(rounds[rounds.length - 4]) <= 4) return false;
  return [qf, sf, f].every((r) => r.matches.flat().every((p) => (rank.get(p) ?? 0) >= 1 && rank.get(p)! <= 8));
}

/** "Modern" (or ["Modern"]) → the enabled format it names; null for any other format. */
export function cacheFormat(formats: string | string[] | undefined, enabled: { format: string; name: string }[]): string | null {
  const names = (Array.isArray(formats) ? formats : [formats ?? ""]).map((s) => s.trim().toLowerCase()).filter(Boolean);
  if (names.length !== 1) return null;
  return enabled.find((f) => f.format === names[0] || f.name.toLowerCase() === names[0])?.format ?? null;
}

/** One cached Melee event as meta_ingest's event; null when its format isn't read, it's smaller than the format's
 *  paper minimum (`topdeck_min`, as for TopDeck) or no list is public. `id` is the file name without .json. */
export function parseCacheEvent(id: string, file: CacheFile, enabled: { format: string; name: string; topdeck_min: number }[]): EventIn | null {
  const t = file.Tournament ?? {};
  const format = cacheFormat(t.Formats, enabled);
  if (!format || !/^\d{4}-\d{2}-\d{2}/.test(t.Date ?? "")) return null;
  const standings = file.Standings ?? [];
  const players = standings.length || (file.Decks ?? []).length;
  if (players < (enabled.find((f) => f.format === format)!.topdeck_min || 32)) return null;

  const byPlayer = new Map(standings.filter((s) => s.Player).map((s) => [s.Player!, s]));
  const rank = new Map<string, number>();
  for (const s of standings) if (s.Player && s.Rank) rank.set(s.Player, s.Rank);
  for (const d of file.Decks ?? []) {
    const ord = /^(\d+)\w*\s+place/i.exec(d.Result ?? "");
    if (d.Player && ord && !rank.has(d.Player)) rank.set(d.Player, Number(ord[1]));
  }

  const rounds = (file.Rounds ?? []).map((r) => ({
    name: (r.RoundName ?? "").trim(),
    all: r.Matches ?? [],
    matches: (r.Matches ?? []).filter((m) => !isBye(m.Player1) && !isBye(m.Player2)).map((m) => [m.Player1!, m.Player2!] as [string, string]),
  }));
  const top8 = hasTopEight(rounds, rank);

  const decks: DeckIn[] = (file.Decks ?? []).flatMap((d) => {
    const main = lines(d.Mainboard);
    if (!d.Player || main.reduce((n, [, q]) => n + q, 0) < 40) return [];
    const s = byPlayer.get(d.Player);
    const r = rank.get(d.Player) ?? null;
    return [{
      player: d.Player, rank: r, wins: s?.Wins ?? null, losses: s?.Losses ?? null, draws: s?.Draws ?? null,
      top8: top8 && r != null && r <= 8, main, side: lines(d.Sideboard),
    }];
  });
  if (!decks.length) return null;

  const matches: MatchIn[] = [];
  rounds.forEach((r, i) => {
    for (const m of r.all) {
      if (isBye(m.Player1) || isBye(m.Player2)) continue;
      const g = games(m.Result);
      if (!g) continue;
      const result = g[0] > g[1] ? "a" : g[1] > g[0] ? "b" : "draw";
      matches.push({ round: r.name || `Round ${i + 1}`, a: m.Player1!, b: m.Player2!, a_wins: g[0], b_wins: g[1], result });
    }
  });

  const name = (t.Name ?? "Melee event").trim();
  // A championship is a major event whatever its size; its qualifiers (RCQs) go by size like any paper event.
  const championship = /regional championship|pro tour|world championship|players tour/i.test(name) && !/qualifier|\brcq\b/i.test(name);
  return {
    source: "melee", source_id: id, format, name, kind: championship ? "championship" : "paper",
    on: t.Date!.slice(0, 10), players, url: t.Uri ?? null,
    complete: standings.length > 0 && decks.length === standings.length, decks, matches,
  };
}
