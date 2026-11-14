/**
 * The TV display, table-1.site/d/<event> (contract/public-events-leagues-2026-11-13.md § 5): which view shows, how
 * lists page, the pairings lists and the clock's text. Pure; the shared cases are testdata/leagues/cases.json
 * (`display_auto`, `display_pages`, reference testdata/leagues/make_cases.py).
 */
import type { PublicEvent, PublicStandings } from "./api";

/** Everything the display reads: event_public and the engine's standings. */
export interface DisplayData {
  event: PublicEvent;
  standings: PublicStandings;
}

/** What `?show=` asks for. */
export type DisplayShow = "auto" | "clock" | "pairings" | "standings";
/** What the screen draws. */
export type DisplayView = "welcome" | "clock" | "pairings" | "standings";

export const DISPLAY_SHOWS: DisplayShow[] = ["auto", "clock", "pairings", "standings"];
/** Lists that don't fit turn a page this often. */
export const PAGE_SECONDS = 10;
/** The event is read again this often, besides on its broadcast. */
export const RELOAD_SECONDS = 15;

/** `?show=`; anything else is auto. */
export function parseShow(value: string | null | undefined): DisplayShow {
  const v = (value ?? "").toLowerCase() as DisplayShow;
  return DISPLAY_SHOWS.includes(v) ? v : "auto";
}

/** The keys: 1 2 3 pick a view, A goes back to auto. */
export function showForKey(key: string): DisplayShow | null {
  switch (key.toLowerCase()) {
    case "1": return "clock";
    case "2": return "pairings";
    case "3": return "standings";
    case "a": return "auto";
    default: return null;
  }
}

/**
 * Which view the TV shows on auto. `elapsed`: seconds into the round; `t`: seconds the display has been open.
 * Pairings for a round's first 5 minutes, then the clock, with 20 s of standings every 2 minutes once results are
 * coming in; standings once every result is in and after the finish; the welcome before round 1.
 */
export function displayAuto(status: string, round: number, elapsed: number, resultsIn: number, matches: number, t: number): DisplayView {
  if (status === "completed" || status === "archived") return "standings";
  if (round === 0) return "welcome";
  if (matches > 0 && resultsIn >= matches) return "standings";
  if (elapsed < 300) return "pairings";
  if (resultsIn > 0 && t % 120 >= 100) return "standings";
  return "clock";
}

/** How many rows fit a page and how many pages a list takes (at least one row, one page). */
export function displayPages(rows: number, height: number, rowHeight: number, header: number): { perPage: number; pages: number } {
  const perPage = Math.max(1, Math.floor((height - header) / rowHeight));
  return { perPage, pages: Math.max(1, Math.ceil(rows / perPage)) };
}

/** The page a list is on after `turns` page turns (arrows can turn back past the first). */
export function pageAt(turns: number, pages: number): number {
  const n = Math.max(1, pages);
  return ((turns % n) + n) % n;
}

/**
 * The view to draw. Before round 1 it's the welcome and after the finish the final standings, whatever was asked;
 * a picked view otherwise; auto follows `displayAuto` (and reads Standings between rounds, when no round is open).
 */
export function displayView(show: DisplayShow, s: {
  status: string; round: number; roundOpen: boolean; elapsed: number; resultsIn: number; matches: number; t: number;
}): DisplayView {
  if (s.status === "completed" || s.status === "archived") return "standings";
  if (s.round === 0) return "welcome";
  if (show !== "auto") return show;
  if (!s.roundOpen) return "standings";
  return displayAuto(s.status, s.round, s.elapsed, s.resultsIn, s.matches, s.t);
}

/* ── sizes ─────────────────────────────────────────────────────────────── */

export interface DisplaySize {
  /** One design pixel on this screen: the display is drawn for 1920 × 1080 and scales to whatever it gets. */
  unit: number;
  /** A list row's height. */
  row: number;
  /** Everything a list page holds besides its rows: the bar, the column labels and the page line. */
  header: number;
  /** Room for two lists (or two columns of one) side by side. */
  wide: boolean;
}

/** Sizes from the window: 72 px rows under 240 px of headers at 1080 tall, scaled down with the window. */
export function displaySize(width: number, height: number): DisplaySize {
  const unit = Math.max(0.25, Math.min(width / 1920, height / 1080));
  return { unit, row: Math.max(28, Math.round(72 * unit)), header: Math.round(240 * unit), wide: width >= 900 && width >= height * 1.2 };
}

/** How much larger a short list is drawn: one that fills less than a page grows toward filling it, up to 1.6×. */
export function listScale(rows: number, perPage: number): number {
  return rows > 0 && rows < perPage ? Math.min(1.6, perPage / rows) : 1;
}

/** The mono face: a character is about 0.61 em wide. */
const CHAR_EM = 0.61;

/**
 * `k` held to what the row's text allows, so growing a list never cuts a name short: `fixed` px of padding, gaps and
 * number columns plus `chars` characters of `type` px (all at scale 1) must still fit `available` px. Never under 1.
 */
export function fitScale(k: number, available: number, fixed: number, chars: number, type: number): number {
  // 4% to spare: faces differ a little in width, and every cell rounds to whole pixels.
  return Math.max(1, Math.min(k, (0.96 * available) / (fixed + chars * type * CHAR_EM)));
}

/** The same screen with its rows and type `k` times larger (the headers keep their size). */
export function scaled(size: DisplaySize, k: number): DisplaySize {
  return { ...size, unit: size.unit * k, row: Math.round(size.row * k) };
}

/* ── pairings ──────────────────────────────────────────────────────────── */

/** A match as event_public gives it (PublicPairing in lib/api.ts). */
export interface DisplayMatch {
  tableNumber: number | null;
  isBye: boolean;
  status: string;
  gameDraws: number;
  sides: { side: number; displayName: string; gameWins: number }[];
}

export interface TableRow {
  /** "12", or "BYE". */
  table: string;
  a: string;
  b: string | null;
  bye: boolean;
  /** "2–1" once a result is in. */
  score: string | null;
}

export interface PlayerRow {
  name: string;
  /** "12", or "BYE". */
  table: string;
  opponent: string | null;
  bye: boolean;
}

const sideName = (m: DisplayMatch, side: number) => m.sides.find((s) => s.side === side)?.displayName || "—";
const tableText = (m: DisplayMatch) => (m.isBye ? "BYE" : m.tableNumber == null ? "–" : String(m.tableNumber));
const byName = (a: string, b: string) => a.localeCompare(b, "en", { sensitivity: "base", numeric: true }) || (a < b ? -1 : a > b ? 1 : 0);

function scoreOf(m: DisplayMatch): string | null {
  if (m.isBye || m.status === "pending") return null;
  const wins = (side: number) => m.sides.find((s) => s.side === side)?.gameWins ?? 0;
  return `${wins(0)}–${wins(1)}${m.gameDraws > 0 ? `–${m.gameDraws}` : ""}`;
}

/** The round by table: tables in order, then the byes by name. */
export function pairingsByTable(matches: DisplayMatch[]): TableRow[] {
  const rows = matches.map((m) => ({
    table: tableText(m), a: sideName(m, 0), b: m.isBye ? null : sideName(m, 1), bye: m.isBye, score: scoreOf(m), n: m.tableNumber ?? Infinity,
  }));
  rows.sort((x, y) => Number(x.bye) - Number(y.bye) || (x.bye ? byName(x.a, y.a) : x.n - y.n || byName(x.a, y.a)));
  return rows.map(({ n: _n, ...row }) => row);
}

/** The round A–Z: one row per player with their table and opponent; a bye reads BYE. */
export function pairingsByPlayer(matches: DisplayMatch[]): PlayerRow[] {
  const rows: PlayerRow[] = [];
  for (const m of matches) {
    if (m.isBye) {
      rows.push({ name: sideName(m, 0), table: "BYE", opponent: null, bye: true });
      continue;
    }
    for (const side of [0, 1]) {
      rows.push({ name: sideName(m, side), table: tableText(m), opponent: sideName(m, 1 - side), bye: false });
    }
  }
  return rows.sort((x, y) => byName(x.name, y.name) || byName(x.table, y.table));
}

/** "9/16 in": matches with a result, of the round's matches; byes aren't matches. */
export function resultsCount(matches: DisplayMatch[]): { resultsIn: number; matches: number } {
  const real = matches.filter((m) => !m.isBye);
  return { resultsIn: real.filter((m) => m.status !== "pending").length, matches: real.length };
}

/* ── clock ─────────────────────────────────────────────────────────────── */

/** A round's timer as event_public gives it. */
export interface DisplayTimer {
  timerStatus: string;
  timerDurationSeconds: number;
  timerRemainingAtChange: number;
  timerLastStartedAt: string | null;
}

/** Seconds left on the round clock (negative once time is called), as every other clock in the app reads it. */
export function remainingSeconds(round: DisplayTimer, nowMs: number): number {
  if (round.timerStatus === "running" && round.timerLastStartedAt) {
    const started = new Date(round.timerLastStartedAt).getTime();
    if (!Number.isNaN(started)) return round.timerRemainingAtChange - Math.floor((nowMs - started) / 1000);
  }
  return round.timerRemainingAtChange;
}

/** Seconds into the round: what the clock has run, so a paused round stands still. */
export function elapsedSeconds(round: DisplayTimer, nowMs: number): number {
  return Math.max(0, round.timerDurationSeconds - remainingSeconds(round, nowMs));
}

/** "23:41"; past the end "−02:15" (as the round clock reads everywhere else). */
export function clockText(seconds: number): string {
  const abs = Math.abs(seconds);
  return `${seconds < 0 ? "−" : ""}${String(Math.floor(abs / 60)).padStart(2, "0")}:${String(abs % 60).padStart(2, "0")}`;
}

export type ClockState = "off" | "running" | "low" | "paused" | "over";

/**
 * The round clock for the display. `off`: a "Round timer off" event or no open round, no clock at all. `paused`
 * holds its time; `low` is the last 5 minutes; `over` from 00:00 on, counting up behind a minus.
 */
export function displayClock(round: DisplayTimer | null, nowMs: number, showClock: boolean): { text: string | null; state: ClockState } {
  if (!round || !showClock) return { text: null, state: "off" };
  const left = remainingSeconds(round, nowMs);
  const state: ClockState = round.timerStatus === "paused" ? "paused" : left <= 0 ? "over" : left <= 300 ? "low" : "running";
  return { text: clockText(left), state };
}

/** The words under or beside the clock: "Paused", "Time" once it's run out. */
export function clockWord(state: ClockState): string | null {
  return state === "paused" ? "Paused" : state === "over" ? "Time" : null;
}

/** The largest type (px) at which `text` fits a width × height box in the mono face (0.61 em a character). */
export function fitType(text: string, width: number, height: number): number {
  return Math.max(12, Math.floor(Math.min(height, width / (Math.max(1, text.length) * CHAR_EM))));
}

/* ── the address ───────────────────────────────────────────────────────── */

export const displayPath = (eventId: string, show: DisplayShow = "auto") => `/d/${eventId}${show === "auto" ? "" : `?show=${show}`}`;

/** "table-1.site/d/8f3c…": an address without its scheme, as it's read out or typed. */
export function bareAddress(url: string): string {
  return url.replace(/^https?:\/\//, "").replace(/\/$/, "");
}
