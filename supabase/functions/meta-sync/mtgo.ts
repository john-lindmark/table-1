// MTGO decklist pages (www.mtgo.com/decklists): the month index lists event pages by slug, and every event page
// carries its data as `window.MTGO.decklists.data = {...};`. Pure, so tests run on saved pages.
//   slug: <format>-<event words>-<yyyy>-<mm>-<dd><event id>, e.g. modern-challenge-32-2026-10-2412856973
import type { EventIn, DeckIn, MatchIn } from "./types.ts";

export const MTGO_FORMATS = ["standard", "pioneer", "modern", "pauper", "legacy", "vintage", "premodern"];

export interface SlugInfo { format: string; kind: EventIn["kind"]; on: string; id: string; words: string }

/** What a slug says about its event; null for formats or pages we don't read (Limited, Commander). */
export function slugInfo(slug: string): SlugInfo | null {
  const m = /^([a-z0-9-]+?)-(\d{4})-(\d{2})-(\d{2})(\d+)$/.exec(slug);
  if (!m) return null;
  const [, head, y, mo, d, id] = m;
  const format = MTGO_FORMATS.find((f) => head === f || head.startsWith(f + "-"));
  if (!format) return null;
  const words = head.slice(format.length + 1);
  const kind: EventIn["kind"] = words.startsWith("league") ? "league"
    : words.includes("showcase") ? "showcase"
    : words.includes("super-qualifier") || words.includes("qualifier") ? "qualifier"
    : words.includes("championship") ? "championship"
    : words.includes("challenge") ? "challenge" : "other";
  return { format, kind, on: `${y}-${mo}-${d}`, id: `${id}-${y}${mo}${d}`, words };
}

/** Event slugs on a month index page, in page order, without duplicates. */
export function indexSlugs(html: string): string[] {
  const seen = new Set<string>();
  for (const m of html.matchAll(/\/decklist\/([a-z0-9-]+)/g)) seen.add(m[1]);
  return [...seen];
}

/** "2026/10" → "2026/09". */
export const monthBefore = (m: string) => {
  const [y, mo] = m.split("/").map(Number);
  return mo === 1 ? `${y - 1}/12` : `${y}/${String(mo - 1).padStart(2, "0")}`;
};

/** The 12-month backfill of month indexes: `next` counts down to `until`; `retry` lists months whose index came back
 *  with no event pages at all ("2026/07:2,2026/01:1", month:tries). MTGO sometimes renders a month's index with an
 *  empty list (cold cache, as with event pages below), and passing over it lost July and January 2026 for good. */
export interface Backfill { next: string; until: string; retry: string }
export const INDEX_TRIES = 72;   // tried on the hourly index read: three days

const retries = (r: string) => r.split(",").filter(Boolean).map((x) => { const [m, n] = x.split(":"); return [m, Number(n) || 0] as const; });

/** The month index to read this tick: the backfill's next month while it runs (every tick), then the first month
 *  waiting for a retry (only on ticks that read the current month's index, hourly: MTGO's empty lists last a while). */
export function backfillMonth(b: Backfill, hourly: boolean): string | null {
  if (b.next >= b.until) return b.next;
  return hourly ? retries(b.retry)[0]?.[0] ?? null : null;
}

/** The backfill after reading month `m`'s index and finding `slugs` event pages on it. An empty index goes to the end
 *  of the retry list, until it has been tried INDEX_TRIES times. */
export function backfillAfter(b: Backfill, m: string, slugs: number): Backfill {
  const list = retries(b.retry);
  const tries = (list.find(([x]) => x === m)?.[1] ?? 0) + 1;
  const rest = list.filter(([x]) => x !== m);
  if (slugs === 0 && tries < INDEX_TRIES) rest.push([m, tries]);
  return { next: m === b.next ? monthBefore(m) : b.next, until: b.until, retry: rest.map(([x, n]) => `${x}:${n}`).join(",") };
}

/** Whether a page fetch ended somewhere other than the page. MTGO answers a page it hasn't served for a while with a
 *  302 to /decklists (the month index) and serves the page itself a moment later, so this is "try again", never "no
 *  decklists": read as the index, Sept–Oct 2026 Challenges and Leagues were skipped for good. */
export function bounced(requested: string, res: { redirected: boolean; url: string }): boolean {
  if (res.redirected) return true;
  if (!res.url) return false;
  try { return new URL(res.url).pathname.replace(/\/$/, "") !== new URL(requested).pathname.replace(/\/$/, ""); } catch { return false; }
}

/** The page's data object, or null when the page has none (not published yet, or a changed layout). */
export function pageData(html: string): Record<string, unknown> | null {
  const m = /window\.MTGO\.decklists\.data\s*=\s*(\{[\s\S]*?\});\s*\n/.exec(html);
  if (!m) return null;
  try { return JSON.parse(m[1]); } catch { return null; }
}

interface MtgoLine { qty: string | number; card_attributes?: { card_name?: string } }
interface MtgoDeck { loginid?: string | number; main_deck?: MtgoLine[]; sideboard_deck?: MtgoLine[] }
interface MtgoBracketPlayer { loginid: string | number; wins?: number; losses?: number; winner?: boolean }

const lines = (l: MtgoLine[] | undefined): [string, number][] => {
  const qty = new Map<string, number>();
  for (const x of l ?? []) {
    const name = x.card_attributes?.card_name?.trim();
    const q = Number(x.qty);
    if (name && q > 0) qty.set(name, (qty.get(name) ?? 0) + q);
  }
  return [...qty];
};

const ROUNDS = ["QF", "SF", "F"];

/** One event for meta_ingest. Players are MTGO login ids (the server hashes them); names are never read. */
export function parseEvent(slug: string, data: Record<string, unknown>): EventIn | null {
  const info = slugInfo(slug);
  if (!info) return null;
  const decks = (data.decklists as MtgoDeck[] | undefined) ?? [];
  if (!decks.length) return null;
  const byId = <T extends { loginid?: string | number }>(rows: unknown) =>
    new Map(((rows as T[] | undefined) ?? []).map((r) => [String(r.loginid), r]));
  const standings = byId<{ loginid: string; rank?: string }>(data.standings);
  const finals = byId<{ loginid: string; rank?: string }>(data.final_rank);
  const records = byId<{ loginid: string; wins?: string; losses?: string }>(data.winloss);
  const brackets = (data.brackets as { matches: { players: MtgoBracketPlayer[] }[] }[] | undefined) ?? [];
  const hasPlayoff = brackets.length > 0;

  const out: DeckIn[] = decks.map((d) => {
    const id = String(d.loginid ?? "");
    const rank = Number(finals.get(id)?.rank ?? standings.get(id)?.rank) || null;
    const rec = records.get(id);
    return {
      player: id,
      rank,
      wins: rec?.wins != null ? Number(rec.wins) : null,
      losses: rec?.losses != null ? Number(rec.losses) : null,
      draws: null,
      top8: info.kind !== "league" && rank != null && rank <= 8 && (hasPlayoff || decks.length >= 8),
      main: lines(d.main_deck),
      side: lines(d.sideboard_deck),
    };
  });

  const matches: MatchIn[] = [];
  brackets.forEach((b, i) => {
    for (const m of b.matches ?? []) {
      const [p, q] = m.players ?? [];
      if (!p || !q) continue;
      matches.push({
        round: ROUNDS[i + Math.max(0, 3 - brackets.length)] ?? `P${i + 1}`,
        a: String(p.loginid), b: String(q.loginid),
        a_wins: p.wins ?? null, b_wins: q.wins ?? null,
        result: p.winner ? "a" : q.winner ? "b" : "draw",
      });
    }
  });

  const count = data.player_count as { players?: string | number } | undefined;
  const players = Number(count?.players) || (info.kind === "league" ? null : decks.length);
  const name = String(data.description ?? data.name ?? slug).trim();
  return {
    source: "mtgo", source_id: info.id, format: info.format, name, kind: info.kind, on: info.on, players,
    url: `https://www.mtgo.com/decklist/${slug}`, complete: false, decks: out, matches,
  };
}
