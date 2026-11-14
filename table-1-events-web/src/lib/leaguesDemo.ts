// Dev server only (`?demo`): finding events, a league, format boards and achievements on stand-in data, so every new
// screen opens without an account or a server (contract/public-events-leagues-2026-11-13.md). The league is shaped
// like a regional series: a 12-month season, placement points 12/10/8/6/3/1, winners qualify for the final and the
// top 10 on points join them. Standings, qualification and a player's season are worked out here by the contract's
// rules from made-up finishes; nobody here is a real person. Changes (follow, new league, a season) stay in memory.
import type { PublicEvent } from "./api";
import {
  BOARD_KEYS, PRESETS, formatKeyLabel, placePoints,
  type Achievement, type Achievements, type AchievementsVisibility, type Board, type BoardMe, type BoardRow, type Boards, type EventAbout,
  type EventLeague, type EventListing, type FoundEvent, type League, type LeagueCard, type LeagueEvent, type LeagueFollow, type LeaguePatch,
  type LeaguePlayer, type LeaguePlayerEvent, type LeagueView, type Leaderboard, type LeaguesHome, type ListingPatch, type PointsRule, type Qualify,
  type Season, type SeasonPatch, type SeasonState, type StandingRow,
} from "./leagues";

/** The Library demo's account id (collection.ts DEMO_USER), spelled here so this file stays free of the Library. */
const DEMO_USER = "demo";
const uid = (n: number) => `d0000000-0000-0000-0000-0000000f${String(n).padStart(4, "0")}`;
/** The demo account, and the friends-demo people who have profiles (`/u/<id>?demo`). */
const ME = { id: DEMO_USER, name: "Sam Reyes" };
const POOL: { name: string; id: string | null }[] = [
  { name: "Mara Quinn", id: uid(1) }, { name: "Theo Vance", id: uid(2) }, { name: "Ines Ruiz", id: uid(3) }, { name: "Sam Okafor", id: uid(4) },
  { name: "Lee Park", id: uid(5) }, { name: "Kai Brandt", id: uid(6) }, { name: ME.name, id: ME.id },
  ...["Bea Lindqvist", "Cy Moreau", "Dee Zhou", "Eli Varga", "Fen Adeyemi", "Gus Novak", "Hal Sato", "Ivy Bianchi", "Jo Weber", "Kit Aldana",
      "Lu Fischer", "Max Berg", "Nia Alvarez", "Oz Natarajan", "Pia Holm", "Quin Abara", "Rae Castell", "Sol Imani", "Tam Okoye", "Uma Petrov",
      "Vic Lund", "Wes Tanaka", "Xan Ferro", "Yun Calder", "Zed Marsh"].map((name) => ({ name, id: null as string | null })),
];
const keyOf = (p: { name: string; id: string | null }) => p.id ?? `g:${p.name.toLowerCase().replace(/\s+/g, " ")}`;

/** A small seeded generator, so the demo reads the same on every load. */
function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const DAY = 86_400_000;
const now = Date.now();
/** A day `days` from today at `hour` local time, as an instant. */
function at(days: number, hour = 10, minute = 0): string {
  const d = new Date(now + days * DAY);
  d.setHours(hour, minute, 0, 0);
  return d.toISOString();
}

interface Placement { key: string; userId: string | null; name: string; place: number; matchWins: number }
interface DemoEvent extends LeagueEvent { placements: Placement[]; seasonId: string; leagueId: string }
interface DemoSeason { id: string; leagueId: string; name: string; starts_on: string; ends_on: string; points: PointsRule; best_n: number | null;
  qualify: Qualify; closed: boolean }
interface DemoLeague extends League { members: { userId: string; name: string; role: "owner" | "organizer" }[]; following: boolean; notify: boolean }

const MMS = "d0000000-0000-0000-0000-00000001ea01";
const leagues: DemoLeague[] = [
  { id: MMS, slug: "the-mountain-magic-series", name: "The Mountain Magic Series", region: "Denver, Colorado",
    description: "Open events up and down the Front Range, one a month, in a different format each time.\n\nWin an event and you're in the final in December. The top 10 on points join the winners.\nhttps://example.com/mountain-magic",
    link: "https://example.com/mountain-magic", archived: false, organizers: ["Ines Ruiz", "Kai Brandt"],
    members: [{ userId: uid(3), name: "Ines Ruiz", role: "owner" }, { userId: uid(6), name: "Kai Brandt", role: "organizer" }],
    following: true, notify: true },
  { id: "d0000000-0000-0000-0000-00000001ea02", slug: "harbor-city-cube-league", name: "Harbor City Cube League", region: "Baltimore, Maryland",
    description: "Cube drafts every other Thursday. A point a match win, a point to play.", link: null, archived: false, organizers: ["Lee Park", ME.name],
    // The demo account helps run this one without owning it: its Organizers screen is read-only.
    members: [{ userId: uid(5), name: "Lee Park", role: "owner" }, { userId: ME.id, name: ME.name, role: "organizer" }], following: false, notify: false },
  { id: "d0000000-0000-0000-0000-00000001ea03", slug: "kitchen-table-pauper", name: "Kitchen Table Pauper", region: null,
    description: null, link: null, archived: false, organizers: [ME.name, "Theo Vance"],
    members: [{ userId: ME.id, name: ME.name, role: "owner" }, { userId: uid(2), name: "Theo Vance", role: "organizer" }], following: false, notify: false },
];
const year = new Date(now).getFullYear();
const S26 = "d0000000-0000-0000-0000-00000005ea26", S25 = "d0000000-0000-0000-0000-00000005ea25";
const seasons: DemoSeason[] = [
  { id: S26, leagueId: MMS, name: String(year), starts_on: `${year}-01-01`, ends_on: `${year}-12-31`, points: PRESETS.places, best_n: null,
    qualify: { winners: true, pass_down: true, top: 10 }, closed: false },
  { id: S25, leagueId: MMS, name: String(year - 1), starts_on: `${year - 1}-01-01`, ends_on: `${year - 1}-12-31`, points: PRESETS.places, best_n: 6,
    qualify: { winners: true, pass_down: true, top: 10 }, closed: true },
  { id: "d0000000-0000-0000-0000-00000005ea31", leagueId: leagues[1].id, name: "Fall", starts_on: `${year}-09-01`, ends_on: `${year}-12-15`,
    points: PRESETS.match_wins, best_n: null, qualify: { winners: false, pass_down: false, top: 8 }, closed: false },
  { id: "d0000000-0000-0000-0000-00000005ea41", leagueId: leagues[2].id, name: "Season 1", starts_on: `${year}-10-01`, ends_on: `${year + 1}-03-31`,
    points: PRESETS.match_wins, best_n: null, qualify: { winners: false, pass_down: false, top: 4 }, closed: false },
];

const FORMATS: [string, string][] = [["modern", "Modern"], ["legacy", "Legacy"], ["pioneer", "Pioneer"], ["standard", "Standard"], ["pauper", "Pauper"]];
const VENUES = ["MeH Games", "Mythic Games", "Level 7 Games", "Black & Read", "The Wizard's Chest"];
const events: DemoEvent[] = [];

/** A finished event's places: a seeded shuffle of `n` people from the pool, stronger players a little likelier on top. */
function placements(seed: number, n: number, must: string[] = []): Placement[] {
  const r = rng(seed);
  const scored = POOL.map((p, i) => ({ p, s: r() + (must.includes(p.name) ? 0.2 : 0) - i * 0.006 }));
  const inIt = scored.sort((a, b) => b.s - a.s).slice(0, n);
  const order = inIt.map((x) => ({ p: x.p, s: r() * 0.75 + x.s * 0.4 })).sort((a, b) => b.s - a.s);
  return order.map(({ p }, i) => ({
    key: keyOf(p), userId: p.id, name: p.name, place: i + 1,
    matchWins: i === 0 ? 6 : i < 2 ? 5 : i < 4 ? 4 : i < 8 ? 3 : i < 16 ? 2 : 1,
  }));
}

function finished(seasonId: string, n: number, monthsAgo: number, seed: number, over: Partial<LeagueEvent> = {}): DemoEvent {
  const [key, label] = FORMATS[n % FORMATS.length];
  const d = new Date(now);
  d.setMonth(d.getMonth() - monthsAgo, 8 + ((seed * 5) % 18));
  d.setHours(10, 0, 0, 0);
  const pl = placements(seed, 16 + ((seed * 7) % 9), [ME.name]);
  return {
    event_id: `demo-ev-${seasonId.slice(-2)}-${n}`, name: `${label} Open`, format_label: label, format_key: key, starts_at: d.toISOString(),
    venue_name: VENUES[n % VENUES.length], status: "completed", multiplier: 1, final: false, players: pl.length,
    winner: pl[0].name, placements: pl, seasonId, leagueId: MMS, ...over,
  };
}

// This year's season: an event a month so far, one coming up, the final in December.
const monthsIn = Math.max(3, Math.min(10, new Date(now).getMonth()));
for (let i = 0; i < monthsIn; i++) events.push(finished(S26, i, monthsIn - i, 11 + i * 3));
events.push({ event_id: "demo-ev-up-1", name: "Modern Open", format_label: "Modern", format_key: "modern", starts_at: at(8), venue_name: "MeH Games",
              status: "setup", multiplier: 1, final: false, players: 12, winner: null, placements: [], seasonId: S26, leagueId: MMS });
events.push({ event_id: "demo-ev-up-2", name: "The Final", format_label: "Modern", format_key: "modern", starts_at: at(29, 9), venue_name: "The Wizard's Chest",
              status: "setup", multiplier: 1, final: true, players: 9, winner: null, placements: [], seasonId: S26, leagueId: MMS });
// Last year's: eight events, a double-points Regional and the final Mara won.
for (let i = 0; i < 8; i++) events.push(finished(S25, i, monthsIn + 3 + (8 - i), 101 + i * 5, i === 6 ? { name: "Front Range Regional", multiplier: 2 } : {}));
{
  const f = finished(S25, 9, monthsIn + 2, 977, { name: "The Final", final: true });
  const mara = f.placements.findIndex((p) => p.name === "Mara Quinn");
  if (mara > 0) [f.placements[0], f.placements[mara]] = [{ ...f.placements[mara], place: 1 }, { ...f.placements[0], place: mara + 1 }];
  else if (mara < 0) f.placements[0] = { key: uid(1), userId: uid(1), name: "Mara Quinn", place: 1, matchWins: 6 };
  f.winner = f.placements[0].name;
  events.push(f);
}

const stateOf = (s: DemoSeason): SeasonState => {
  const d = new Date(now);
  const today = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  return s.closed || today > s.ends_on ? "over" : today < s.starts_on ? "upcoming" : "active";
};
const seasonJson = (s: DemoSeason): Season => ({ id: s.id, name: s.name, starts_on: s.starts_on, ends_on: s.ends_on, state: stateOf(s),
  points: s.points, best_n: s.best_n, qualify: s.qualify, closed: s.closed });
const leagueJson = (l: DemoLeague): League => ({ id: l.id, slug: l.slug, name: l.name, description: l.description, region: l.region, link: l.link,
  archived: l.archived, organizers: l.members.map((m) => m.name) });

interface Result { event: DemoEvent; place: number; matchWins: number; points: number; counted: boolean }
interface TableRow extends StandingRow { results: Result[]; userId: string | null }

/** A season's standings by the contract's rules (§ 3 Standings and Qualification). */
function table(seasonId: string): TableRow[] {
  const s = seasons.find((x) => x.id === seasonId);
  if (!s) return [];
  const done = events.filter((e) => e.seasonId === seasonId && e.status === "completed")
    .sort((a, b) => (a.starts_at ?? "").localeCompare(b.starts_at ?? ""));
  const by = new Map<string, TableRow>();
  for (const e of done) {
    for (const p of e.placements) {
      const row = by.get(p.key) ?? { rank: 0, key: p.key, user_id: p.userId, userId: p.userId, name: p.name, points: 0, events: 0, wins: 0,
                                     best: null, qualified: null, results: [] };
      const points = e.final ? 0 : Math.round((placePoints(s.points, p.place) + (s.points.match_win ?? 0) * p.matchWins) * e.multiplier);
      row.results.push({ event: e, place: p.place, matchWins: p.matchWins, points, counted: !e.final });
      by.set(p.key, row);
    }
  }
  const rows = [...by.values()];
  for (const r of rows) {
    const scoring = r.results.filter((x) => !x.event.final).sort((a, b) => b.points - a.points || a.place - b.place);
    scoring.forEach((x, i) => { x.counted = s.best_n == null || i < s.best_n; });
    r.points = scoring.filter((x) => x.counted).reduce((sum, x) => sum + x.points, 0);
    r.events = scoring.length;
    r.wins = scoring.filter((x) => x.place === 1).length;
    r.best = scoring.length ? Math.min(...scoring.map((x) => x.place)) : null;
  }
  const finishes = (r: TableRow) => r.results.filter((x) => !x.event.final).map((x) => x.place).sort((a, b) => a - b);
  const cmp = (a: TableRow, b: TableRow) => {
    if (a.points !== b.points) return b.points - a.points;
    const fa = finishes(a), fb = finishes(b);
    for (let i = 0; i < Math.max(fa.length, fb.length); i++) {
      if (fa[i] == null) return 1;   // a finish beats none
      if (fb[i] == null) return -1;
      if (fa[i] !== fb[i]) return fa[i] - fb[i];
    }
    return 0;
  };
  const ranked = rows.filter((r) => r.events > 0).sort((a, b) => cmp(a, b) || a.name.localeCompare(b.name));
  ranked.forEach((r, i) => { r.rank = i > 0 && cmp(ranked[i - 1], r) === 0 ? ranked[i - 1].rank : i + 1; });
  // Winners, oldest event first, passing down as far as 8th; then the top N on points among the rest.
  const q = new Set<string>();
  if (s.qualify.winners) {
    for (const e of done.filter((x) => !x.final)) {
      for (let place = 1; place <= (s.qualify.pass_down ? 8 : 1); place++) {
        const at = e.placements.filter((p) => p.place === place && !q.has(p.key));
        if (!at.length) continue;
        for (const p of at) { q.add(p.key); const row = by.get(p.key); if (row) row.qualified = "winner"; }
        break;
      }
    }
  }
  let left = s.qualify.top ?? 0;
  for (const r of ranked) {
    if (left <= 0) break;
    if (r.qualified) continue;
    r.qualified = "points";
    left--;
  }
  return ranked;
}

const wire = ({ results: _r, userId: _u, ...row }: TableRow): StandingRow => row;
const slugOf = (name: string) => name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 34);

function leagueOf(idOrSlug: string): DemoLeague {
  const l = leagues.find((x) => x.id === idOrSlug || x.slug === idOrSlug.toLowerCase());
  if (!l || l.archived) throw Object.assign(new Error("That league isn't available"), { code: "P0002" });
  return l;
}
const roleOf = (l: DemoLeague) => l.members.find((m) => m.userId === ME.id)?.role ?? null;

export function leagueView(league: string, seasonId: string | null): LeagueView {
  const l = leagueOf(league);
  const mine = seasons.filter((s) => s.leagueId === l.id);
  const rank = (s: DemoSeason) => ({ active: 0, over: 1, upcoming: 2 })[stateOf(s)];
  const s = seasonId ? mine.find((x) => x.id === seasonId) : [...mine].sort((a, b) => rank(a) - rank(b) || b.starts_on.localeCompare(a.starts_on))[0];
  if (seasonId && !s) throw Object.assign(new Error("That season isn't in this league"), { code: "P0002" });
  const rows = s ? table(s.id) : [];
  const me = rows.find((r) => r.userId === ME.id);
  return {
    league: leagueJson(l),
    me: { role: roleOf(l), following: l.following, notify: l.following && l.notify },
    // Who runs it, with accounts: only for the league's own organizers.
    members: roleOf(l) ? [...l.members].sort((a, b) => Number(b.role === "owner") - Number(a.role === "owner"))
      .map((m) => ({ user_id: m.userId, name: m.name, role: m.role })) : null,
    seasons: [...mine].sort((a, b) => b.starts_on.localeCompare(a.starts_on)).map((x) => ({ id: x.id, name: x.name, starts_on: x.starts_on, ends_on: x.ends_on, state: stateOf(x) })),
    season: s ? seasonJson(s) : null,
    events: s ? events.filter((e) => e.seasonId === s.id).map(({ placements: _p, seasonId: _s, leagueId: _l, ...e }) => e) : [],
    standings: rows.slice(0, 50).map(wire),
    standings_count: rows.length,
    my_row: me ? wire(me) : null,
  };
}

export function leagueStandings(seasonId: string, after: number, limit: number): StandingRow[] {
  return table(seasonId).slice(after, after + limit).map(wire);
}

export function leaguePlayer(seasonId: string, key: string): LeaguePlayer {
  const row = table(seasonId).find((r) => r.key === key);
  if (!row) throw Object.assign(new Error("That player isn't in this season"), { code: "P0002" });
  const list: LeaguePlayerEvent[] = row.results
    .sort((a, b) => (b.event.starts_at ?? "").localeCompare(a.event.starts_at ?? ""))
    .map((r) => ({ event_id: r.event.event_id, name: r.event.name, format_label: r.event.format_label, starts_at: r.event.starts_at, place: r.place,
                   players: r.event.players, match_wins: r.matchWins, points: r.points, counted: r.counted }));
  return { player: wire(row), events: list };
}

function card(l: DemoLeague): LeagueCard {
  const mine = seasons.filter((s) => s.leagueId === l.id);
  const rank = (s: DemoSeason) => ({ active: 0, over: 1, upcoming: 2 })[stateOf(s)];
  const s = [...mine].sort((a, b) => rank(a) - rank(b) || b.starts_on.localeCompare(a.starts_on))[0];
  const next = events.filter((e) => e.leagueId === l.id && e.status !== "completed").sort((a, b) => (a.starts_at ?? "").localeCompare(b.starts_at ?? ""))[0];
  return { id: l.id, slug: l.slug, name: l.name, region: l.region, season: s?.name ?? null,
           next_event: next ? { event_id: next.event_id, name: next.name, starts_at: next.starts_at, format_label: next.format_label } : null };
}

export function leaguesHome(query: string): LeaguesHome {
  const live = leagues.filter((l) => !l.archived);
  const q = query.trim().toLowerCase();
  return {
    mine: live.filter((l) => roleOf(l)).map((l) => ({ ...card(l), role: roleOf(l)! })),
    following: live.filter((l) => l.following && !roleOf(l)).map((l) => ({ ...card(l), notify: l.notify })),
    found: q.length < 2 ? [] : live.filter((l) => l.name.toLowerCase().includes(q) || (l.region ?? "").toLowerCase().includes(q)).map(card),
  };
}

export function leagueFollowSet(leagueId: string, follow: boolean, notify: boolean | null): LeagueFollow {
  const l = leagueOf(leagueId);
  l.notify = follow && (notify ?? (l.following ? l.notify : true));
  l.following = follow;
  return { following: l.following, notify: l.following && l.notify };
}

export function leagueCreate(input: { name: string; description?: string; region?: string; link?: string }): League {
  const name = input.name.trim().replace(/\s+/g, " ");
  if (name.length < 2 || name.length > 60) throw Object.assign(new Error("Name the league (2 to 60 characters)"), { code: "22023" });
  if (leagues.filter((l) => roleOf(l) === "owner" && !l.archived).length >= 3) throw Object.assign(new Error("You own 3 leagues. Archive one first."), { code: "53400" });
  if (input.link?.trim() && !/^https:\/\//.test(input.link.trim())) throw Object.assign(new Error("The link starts with https://"), { code: "22023" });
  let slug = slugOf(name), n = 1;
  while (leagues.some((l) => l.slug === slug)) slug = `${slugOf(name)}-${++n}`;
  const l: DemoLeague = { id: `d0000000-0000-0000-0000-00000001eb${String(leagues.length).padStart(2, "0")}`, slug, name,
    description: input.description?.trim() || null, region: input.region?.trim() || null, link: input.link?.trim() || null, archived: false,
    organizers: [ME.name], members: [{ userId: ME.id, name: ME.name, role: "owner" }], following: false, notify: false };
  leagues.push(l);
  return leagueJson(l);
}

export function leagueUpdate(leagueId: string, patch: LeaguePatch): League {
  const l = leagueOf(leagueId);
  if (patch.name != null) {
    const name = patch.name.trim().replace(/\s+/g, " ");
    if (name.length < 2 || name.length > 60) throw Object.assign(new Error("Name the league (2 to 60 characters)"), { code: "22023" });
    l.name = name;
  }
  if ("description" in patch) l.description = patch.description?.trim() || null;
  if ("region" in patch) l.region = patch.region?.trim() || null;
  if ("link" in patch) {
    if (patch.link?.trim() && !/^https:\/\//.test(patch.link.trim())) throw Object.assign(new Error("The link starts with https://"), { code: "22023" });
    l.link = patch.link?.trim() || null;
  }
  if (patch.archived != null) l.archived = patch.archived;
  return leagueJson(l);
}

export function leagueMemberSet(leagueId: string, userId: string, role: "owner" | "organizer" | null) {
  const l = leagueOf(leagueId);
  if (roleOf(l) !== "owner") throw Object.assign(new Error("Only the owner can change who runs a league"), { code: "42501" });
  const before = l.members.find((m) => m.userId === userId);
  if (before?.role === "owner" && role !== "owner" && l.members.filter((m) => m.role === "owner").length <= 1) {
    throw Object.assign(new Error("A league keeps an owner. Make someone else the owner first."), { code: "22023" });
  }
  if (!before && role && l.members.length >= 20) throw Object.assign(new Error("A league has up to 20 organizers"), { code: "53400" });
  if (!role) l.members = l.members.filter((m) => m.userId !== userId);
  else if (before) before.role = role;
  else l.members.push({ userId, name: POOL.find((p) => p.id === userId)?.name ?? "A friend", role });
}

export function leagueSeasonSet(leagueId: string, seasonId: string | null, patch: SeasonPatch): Season {
  const l = leagueOf(leagueId);
  let s = seasonId ? seasons.find((x) => x.id === seasonId && x.leagueId === l.id) : undefined;
  if (seasonId && !s) throw Object.assign(new Error("That season isn't in this league"), { code: "P0002" });
  const name = patch.name?.trim();
  if (name && seasons.some((x) => x.leagueId === l.id && x.id !== seasonId && x.name.toLowerCase() === name.toLowerCase())) {
    throw Object.assign(new Error("This league already has a season with that name"), { code: "23505" });
  }
  if (!s) {
    if (!name || !patch.starts_on || !patch.ends_on || !patch.points) throw Object.assign(new Error("A season needs a name, dates and points"), { code: "22023" });
    s = { id: `d0000000-0000-0000-0000-00000005eb${String(seasons.length).padStart(2, "0")}`, leagueId: l.id, name, starts_on: patch.starts_on,
          ends_on: patch.ends_on, points: patch.points, best_n: null, qualify: { winners: false, pass_down: true, top: 0 }, closed: false };
    seasons.push(s);
  }
  if (name) s.name = name;
  if (patch.starts_on) s.starts_on = patch.starts_on;
  if (patch.ends_on) s.ends_on = patch.ends_on;
  if (patch.points) s.points = patch.points;
  if ("best_n" in patch) s.best_n = patch.best_n ?? null;
  if (patch.qualify) s.qualify = patch.qualify;
  if (patch.closed != null) s.closed = patch.closed;
  return seasonJson(s);
}

const eventLeague = (e: DemoEvent): EventLeague => {
  const l = leagues.find((x) => x.id === e.leagueId)!, s = seasons.find((x) => x.id === e.seasonId)!;
  return { id: l.id, slug: l.slug, name: l.name, season_id: s.id, season: s.name, multiplier: e.multiplier, final: e.final };
};

export function leagueEventSet(eventId: string, seasonId: string | null, multiplier: number, final: boolean): { league: EventLeague | null } {
  const i = events.findIndex((e) => e.event_id === eventId);
  if (seasonId == null) {
    if (i >= 0) events.splice(i, 1);
    return { league: null };
  }
  const s = seasons.find((x) => x.id === seasonId);
  if (!s) throw Object.assign(new Error("That season isn't available"), { code: "22023" });
  const e: DemoEvent = i >= 0 ? events[i] : { event_id: eventId, name: "Your event", format_label: "Modern", format_key: "modern", starts_at: at(3),
    venue_name: null, status: "setup", multiplier, final, players: 0, winner: null, placements: [], seasonId, leagueId: s.leagueId };
  Object.assign(e, { seasonId, leagueId: s.leagueId, multiplier, final });
  if (i < 0) events.push(e);
  return { league: eventLeague(e) };
}

/* ── found events ────────────────────────────────────────────────────── */

type Found = FoundEvent & { description?: string; here_km: number | null };
const found: Found[] = [
  { event_id: "demo-ev-run", name: "Legacy Open", format_key: "legacy", format_label: "Legacy", status: "in_progress", current_round: 3,
    starts_at: at(0, 9), venue_name: "Mythic Games", venue_address: "1630 S Colorado Blvd, Denver", capacity: 32, players: 30, visibility: "public",
    organizer: "Kai Brandt", has_description: false, league: null, me: null, here_km: 4 },
  { event_id: "demo-ev-fri", name: "Friday draft", format_key: "limited", format_label: "Draft", set_name: "Star Trek", status: "setup", current_round: 0,
    starts_at: at((5 - new Date(now).getDay() + 7) % 7, 18, 30), venue_name: null, capacity: 8, players: 5, visibility: "friends",
    organizer: "Mara Quinn", has_description: true, description: "Bring sleeves. Pizza at 6, packs open at 6:30.", league: null, me: "player", here_km: null },
  { event_id: "demo-ev-cube", name: "Vintage Cube night", format_key: "cube", format_label: "Cube draft", cube_name: "Vintage Cube", status: "setup",
    current_round: 0, starts_at: at(2, 19), venue_name: "Level 7 Games", capacity: 16, players: 16, visibility: "public", organizer: "Lee Park",
    has_description: false, league: null, me: null, here_km: 11 },
  { event_id: "demo-ev-pauper", name: "Pauper weekly", format_key: "pauper", format_label: "Pauper", status: "setup", current_round: 0,
    starts_at: at(3, 18), venue_name: "Black & Read", capacity: null, players: 7, visibility: "public", organizer: "Theo Vance",
    has_description: false, league: null, me: null, here_km: 23 },
  { event_id: "demo-ev-trios", name: "Team draft", format_key: "limited", format_label: "Team draft", set_name: "Star Trek", team_size: 3, status: "setup",
    current_round: 0, starts_at: at(6, 13), venue_name: "MeH Games", capacity: 6, players: 4, visibility: "friends", organizer: "Theo Vance",
    has_description: false, league: null, me: null, here_km: 19 },
  { event_id: "demo-ev-up-1", name: "Modern Open", format_key: "modern", format_label: "Modern", status: "setup", current_round: 0, starts_at: at(8),
    venue_name: "MeH Games", venue_address: "3355 S Wadsworth Blvd, Lakewood", capacity: null, players: 12, top_cut: 8, visibility: "public",
    organizer: "Ines Ruiz", has_description: true,
    description: "Round 1 at 10:00. Five rounds of Swiss, then a top 8.\n\nDecklists are due before round 1: https://example.com/mountain-magic/decklists\nWinner qualifies for the final in December.",
    league: null, me: null, here_km: 19 },
  { event_id: "demo-ev-std", name: "Standard Showdown", format_key: "standard", format_label: "Standard", status: "setup", current_round: 0,
    starts_at: at(9, 12), venue_name: "The Wizard's Chest", capacity: 24, players: 9, visibility: "public", organizer: "Sam Okafor",
    has_description: false, league: null, me: null, here_km: 6 },
  { event_id: "demo-ev-canlander", name: "Highlander Sunday", format_key: "canadian_highlander", format_label: "Canadian Highlander", status: "setup",
    current_round: 0, starts_at: at(16, 11), venue_name: "Enchanted Grounds", capacity: 16, players: 3, visibility: "public", organizer: "Cy Moreau",
    has_description: false, league: null, me: null, here_km: 31 },
  { event_id: "demo-ev-harbor", name: "Week 6", format_key: "cube", format_label: "Cube draft", cube_name: "Harbor Cube", status: "setup", current_round: 0,
    starts_at: at(4, 18, 30), venue_name: "Canton Games", capacity: 8, players: 6, visibility: "public", organizer: "Lee Park",
    has_description: false, league: null, me: null, here_km: 2410 },
  { event_id: "demo-ev-up-2", name: "The Final", format_key: "modern", format_label: "Modern", status: "setup", current_round: 0, starts_at: at(29, 9),
    venue_name: "The Wizard's Chest", capacity: 32, players: 9, top_cut: 8, visibility: "public", organizer: "Ines Ruiz", has_description: true,
    description: "Invitation: event winners and the top 10 on points.", league: null, me: null, here_km: 6 },
];
const HARBOR: EventLeague = { id: leagues[1].id, slug: leagues[1].slug, name: leagues[1].name, season_id: seasons[2].id, season: "Fall", multiplier: 1, final: false };
const leagueFor = (id: string): EventLeague | null => {
  if (id === "demo-ev-harbor") return HARBOR;
  const e = events.find((x) => x.event_id === id);
  return e ? eventLeague(e) : null;
};

export function findEvents(filters: Record<string, unknown>, limit: number): FoundEvent[] {
  const f = filters as { formats?: string[]; lat?: number; km?: number; from?: string; to?: string; q?: string; team?: boolean; league?: boolean;
                         open?: boolean; scope?: string };
  const from = f.from ? new Date(f.from).getTime() : now - 2 * DAY, to = f.to ? new Date(f.to).getTime() : null;
  const q = (f.q ?? "").trim().toLowerCase();
  return found
    .map(({ here_km, description: _d, ...e }): FoundEvent => ({ ...e, league: leagueFor(e.event_id), km: f.lat != null ? here_km : null }))
    .filter((e) => {
      const t = new Date(e.starts_at ?? now).getTime();
      const hay = [e.name, e.venue_name, e.venue_address, e.league?.name].filter(Boolean).join(" ").toLowerCase();
      return (!f.formats?.length || f.formats.includes(e.format_key ?? "other"))
        && t > from && (to == null || t < to)
        && (f.km == null || f.lat == null || (e.km != null && e.km <= f.km))
        && (f.team == null || (e.team_size != null) === f.team)
        && (f.league == null || !!e.league === f.league)
        && (!f.open || (e.status === "setup" && (e.capacity == null || (e.players ?? 0) < e.capacity)))
        && (!f.scope || f.scope === "all" || e.visibility === f.scope)
        && (q.length < 2 || hay.includes(q));
    })
    .sort((a, b) => (a.starts_at ?? "").localeCompare(b.starts_at ?? "") || a.name.localeCompare(b.name))
    .slice(0, limit);
}

/** Text an organizer typed in the demo's Setup → Details, kept for the page. */
const listings = new Map<string, EventListing>();

export function eventAbout(eventId: string): EventAbout | null {
  const e = found.find((x) => x.event_id === eventId);
  const mine = listings.get(eventId);
  if (!e && !mine) return null;
  return { event_id: eventId, description: mine?.description ?? e?.description ?? null, venue_address: mine?.venue_address ?? e?.venue_address ?? null,
           visibility: mine?.visibility ?? e?.visibility ?? "link_only", format_key: e?.format_key ?? "other", league: leagueFor(eventId), placed: false };
}

export function eventListingSet(eventId: string, patch: ListingPatch): EventListing {
  const was = listings.get(eventId) ?? { description: null, venue_address: null, visibility: "link_only" };
  const next: EventListing = {
    description: "description" in patch ? patch.description?.trim() || null : was.description,
    venue_address: "venue_address" in patch ? patch.venue_address?.trim() || null : was.venue_address,
    visibility: patch.find ? (patch.find === "private" ? "link_only" : patch.find) : was.visibility,
  };
  listings.set(eventId, next);
  return next;
}

/** A found event's own page (`/s/<id>?demo`): the sign-up page before round 1, as event_public would send it. */
export function publicEvent(eventId: string): PublicEvent | null {
  const e = found.find((x) => x.event_id === eventId);
  if (!e) return null;
  const full = e.capacity != null && (e.players ?? 0) >= e.capacity;
  return {
    eventId, name: e.name, status: "setup", currentRound: 0, numberOfRounds: 5, showClock: true, round: null, pairings: [], access: "link",
    shortCode: null, formatLabel: e.format_label ?? null, startsAt: e.starts_at ?? null, venueName: e.venue_name ?? null,
    organizerName: e.organizer ?? null, capacity: e.capacity ?? null, players: e.players ?? 0, waitlist: full ? 2 : 0, topCut: e.top_cut ?? 0,
    autoRounds: true, signUp: full ? "full" : "open", me: e.me === "player" ? "player" : null, position: null, decklists: "off", rounds: [],
  };
}

/* ── boards ──────────────────────────────────────────────────────────── */

let listed = true;
const BOARD_SIZE: Record<string, number> = { standard: 61, pioneer: 38, modern: 124, legacy: 40, vintage: 12, pauper: 57, premodern: 9, canadian_highlander: 18, limited: 212, cube: 86 };
const MY_BOARDS: Record<string, BoardMe> = {
  modern: { rating: 1612, matches: 46, wins: 28, losses: 16, draws: 2, events: 9, rank: 14, to_go: 0 },
  legacy: { rating: 1688, matches: 21, wins: 15, losses: 6, draws: 0, events: 4, rank: 3, to_go: 0 },
  limited: { rating: 1547, matches: 33, wins: 18, losses: 14, draws: 1, events: 11, rank: 71, to_go: 0 },
  cube: { rating: 1540, matches: 6, wins: 4, losses: 2, draws: 0, events: 2, rank: null, to_go: 4 },
};
const myBoard = (key: string): BoardMe | null => {
  const m = MY_BOARDS[key];
  return m ? (listed ? m : { ...m, rank: null }) : null;
};

export function formatBoards(): Boards {
  return { listed, boards: BOARD_KEYS.map((b): Board => ({ board: b.key, label: b.label, players: BOARD_SIZE[b.key] ?? 0, me: myBoard(b.key) })) };
}

function boardRows(key: string): BoardRow[] {
  const n = BOARD_SIZE[key];
  if (n == null) throw Object.assign(new Error("There's no board for that format"), { code: "22023" });
  const r = rng(key.split("").reduce((a, c) => a * 31 + c.charCodeAt(0), 7));
  const me = listed ? MY_BOARDS[key] : null;
  const rows: BoardRow[] = [];
  let rating = 1840 + Math.round(r() * 40);
  for (let i = 0; i < n; i++) {
    const rank = i + 1;
    if (me?.rank === rank) {
      rows.push({ rank, user_id: ME.id, name: ME.name, avatar_url: null, rating: me.rating, matches: me.matches, wins: me.wins, losses: me.losses,
                  draws: me.draws, events: me.events });
      rating = me.rating;
      continue;
    }
    // Ratings fall away from the top and never cross the demo account's own place.
    const floor = me?.rank && rank < me.rank ? me.rating + (me.rank - rank) : 1400;
    rating = Math.max(floor, rating - Math.round(1 + r() * (i < 10 ? 12 : 5)));
    const p = POOL[(i * 7 + key.length) % POOL.length];
    const person = p.id === ME.id ? POOL[(i * 7 + key.length + 1) % POOL.length] : p;
    const matches = 10 + Math.round(r() * 60), draws = Math.round(r() * 2);
    const wins = Math.round((matches - draws) * (0.42 + (rating - 1400) / 1400));
    rows.push({ rank, user_id: person.id ?? uid(100 + i), name: i < POOL.length - 1 ? person.name : `${person.name.split(" ")[0]} ${"ABCDEFGHJKLMNP"[i % 14]}.`,
                avatar_url: null, rating, matches, wins: Math.min(wins, matches - draws), losses: Math.max(0, matches - draws - wins), draws,
                events: 2 + Math.round(matches / 5) });
  }
  return rows;
}

export function formatLeaderboard(board: string, after: number, limit: number): Leaderboard {
  const rows = boardRows(board);
  return { board, label: formatKeyLabel(board), count: rows.length, me: myBoard(board), rows: rows.slice(after, after + limit) };
}

export function leaderboardsListedSet(next: boolean): { listed: boolean } {
  listed = next;
  return { listed };
}

/* ── achievements ────────────────────────────────────────────────────── */

let achievementsVisibility: AchievementsVisibility = "public";

function leagueItems(userId: string): Achievement[] {
  const out: Achievement[] = [];
  for (const s of seasons.filter((x) => x.leagueId === MMS).sort((a, b) => b.starts_on.localeCompare(a.starts_on))) {
    const rows = table(s.id);
    const row = rows.find((r) => r.userId === userId);
    const final = events.find((e) => e.seasonId === s.id && e.final && e.status === "completed");
    const champion = !!final?.placements.some((p) => p.place === 1 && p.userId === userId);
    if (!row && !champion) continue;
    const top8 = !!row && row.rank <= 8;
    if (!champion && !top8 && !row?.qualified && !(row?.wins ?? 0)) continue;
    out.push({ kind: "league", league_id: MMS, league_slug: leagues[0].slug, league_name: leagues[0].name, season_id: s.id, season_name: s.name,
               state: stateOf(s), rank: row?.rank ?? null, players: rows.length, points: row?.points ?? 0, wins: row?.wins ?? 0,
               qualified: row?.qualified ?? null, champion });
  }
  return out.sort((a, b) => Number((b as { champion: boolean }).champion) - Number((a as { champion: boolean }).champion));
}

export function profileAchievements(userId: string): Achievements {
  const self = userId === ME.id;
  const boards: Achievement[] = self
    ? Object.entries(MY_BOARDS).map(([board, m]): Achievement =>
        ({ kind: "board", board, label: formatKeyLabel(board), rank: listed ? m.rank : null, rating: m.rating, matches: m.matches, to_go: m.to_go,
           players: BOARD_SIZE[board] ?? 0 }))
    : BOARD_KEYS.flatMap((b): Achievement[] => {
        const row = boardRows(b.key).find((r) => r.user_id === userId);
        return row && row.rank <= 40 ? [{ kind: "board", board: b.key, label: b.label, rank: row.rank, rating: row.rating, matches: row.matches, to_go: 0,
                                           players: BOARD_SIZE[b.key] ?? 0 }] : [];
      }).slice(0, 3);
  const rank = (a: Achievement) => (a.kind === "board" ? a.rank ?? 1e9 : 0);
  const items = [...leagueItems(userId), ...boards.sort((a, b) => rank(a) - rank(b))];
  return self ? { items, visibility: achievementsVisibility, listed } : { items };
}

export function achievementsVisibilitySet(v: AchievementsVisibility): { visibility: AchievementsVisibility } {
  achievementsVisibility = v;
  return { visibility: v };
}

/** The demo account's id, for screens that mark "you". */
export const DEMO_ME = ME.id;
