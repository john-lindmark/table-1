// TopDeck.gg API v2 (https://topdeck.gg/docs/tournaments-v2): paper events with standings, decklists once
// public, and every round's tables. Free key in TOPDECK_API_KEY; the docs ask for a visible credit and link
// (contract/insights-2026-10-24.md § What the viewer gets). Pure apart from the request body, so tests run on
// saved answers.
import type { DeckIn, EventIn, MatchIn } from "./types.ts";
import { singletonField } from "./singleton.ts";

export const TOPDECK_GAME = "Magic: The Gathering";

/** The request body: the last N days, or a window of start/end in Unix seconds (the backfill). */
export interface TdQuery {
  game: string; format: string; last?: number; start?: number; end?: number; participantMin: number;
  columns: string[]; rounds: boolean; tables: string[]; players: string[];
}
export function tournamentsQuery(format: string, range: number | { start: number; end: number }, participantMin = 32): TdQuery {
  return {
    game: TOPDECK_GAME, format, ...(typeof range === "number" ? { last: range } : range), participantMin,
    columns: ["id", "decklist", "wins", "losses", "draws"],
    rounds: true, tables: ["table", "players", "winner", "status"], players: ["id"],
  };
}

const DAY = 86_400_000;

/**
 * The TopDeck backfill's next window. Each format's cursor (`td_back_<format>` in meta_state, an ISO date) is where
 * its history read has reached; without one it starts 3 days back, where the builds' "last 3 days" take over. Of the
 * formats still short of `days` of history, TopDeck-only formats (no MTGO results) go first, then the one with the
 * least history read. Null when every format is read back far enough.
 */
export function nextTopdeckWindow(formats: { format: string; topdeckOnly: boolean }[], state: Record<string, string>, now: number,
                                  days = 365, windowDays = 30): { format: string; start: number; end: number } | null {
  const floor = now - days * DAY;
  const open = formats.map((f, i) => {
    const cursor = state[`td_back_${f.format}`];
    const end = cursor ? Date.parse(cursor) : now - 3 * DAY;
    return { ...f, i, end };
  }).filter((f) => f.end > floor);
  open.sort((a, b) => Number(b.topdeckOnly) - Number(a.topdeckOnly) || b.end - a.end || a.i - b.i);
  const f = open[0];
  if (!f) return null;
  return { format: f.format, start: Math.floor(Math.max(floor, f.end - windowDays * DAY) / 1000), end: Math.floor(f.end / 1000) };
}

interface TdStanding { id?: string; decklist?: string | null; deckObj?: Record<string, unknown> | null; wins?: number; losses?: number; draws?: number }
interface TdTable { table?: number | string; players?: { id?: string }[]; winner_id?: string | null; winner_games?: number | null; loser_games?: number | null; status?: string }
export interface TdTournament {
  TID: string; tournamentName?: string; startDate?: number; format?: string; topCut?: number;
  standings?: TdStanding[]; rounds?: { round: number | string; tables?: TdTable[] }[];
}

/** Card lines from deckObj ({ Mainboard: { name: { count } | count }, Sideboard: … }) or, failing that, from
 *  decklist text ("4 Card" lines; a "Sideboard" line starts the sideboard). A link-only decklist gives nothing. */
export function deckLines(s: TdStanding): { main: [string, number][]; side: [string, number][] } {
  const fromObj = (o: unknown): [string, number][] => {
    if (!o || typeof o !== "object") return [];
    return Object.entries(o as Record<string, unknown>).flatMap(([name, v]) => {
      const n = typeof v === "number" ? v : Number((v as { count?: unknown })?.count ?? 0);
      return n > 0 ? [[name.trim(), n] as [string, number]] : [];
    });
  };
  const obj = s.deckObj ?? null;
  if (obj && (obj.Mainboard || obj.mainboard)) {
    return { main: fromObj(obj.Mainboard ?? obj.mainboard), side: fromObj(obj.Sideboard ?? obj.sideboard) };
  }
  const text = (s.decklist ?? "").trim();
  if (!text || /^https?:\/\//.test(text)) return { main: [], side: [] };
  const main: [string, number][] = [], side: [string, number][] = [];
  let into = main;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) { if (main.length) into = side; continue; }
    if (/^(sideboard|sb)[:\s]*$/i.test(line)) { into = side; continue; }
    if (/^(deck|mainboard|main|companion)[:\s]*$/i.test(line)) continue;
    const m = /^(?:SB:\s*)?(\d+)x?\s+(.+?)(?:\s+\([A-Z0-9]+\)\s*\S*)?$/.exec(line);
    if (m) (line.startsWith("SB:") ? side : into).push([m[2].trim(), Number(m[1])]);
  }
  return { main, side };
}

/** One TopDeck tournament as meta_ingest's event; null when no deck is public yet or the field is singleton (singleton.ts). */
export function parseTournament(t: TdTournament, format: string): EventIn | null {
  const standings = t.standings ?? [];
  const decks: DeckIn[] = standings.map((s, i) => {
    const { main, side } = deckLines(s);
    return {
      player: String(s.id ?? `row${i}`), rank: i + 1,
      wins: s.wins ?? null, losses: s.losses ?? null, draws: s.draws ?? null,
      top8: i < 8 && (t.topCut ?? 0) >= 8, main, side,
    };
  });
  const withLists = decks.filter((d) => d.main.reduce((n, [, q]) => n + q, 0) >= 40);
  if (!withLists.length || singletonField(format, withLists)) return null;
  const matches: MatchIn[] = [];
  for (const r of t.rounds ?? []) {
    for (const tb of r.tables ?? []) {
      const [p, q] = tb.players ?? [];
      if (!p?.id || !q?.id || tb.status !== "Completed") continue;
      const result = tb.winner_id === "Draw" || tb.winner_id == null ? "draw" : tb.winner_id === p.id ? "a" : "b";
      matches.push({
        round: String(r.round), a: p.id, b: q.id, result,
        a_wins: result === "a" ? tb.winner_games ?? null : tb.loser_games ?? null,
        b_wins: result === "b" ? tb.winner_games ?? null : tb.loser_games ?? null,
      });
    }
  }
  const on = new Date((t.startDate ?? 0) * 1000).toISOString().slice(0, 10);
  return {
    source: "topdeck", source_id: t.TID, format, name: (t.tournamentName ?? "TopDeck event").trim(), kind: "paper", on,
    players: standings.length || null, url: `https://topdeck.gg/event/${t.TID}`,
    complete: withLists.length === decks.length, decks: withLists, matches,
  };
}
