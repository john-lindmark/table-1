// Finding events, leagues, format boards and profile achievements (contract/public-events-leagues-2026-11-13.md §§ 1, 3,
// 4, 7): the wire types, every small rule and wording the three clients share, and the calls. Change a rule in
// testdata/leagues/make_cases.py first, then make this pass testdata/leagues/cases.json (leagues.test.ts).
//
// The server part may not be live: a call to a function the server doesn't have (PostgREST PGRST202, HTTP 404) is
// `isMissing`. Sections that are extras (the Events home's Find events, a profile's achievements, an event's About
// row) read through the `soft` helpers and simply don't draw; screens of their own show the error row with Try again.
// Nothing here is reported to Sentry.
import { isLibraryDemo } from "./libraryDemo";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";

/* ── format keys ─────────────────────────────────────────────────────── */

export const FORMAT_KEYS: { key: string; label: string }[] = [
  { key: "standard", label: "Standard" }, { key: "pioneer", label: "Pioneer" }, { key: "modern", label: "Modern" },
  { key: "legacy", label: "Legacy" }, { key: "vintage", label: "Vintage" }, { key: "pauper", label: "Pauper" },
  { key: "premodern", label: "Premodern" }, { key: "canadian_highlander", label: "Canadian Highlander" },
  { key: "limited", label: "Limited" }, { key: "cube", label: "Cube" }, { key: "other", label: "Other" },
];
const FORMAT_LABEL = new Map(FORMAT_KEYS.map((f) => [f.key, f.label]));
export const formatKeyLabel = (key: string | null | undefined) => FORMAT_LABEL.get(key ?? "") ?? "Other";
/** One board per format key except `other`. */
export const BOARD_KEYS = FORMAT_KEYS.filter((f) => f.key !== "other");

/* ── wire ────────────────────────────────────────────────────────────── */

/** The league an event is in, as find_events and event_about send it. */
export interface EventLeague {
  id?: string; slug?: string; name: string; season_id?: string; season?: string; multiplier?: number; final?: boolean;
}

export type FoundMe = "organizer" | "player" | "waitlisted" | null;

/** One of find_events' rows. */
export interface FoundEvent {
  event_id: string;
  name: string;
  format_key?: string | null;
  format_label?: string | null;
  set_name?: string | null;
  cube_name?: string | null;
  team_size?: number | null;
  status: string;
  current_round?: number | null;
  starts_at?: string | null;
  venue_name?: string | null;
  venue_address?: string | null;
  capacity?: number | null;
  top_cut?: number | null;
  visibility?: string | null;
  players?: number | null;
  organizer?: string | null;
  has_description?: boolean | null;
  km?: number | null;
  league?: EventLeague | null;
  me?: FoundMe;
}

/** event_about: what the event page adds. */
export interface EventAbout {
  event_id: string;
  description: string | null;
  venue_address: string | null;
  visibility: string | null;
  format_key: string | null;
  league: EventLeague | null;
  placed?: boolean;
}

export interface EventListing { description: string | null; venue_address: string | null; visibility: string }
/** Who can find it, as Create and Setup → Details say it. */
export type FindPick = "public" | "friends" | "private";
export const FIND_PICKS: { value: FindPick; label: string }[] = [
  { value: "public", label: "Public" }, { value: "friends", label: "Friends" }, { value: "private", label: "Private" },
];
/** A stored visibility as the three-way pick: `link_only`, `nearby` and invitation-only all read Private. */
export const findPickOf = (visibility: string | null | undefined): FindPick =>
  visibility === "public" ? "public" : visibility === "friends" ? "friends" : "private";
export const DESCRIPTION_MAX = 2000;
export const ADDRESS_MAX = 200;
/** "1,240 / 2,000". */
export const counter = (n: number, max: number) => `${n.toLocaleString("en-US")} / ${max.toLocaleString("en-US")}`;
/** Results here are public: a public event, or one in a league (the once-per-device sign-up notice). */
export const resultsPublic = (a: Pick<EventAbout, "visibility" | "league"> | null | undefined) =>
  !!a && (a.visibility === "public" || !!a.league);
export const PUBLIC_NOTICE =
  "Results in public events are public: standings, league points and format boards. You can hide yourself from the boards in Sharing.";

export interface PointsBracket { through: number; points: number }
export interface PointsRule { places: PointsBracket[]; participation: number; match_win: number }
export interface Qualify { winners: boolean; pass_down: boolean; top: number }
export type SeasonState = "upcoming" | "active" | "over";

export interface League {
  id: string; slug: string; name: string; description: string | null; region: string | null; link: string | null;
  archived: boolean; organizers: string[];
}
export interface SeasonRef { id: string; name: string; starts_on: string; ends_on: string; state: SeasonState }
export interface Season extends SeasonRef { points: PointsRule; best_n: number | null; qualify: Qualify; closed: boolean }
export interface LeagueEvent {
  event_id: string; name: string; format_label: string | null; format_key: string | null; starts_at: string | null;
  venue_name: string | null; status: string; multiplier: number; final: boolean; players: number; winner: string | null;
}
export interface StandingRow {
  rank: number; key: string; user_id?: string | null; name: string; points: number; events: number; wins: number;
  best: number | null; qualified: "winner" | "points" | null;
}
export type LeagueRole = "owner" | "organizer";
/** Who runs a league, with accounts: league_view sends it to the league's own organizers only. */
export interface LeagueMember { user_id: string; name: string; role: LeagueRole }
export type MemberAction = "make_owner" | "make_organizer" | "remove";
/** What the Organizers screen offers on a member: everything for an owner, nothing for anyone else. The server has
 *  the last word (a league keeps an owner). */
export function memberActions(viewer: LeagueRole | null | undefined, member: Pick<LeagueMember, "role">): MemberAction[] {
  if (viewer !== "owner") return [];
  return [member.role === "owner" ? "make_organizer" : "make_owner", "remove"];
}
export const MEMBER_ACTION_LABEL: Record<MemberAction, string> = { make_owner: "Make owner", make_organizer: "Make organizer", remove: "Remove" };
export const roleLabel = (r: LeagueRole) => (r === "owner" ? "Owner" : "Organizer");

export interface LeagueView {
  league: League;
  me: { role: LeagueRole | null; following: boolean; notify: boolean };
  /** Null (or missing, from a server before it) for everyone who doesn't run the league. */
  members?: LeagueMember[] | null;
  seasons: SeasonRef[];
  season: Season | null;
  events: LeagueEvent[];
  standings: StandingRow[];
  standings_count: number;
  my_row: StandingRow | null;
}
export interface LeaguePlayerEvent {
  event_id: string; name: string; format_label: string | null; starts_at: string | null; place: number; players: number;
  match_wins: number; points: number; counted: boolean;
}
export interface LeaguePlayer { player: StandingRow; events: LeaguePlayerEvent[] }
export interface LeagueCard {
  id: string; slug: string; name: string; region: string | null; season: string | null;
  next_event: { event_id: string; name: string; starts_at: string | null; format_label: string | null } | null;
  role?: "owner" | "organizer"; notify?: boolean;
}
export interface LeaguesHome { mine: LeagueCard[]; following: LeagueCard[]; found: LeagueCard[] }
export interface LeagueFollow { following: boolean; notify: boolean }

export interface BoardMe {
  rating: number; matches: number; wins: number; losses: number; draws: number; events: number; rank: number | null; to_go: number;
}
export interface Board { board: string; label: string; players: number; me: BoardMe | null }
export interface Boards { listed: boolean; boards: Board[] }
export interface BoardRow {
  rank: number; user_id?: string | null; name: string; avatar_url?: string | null; rating: number; matches: number;
  wins: number; losses: number; draws: number; events: number;
}
export interface Leaderboard { board: string; label: string; count: number; me: BoardMe | null; rows: BoardRow[] }

export interface LeagueAchievement {
  kind: "league"; league_id: string; league_slug: string; league_name: string; season_id: string; season_name: string;
  state: SeasonState; rank: number | null; players: number; points: number; wins: number;
  qualified: "winner" | "points" | null; champion: boolean;
}
export interface BoardAchievement {
  kind: "board"; board: string; label: string; rank: number | null; rating: number; matches: number; to_go: number; players: number;
}
export type Achievement = LeagueAchievement | BoardAchievement;
export type AchievementsVisibility = "private" | "friends" | "public";
export interface Achievements { items: Achievement[]; visibility?: AchievementsVisibility; listed?: boolean }

/* ── points and qualification ────────────────────────────────────────── */

export const PRESETS: Record<"places" | "match_wins", PointsRule> = {
  places: {
    places: [{ through: 1, points: 12 }, { through: 2, points: 10 }, { through: 4, points: 8 }, { through: 8, points: 6 },
             { through: 16, points: 3 }],
    participation: 1, match_win: 0,
  },
  match_wins: { places: [], participation: 1, match_win: 1 },
};
export type Preset = "places" | "match_wins" | "custom";
const sameRule = (a: PointsRule, b: PointsRule) =>
  (a.participation ?? 0) === b.participation && (a.match_win ?? 0) === b.match_win && (a.places ?? []).length === b.places.length &&
  (a.places ?? []).every((x, i) => x.through === b.places[i].through && x.points === b.places[i].points);
/** Which preset a rule is, for the season editor and `league_season_saved {preset}`. */
export const presetOf = (rule: PointsRule): Preset =>
  sameRule(rule, PRESETS.places) ? "places" : sameRule(rule, PRESETS.match_wins) ? "match_wins" : "custom";

export function ordinal(n: number): string {
  if (n % 100 >= 10 && n % 100 <= 20) return `${n}th`;
  return `${n}${({ 1: "st", 2: "nd", 3: "rd" } as Record<number, string>)[n % 10] ?? "th"}`;
}

/** "1st 12 · 2nd 10 · Top 4 8 · Top 8 6 · Top 16 3 · Others 1". A bracket one past the last is a single place. */
export function pointsWords(rule: Partial<PointsRule>): string {
  const parts: string[] = [];
  let last = 0;
  for (const b of rule.places ?? []) {
    parts.push(`${b.through === last + 1 ? ordinal(b.through) : `Top ${b.through}`} ${b.points}`);
    last = b.through;
  }
  if ((rule.participation ?? 0) > 0) parts.push(`${parts.length ? "Others" : "Playing"} ${rule.participation}`);
  if ((rule.match_win ?? 0) > 0) parts.push(`Match win ${rule.match_win}`);
  return parts.join(" · ");
}

/** What a finish earns before match wins and the multiplier: the first bracket whose `through` reaches the place. */
export function placePoints(rule: Partial<PointsRule>, place: number): number {
  for (const b of rule.places ?? []) if (b.through >= place) return b.points;
  return rule.participation ?? 0;
}

export function qualifyWords(q: Partial<Qualify>): string {
  const top = Math.trunc(q.top ?? 0);
  if (q.winners && top > 0) return `Event winners and the top ${top} on points`;
  if (q.winners) return "Event winners";
  return top > 0 ? `The top ${top} on points` : "";
}

/** "1×", "1.5×". */
export const multiplierText = (m: number) => `${Number.isInteger(m) ? m : m.toFixed(1)}×`;
export const MULTIPLIERS = [1, 1.5, 2, 3];

/* ── found events ────────────────────────────────────────────────────── */

/** The small label above a found event's name: the league's name, else FRIENDS for a friends event. */
export function rowLabel(e: { league?: { name: string } | null; visibility?: string | null }): string | null {
  if (e.league) return e.league.name.toUpperCase();
  return e.visibility === "friends" ? "FRIENDS" : null;
}

/** The data line under a found event. `when` is the date piece, formatted in the device's zone (`whenText`). */
export function eventLine(
  e: { status: string; current_round?: number | null; format_label?: string | null; venue_name?: string | null;
       capacity?: number | null; players?: number | null; km?: number | null },
  when: string | null,
): string {
  const round = e.current_round ?? 0;
  const running = (e.status === "seated" || e.status === "in_progress") && round > 0;
  const parts: (string | null)[] = [running ? `NOW · ROUND ${round}` : when, (e.format_label ?? "").toUpperCase()];
  if (e.venue_name) parts.push(e.venue_name.toUpperCase());
  if (e.capacity) parts.push(`${e.players ?? 0}/${e.capacity}`);
  if (e.km != null) parts.push(`${e.km} KM`);
  return parts.filter(Boolean).join(" · ");
}

const clean = (s: string) => s.toUpperCase().replace(/\./g, "").replace(/,/g, "");

/** "SUN 29 MAR · 10:00" in the device's zone (or `zone`, for tests). */
export function whenText(iso: string | null | undefined, zone?: string, locale?: string): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const parts = new Intl.DateTimeFormat(locale, { weekday: "short", day: "numeric", month: "short", timeZone: zone }).formatToParts(d);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  const time = new Intl.DateTimeFormat(locale, { hour: "numeric", minute: "2-digit", timeZone: zone }).format(d);
  return `${clean(`${get("weekday")} ${get("day")} ${get("month")}`)} · ${clean(time)}`;
}

/** "29 MAR 2026" for a season's or a finished event's day. A bare date ("2026-03-29") is that calendar day anywhere. */
export function dateText(iso: string | null | undefined, zone?: string, locale?: string): string | null {
  if (!iso) return null;
  const bare = /^\d{4}-\d{2}-\d{2}$/.test(iso);
  const d = new Date(bare ? `${iso}T00:00:00Z` : iso);
  if (Number.isNaN(d.getTime())) return null;
  const parts = new Intl.DateTimeFormat(locale, { day: "numeric", month: "short", year: "numeric", timeZone: bare ? "UTC" : zone }).formatToParts(d);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return clean(`${get("day")} ${get("month")} ${get("year")}`);
}

/* ── the When windows ────────────────────────────────────────────────── */

export type WhenPick = "any" | "today" | "weekend" | "week" | "month";
export const WHEN_PICKS: { value: WhenPick; label: string }[] = [
  { value: "any", label: "Any time" }, { value: "today", label: "Today" }, { value: "weekend", label: "This weekend" },
  { value: "week", label: "This week" }, { value: "month", label: "This month" },
];
export const KM_PICKS = [25, 50, 100, 250];

/** The calendar day and weekday (Monday = 0) an instant falls on in a zone. */
function dayIn(zone: string, at: Date): { y: number; m: number; d: number; weekday: number } {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: zone, year: "numeric", month: "numeric", day: "numeric", weekday: "short" }).formatToParts(at);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return { y: Number(get("year")), m: Number(get("month")), d: Number(get("day")),
           weekday: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].indexOf(get("weekday")) };
}

/** The zone's offset from UTC (ms) at an instant. */
function offsetIn(zone: string, at: number): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: zone, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", second: "numeric",
  }).formatToParts(new Date(at));
  const n = (t: string) => Number(parts.find((p) => p.type === t)?.value ?? 0);
  return Date.UTC(n("year"), n("month") - 1, n("day"), n("hour"), n("minute"), n("second")) - Math.floor(at / 1000) * 1000;
}

/** Local midnight of a calendar day (days may overflow the month) as an instant, right across a clock change. */
function midnightIn(zone: string, y: number, m: number, d: number): Date {
  const wall = Date.UTC(y, m - 1, d);
  let t = wall - offsetIn(zone, wall);
  t = wall - offsetIn(zone, t);
  return new Date(t);
}

const isoZ = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, "Z");

/** [from, to) as UTC instants for a When pick, in the device's zone. Weeks start on Monday. Null for Any time. */
export function whenWindow(pick: string, now: Date, zone: string): [string, string] | null {
  const { y, m, d, weekday } = dayIn(zone, now);
  const at = (plus: number) => midnightIn(zone, y, m, d + plus);
  const nextMonday = at(7 - weekday);
  let start: Date, end: Date;
  if (pick === "today") [start, end] = [at(0), at(1)];
  else if (pick === "weekend") [start, end] = [weekday >= 5 ? at(0) : at(5 - weekday), nextMonday];
  else if (pick === "week") [start, end] = [at(0), nextMonday];
  else if (pick === "month") [start, end] = [at(0), midnightIn(zone, y, m + 1, 1)];
  else return null;
  return [isoZ(start), isoZ(end)];
}

export const deviceZone = () => {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
  } catch {
    return "UTC";
  }
};

/* ── filters ─────────────────────────────────────────────────────────── */

export type FindScope = "all" | "public" | "friends";
/** The Find events picks (kept per device: `find.formats`, `find.km`, `find.when`, `find.more`). */
export interface FindFilters {
  formats: string[];
  km: number | null;
  when: WhenPick;
  scope: FindScope;
  team: boolean;
  league: boolean;
  open: boolean;
}
export const NO_FILTERS: FindFilters = { formats: [], km: null, when: "any", scope: "all", team: false, league: false, open: false };
export const isFiltered = (f: FindFilters, q = "") =>
  f.formats.length > 0 || f.km != null || f.when !== "any" || f.scope !== "all" || f.team || f.league || f.open || q.trim().length >= 2;

/** What each filter cell reads. */
export function filterLabels(f: Partial<FindFilters>): { format: string; where: string; when: string; more: string } {
  const formats = f.formats ?? [];
  const more = [f.team, f.league, f.open].filter(Boolean).length + ((f.scope ?? "all") !== "all" ? 1 : 0);
  return {
    format: !formats.length ? "Any format" : formats.length === 1 ? formatKeyLabel(formats[0]) : `${formats.length} formats`,
    where: f.km ? `${f.km} km` : "Everywhere",
    when: WHEN_PICKS.find((w) => w.value === f.when && w.value !== "any")?.label ?? "Any time",
    more: more ? `More · ${more}` : "More",
  };
}

/** find_events' p_filters. A distance only counts with a place to measure from (never stored). */
export function filtersWire(f: FindFilters, opts: { now?: Date; zone?: string; here?: { lat: number; lng: number } | null; q?: string } = {}): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (f.formats.length) out.formats = f.formats;
  if (opts.here) {
    out.lat = opts.here.lat;
    out.lng = opts.here.lng;
    if (f.km) out.km = f.km;
  }
  const w = whenWindow(f.when, opts.now ?? new Date(), opts.zone ?? deviceZone());
  if (w) [out.from, out.to] = w;
  const q = (opts.q ?? "").trim();
  if (q.length >= 2) out.q = q;
  if (f.team) out.team = true;
  if (f.league) out.league = true;
  if (f.open) out.open = true;
  if (f.scope !== "all") out.scope = f.scope;
  return out;
}

const PICK_KEY = "table1.find.";
function stored(key: string): string | null {
  try {
    return localStorage.getItem(PICK_KEY + key);
  } catch {
    return null;
  }
}
/** The picks this device last made; anything unreadable is its default. */
export function loadFindFilters(read: (key: string) => string | null = stored): FindFilters {
  const f: FindFilters = { ...NO_FILTERS };
  const list = (key: string): string[] => {
    try {
      const v = JSON.parse(read(key) ?? "[]");
      return Array.isArray(v) ? v.filter((x) => typeof x === "string") : [];
    } catch {
      return [];
    }
  };
  const formats = list("formats");
  f.formats = FORMAT_KEYS.map((k) => k.key).filter((k) => formats.includes(k));
  const km = Number(read("km"));
  f.km = KM_PICKS.includes(km) ? km : null;
  const when = read("when");
  f.when = WHEN_PICKS.some((w) => w.value === when) ? (when as WhenPick) : "any";
  const more = list("more");
  f.team = more.includes("team");
  f.league = more.includes("league");
  f.open = more.includes("open");
  f.scope = more.includes("public") ? "public" : more.includes("friends") ? "friends" : "all";
  return f;
}
export function saveFindFilters(f: FindFilters) {
  try {
    localStorage.setItem(PICK_KEY + "formats", JSON.stringify(f.formats));
    localStorage.setItem(PICK_KEY + "km", String(f.km ?? 0));
    localStorage.setItem(PICK_KEY + "when", f.when);
    localStorage.setItem(PICK_KEY + "more", JSON.stringify(
      [f.team && "team", f.league && "league", f.open && "open", f.scope !== "all" && f.scope].filter(Boolean)));
  } catch { /* private window: the picks last for this page */ }
}

/** Where a found event opens: the organizer's and a player's own screens, else the event page. */
export const foundEventPath = (e: Pick<FoundEvent, "event_id" | "me">) =>
  e.me === "organizer" ? `/e/${e.event_id}` : e.me === "player" ? `/p/${e.event_id}` : `/s/${e.event_id}`;

/** The "Results in public events are public" notice shows once per device. */
const NOTICE_KEY = "table1.publicResultsNotice";
export function publicNoticeDue(): boolean {
  try {
    return localStorage.getItem(NOTICE_KEY) !== "1";
  } catch {
    return false;
  }
}
export function publicNoticeSeen() {
  try {
    localStorage.setItem(NOTICE_KEY, "1");
  } catch { /* private window */ }
}

/* ── boards, leagues, achievements: wording ──────────────────────────── */

/** "124 LISTED · YOU 1612 · #14"; "… · 4 TO GO" before you're listed; nothing about you with no rated match. */
export function boardLine(b: { players: number; me?: Pick<BoardMe, "rating" | "rank" | "to_go"> | null }): string {
  const parts = [`${b.players} LISTED`];
  if (b.me) {
    parts.push(`YOU ${b.me.rating}`);
    parts.push(b.me.rank ? `#${b.me.rank}` : (b.me.to_go ?? 0) > 0 ? `${b.me.to_go} TO GO` : "NOT LISTED");
  }
  return parts.join(" · ");
}

/** "8-4-0". */
export const recordText = (r: { wins: number; losses: number; draws: number }) => `${r.wins}-${r.losses}-${r.draws}`;

/** "2026 · DENVER, COLORADO · NEXT MODERN OPEN". */
export function leagueLine(c: { season?: string | null; region?: string | null; next_event?: { name: string } | null }): string {
  return [(c.season ?? "").toUpperCase(), (c.region ?? "").toUpperCase(), c.next_event ? `NEXT ${c.next_event.name.toUpperCase()}` : ""]
    .filter(Boolean).join(" · ");
}

/** A league event's data line: upcoming "SUN 29 MAR · 10:00 · MODERN · MEH GAMES", finished "29 MAR 2026 · MODERN · BEA WON". */
export function leagueEventLine(e: LeagueEvent, zone?: string): string {
  const done = e.status === "completed" || e.status === "archived";
  const running = (e.status === "in_progress" || e.status === "seated") && !done;
  return [
    done ? dateText(e.starts_at, zone) : running && !e.starts_at ? "NOW" : whenText(e.starts_at, zone),
    (e.format_label ?? "").toUpperCase(),
    e.final ? "FINAL" : e.multiplier && e.multiplier !== 1 ? multiplierText(e.multiplier) : "",
    done ? (e.winner ? `${e.winner.toUpperCase()} WON` : "") : (e.venue_name ?? "").toUpperCase(),
  ].filter(Boolean).join(" · ");
}

/** A season's events as the league page lists them: upcoming soonest first, then finished newest first. */
export function orderedLeagueEvents(events: LeagueEvent[]): { upcoming: LeagueEvent[]; finished: LeagueEvent[] } {
  const done = (e: LeagueEvent) => e.status === "completed" || e.status === "archived";
  const at = (e: LeagueEvent) => (e.starts_at ? new Date(e.starts_at).getTime() : 0);
  return {
    upcoming: events.filter((e) => !done(e)).sort((a, b) => at(a) - at(b)),
    finished: events.filter(done).sort((a, b) => at(b) - at(a)),
  };
}

/** A player's finish in one event: "3RD OF 24 · MODERN · 29 MAR 2026". */
export const finishLine = (e: Pick<LeaguePlayerEvent, "place" | "players" | "format_label" | "starts_at">, zone?: string) =>
  [`${ordinal(e.place).toUpperCase()}${e.players ? ` OF ${e.players}` : ""}`, (e.format_label ?? "").toUpperCase(), dateText(e.starts_at, zone)]
    .filter(Boolean).join(" · ");

/** A standings row's data line: "5 EVENTS · 2 WINS · BEST 1ST". */
export const standingLine = (r: Pick<StandingRow, "events" | "wins" | "best">) =>
  [`${r.events} ${r.events === 1 ? "EVENT" : "EVENTS"}`, r.wins > 0 ? `${r.wins} ${r.wins === 1 ? "WIN" : "WINS"}` : "",
   r.best ? `BEST ${ordinal(r.best).toUpperCase()}` : ""].filter(Boolean).join(" · ");

/** "1 JAN 2026 – 31 DEC 2026 · ACTIVE". */
export const seasonLine = (s: SeasonRef) =>
  `${dateText(s.starts_on)} – ${dateText(s.ends_on)} · ${s.state === "active" ? "RUNNING" : s.state.toUpperCase()}`;

/** A profile achievement as a small tile: a code, a label under it, and whether it takes the accent. */
export function achievementText(i: Partial<LeagueAchievement> | Partial<BoardAchievement>): { code: string; label: string; accent: boolean } {
  if (i.kind === "board") {
    const b = i as Partial<BoardAchievement>;
    if (b.rank) return { code: `#${b.rank}`, label: b.label ?? "", accent: b.rank === 1 };
    return { code: String(b.rating ?? ""), label: b.label ?? "", accent: false };
  }
  const l = i as Partial<LeagueAchievement>;
  const label = `${l.league_name} · ${l.season_name}`;
  const rank = l.rank ?? null, over = l.state === "over";
  if (l.champion) return { code: "CHAMPION", label, accent: true };
  if (over && rank && rank <= 8) return { code: rank === 1 ? "1ST" : rank <= 4 ? "TOP 4" : "TOP 8", label, accent: rank === 1 };
  if (l.qualified) return { code: "QUALIFIED", label, accent: false };
  if (rank && rank <= 8) return { code: `#${rank}`, label, accent: false };
  return { code: l.wins === 1 ? "1 WIN" : `${l.wins ?? 0} WINS`, label, accent: false };
}

/** Where an achievement tile opens: the league on that season, or the board. */
export const achievementPath = (i: Achievement) =>
  i.kind === "board" ? `/boards/${i.board}` : `/league/${i.league_slug}?season=${i.season_id}`;

/* ── calls ───────────────────────────────────────────────────────────── */

/** The function isn't on the server (PostgREST PGRST202, HTTP 404): the section hides, nothing is reported. */
export function isMissing(e: unknown): boolean {
  const o = e as { code?: unknown; status?: unknown; message?: unknown } | null;
  // PGRST202: not in the schema cache; 42883: Postgres has no such function. A function's own answer (P0002 for a
  // league that isn't available, 42501, 22023) is never "missing", whatever status it travels with.
  if (o?.code === "PGRST202" || o?.code === "42883") return true;
  if (typeof o?.code === "string" && o.code) return false;
  return o?.status === 404 || (typeof o?.message === "string" && /could not find the function/i.test(o.message));
}

/** What a league, board or Find screen says when its call fails. */
export function leaguesError(e: unknown): string {
  if (isMissing(e)) return "This isn't available yet.";
  if (e instanceof Error) return e.message;
  const m = (e as { message?: unknown } | null)?.message;
  return typeof m === "string" && m ? m : "Couldn't load. Check your connection.";
}

async function rpc<T>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error, status } = await supabase.rpc(fn, args);
  if (error) throw Object.assign(error, { status });
  return data as T;
}

/** Dev server, `?demo`: every call answers from stand-in data (leaguesDemo.ts), no account or server. Production
 *  builds drop it. */
const demo = () => (import.meta.env.DEV && isLibraryDemo() ? import("./leaguesDemo") : null);
export const leaguesDemoOn = () => import.meta.env.DEV && isLibraryDemo();
/** A path inside the demo keeps `?demo`, so the next screen's taps (a person's profile) stay in it. */
export const demoPath = (path: string) => (leaguesDemoOn() && !/[?&]demo\b/.test(path) ? `${path}${path.includes("?") ? "&" : "?"}demo` : path);

export async function findEvents(filters: Record<string, unknown> = {}, limit = 50): Promise<FoundEvent[]> {
  const d = await demo();
  if (d) return d.findEvents(filters, limit);
  return (await rpc<FoundEvent[] | null>("find_events", { p_filters: filters, p_limit: limit })) ?? [];
}

/** An event's description, address and league; null when the event has none of it to show or the call fails. */
export async function eventAbout(eventId: string, token?: string | null): Promise<EventAbout | null> {
  try {
    const d = await demo();
    if (d) return d.eventAbout(eventId);
    return await rpc<EventAbout>("event_about", token ? { p_event_id: eventId, p_token: token } : { p_event_id: eventId });
  } catch {
    return null;
  }
}

/** The same read for Setup → Details, which must tell "the server has no listings yet" (keep the older choices only)
 *  from "couldn't read it". */
export async function eventAboutOrMissing(eventId: string): Promise<EventAbout | "missing" | null> {
  try {
    const d = await demo();
    if (d) return d.eventAbout(eventId) ?? { event_id: eventId, description: null, venue_address: null, visibility: null, format_key: null, league: null };
    return await rpc<EventAbout>("event_about", { p_event_id: eventId });
  } catch (e) {
    return isMissing(e) ? "missing" : null;
  }
}

/** Whether the server lists events at all yet: Create offers Public | Friends | Private only when it does. */
export async function listingsLive(): Promise<boolean> {
  try {
    await findEvents({}, 1);
    return true;
  } catch (e) {
    return !isMissing(e);
  }
}

export interface ListingPatch { description?: string | null; venue_address?: string | null; find?: FindPick; lat?: number; lng?: number }
export async function eventListingSet(eventId: string, patch: ListingPatch): Promise<EventListing> {
  const d = await demo();
  const r = d ? d.eventListingSet(eventId, patch) : await rpc<EventListing>("event_listing_set", { p_event_id: eventId, p_patch: patch });
  capture("event_listing_saved", { find: patch.find ?? "kept", description: !!(patch.description ?? "").trim() });
  return r;
}

export async function leagueView(league: string, seasonId?: string | null): Promise<LeagueView> {
  const d = await demo();
  if (d) return d.leagueView(league, seasonId ?? null);
  return rpc<LeagueView>("league_view", seasonId ? { p_league: league, p_season_id: seasonId } : { p_league: league });
}

export async function leagueStandings(seasonId: string, after = 0, limit = 100): Promise<StandingRow[]> {
  const d = await demo();
  if (d) return d.leagueStandings(seasonId, after, limit);
  return (await rpc<StandingRow[] | null>("league_standings", { p_season_id: seasonId, p_after: after, p_limit: limit })) ?? [];
}

export async function leaguePlayer(seasonId: string, key: string): Promise<LeaguePlayer> {
  const d = await demo();
  if (d) return d.leaguePlayer(seasonId, key);
  return rpc<LeaguePlayer>("league_player", { p_season_id: seasonId, p_key: key });
}

export async function leaguesHome(query?: string): Promise<LeaguesHome> {
  const d = await demo();
  const q = (query ?? "").trim();
  const r = d ? d.leaguesHome(q) : await rpc<Partial<LeaguesHome>>("leagues_home", q.length >= 2 ? { p_query: q } : {});
  return { mine: r.mine ?? [], following: r.following ?? [], found: r.found ?? [] };
}

export async function leagueFollowSet(leagueId: string, follow: boolean, notify: boolean | null = null): Promise<LeagueFollow> {
  const d = await demo();
  const r = d ? d.leagueFollowSet(leagueId, follow, notify)
    : await rpc<LeagueFollow>("league_follow_set", { p_league_id: leagueId, p_follow: follow, p_notify: notify });
  if (notify == null) capture("league_followed", { following: r.following });
  return r;
}

export async function leagueCreate(input: { name: string; description?: string; region?: string; link?: string }): Promise<League> {
  const d = await demo();
  const text = (s?: string) => (s ?? "").trim() || null;
  const r = d ? d.leagueCreate(input) : await rpc<League>("league_create", {
    p_name: input.name.trim(), p_description: text(input.description), p_region: text(input.region), p_link: text(input.link),
  });
  capture("league_created");
  return r;
}

export interface LeaguePatch { name?: string; description?: string | null; region?: string | null; link?: string | null; archived?: boolean }
export async function leagueUpdate(leagueId: string, patch: LeaguePatch): Promise<League> {
  const d = await demo();
  return d ? d.leagueUpdate(leagueId, patch) : rpc<League>("league_update", { p_league_id: leagueId, p_patch: patch });
}

export async function leagueMemberSet(leagueId: string, userId: string, role: LeagueRole | null): Promise<void> {
  const d = await demo();
  if (d) return d.leagueMemberSet(leagueId, userId, role);
  await rpc<unknown>("league_member_set", { p_league_id: leagueId, p_user_id: userId, p_role: role });
}

export interface SeasonPatch {
  name?: string; starts_on?: string; ends_on?: string; points?: PointsRule; best_n?: number | null; qualify?: Qualify; closed?: boolean;
}
export async function leagueSeasonSet(leagueId: string, seasonId: string | null, patch: SeasonPatch): Promise<Season> {
  const d = await demo();
  const r = d ? d.leagueSeasonSet(leagueId, seasonId, patch)
    : await rpc<Season>("league_season_set", { p_league_id: leagueId, p_season_id: seasonId, p_patch: patch });
  if (patch.points) capture("league_season_saved", { preset: presetOf(patch.points) });
  return r;
}

export async function leagueEventSet(eventId: string, seasonId: string | null, multiplier = 1, final = false): Promise<{ league: EventLeague | null }> {
  const d = await demo();
  const r = d ? d.leagueEventSet(eventId, seasonId, multiplier, final)
    : await rpc<{ league: EventLeague | null }>("league_event_set", { p_event_id: eventId, p_season_id: seasonId, p_multiplier: multiplier, p_final: final });
  capture("league_event_set", { final, multiplier, removed: seasonId == null });
  return r;
}

export async function formatBoards(): Promise<Boards> {
  const d = await demo();
  const r = d ? d.formatBoards() : await rpc<Partial<Boards>>("format_boards");
  return { listed: !!r.listed, boards: r.boards ?? [] };
}

export async function formatLeaderboard(board: string, after = 0, limit = 100): Promise<Leaderboard> {
  const d = await demo();
  if (d) return d.formatLeaderboard(board, after, limit);
  const r = await rpc<Leaderboard>("format_leaderboard", { p_board: board, p_after: after, p_limit: limit });
  return { ...r, rows: r.rows ?? [] };
}

export async function leaderboardsListedSet(listed: boolean): Promise<{ listed: boolean }> {
  const d = await demo();
  const r = d ? d.leaderboardsListedSet(listed) : await rpc<{ listed: boolean }>("leaderboards_listed_set", { p_listed: listed });
  capture("leaderboards_listed", { listed: r.listed });
  return r;
}

/** A profile's achievements; a failed or missing call (the server part isn't live yet) reads as none. */
export async function profileAchievements(userId: string): Promise<Achievements | null> {
  try {
    const d = await demo();
    const r = d ? d.profileAchievements(userId) : await rpc<Achievements>("profile_achievements", { p_user_id: userId });
    return { ...r, items: r?.items ?? [] };
  } catch {
    return null;
  }
}

export async function achievementsVisibilitySet(visibility: AchievementsVisibility): Promise<{ visibility: AchievementsVisibility }> {
  const d = await demo();
  const r = d ? d.achievementsVisibilitySet(visibility)
    : await rpc<{ visibility: AchievementsVisibility }>("achievements_visibility_set", { p_visibility: visibility });
  capture("achievements_visibility", { visibility: r.visibility });
  return r;
}
