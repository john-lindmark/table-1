import { describe, expect, it } from "vitest";
import cases from "../../../testdata/leagues/cases.json";
import {
  BOARD_KEYS, FORMAT_KEYS, NO_FILTERS, PRESETS, achievementPath, achievementText, boardLine, counter, dateText, eventLine,
  filterLabels, filtersWire, findPickOf, finishLine, foundEventPath, isFiltered, isMissing, leagueEventLine, leagueLine,
  leaguesError, loadFindFilters, memberActions, multiplierText, orderedLeagueEvents, placePoints, pointsWords, presetOf, qualifyWords,
  resultsPublic, rowLabel, standingLine, whenText, whenWindow,
  type Achievement, type FindFilters, type LeagueEvent,
} from "./leagues";

// Finding events, leagues, boards and achievements (contract/public-events-leagues-2026-11-13.md). The wording and
// small rules are shared cases (testdata/leagues/cases.json from make_cases.py), the same file iOS and Android run.

describe("leagues: shared cases (testdata/leagues)", () => {
  it("format keys, in order", () => {
    expect(FORMAT_KEYS).toEqual(cases.format_keys);
    expect(BOARD_KEYS.map((b) => b.key)).not.toContain("other");
  });

  it("presets", () => {
    expect(PRESETS).toEqual(cases.presets);
    expect(presetOf(cases.presets.places)).toBe("places");
    expect(presetOf(cases.presets.match_wins)).toBe("match_wins");
    expect(presetOf({ places: [{ through: 4, points: 4 }], participation: 0, match_win: 0 })).toBe("custom");
  });

  it("points in words", () => {
    expect(cases.points_words.length).toBeGreaterThan(0);
    for (const c of cases.points_words) expect(pointsWords(c.rule), JSON.stringify(c.rule)).toBe(c.want);
  });

  it("what a place earns", () => {
    for (const c of cases.place_points) expect(placePoints(c.rule, c.place), `place ${c.place}`).toBe(c.want);
  });

  it("qualification in words", () => {
    for (const c of cases.qualify_words) expect(qualifyWords(c.qualify), JSON.stringify(c.qualify)).toBe(c.want);
  });

  it("the label above a found event", () => {
    for (const c of cases.row_label) expect(rowLabel(c.event), c.event.name).toBe(c.want);
  });

  it("a found event's data line", () => {
    for (const c of cases.event_line) expect(eventLine(c.event, c.when), c.event.name).toBe(c.want);
  });

  it("the When windows, in the device's zone", () => {
    expect(cases.when_window.length).toBeGreaterThan(0);
    for (const c of cases.when_window) {
      expect(whenWindow(c.pick, new Date(c.now), c.zone), `${c.pick} at ${c.now} in ${c.zone}`).toEqual(c.want);
    }
  });

  it("what the filter cells read", () => {
    for (const c of cases.filter_labels) expect(filterLabels(c.filters as Partial<FindFilters>), JSON.stringify(c.filters)).toEqual(c.want);
  });

  it("a board's data line", () => {
    for (const c of cases.board_line) expect(boardLine(c.board), JSON.stringify(c.board)).toBe(c.want);
  });

  it("a league's data line", () => {
    for (const c of cases.league_line) expect(leagueLine(c.card), JSON.stringify(c.card)).toBe(c.want);
  });

  it("achievement tiles", () => {
    expect(cases.achievement_text.length).toBeGreaterThan(0);
    for (const c of cases.achievement_text) expect(achievementText(c.item as Partial<Achievement>), JSON.stringify(c.item)).toEqual(c.want);
  });
});

describe("leagues: the web's own", () => {
  it("dates read in the zone asked for", () => {
    expect(whenText("2026-03-29T16:00:00Z", "America/Denver", "en-GB")).toBe("SUN 29 MAR · 10:00");
    expect(whenText("2026-03-29T16:00:00Z", "Europe/Stockholm", "en-GB")).toBe("SUN 29 MAR · 18:00");
    expect(whenText(null)).toBeNull();
    expect(whenText("not a date")).toBeNull();
    // A season's bare date is that calendar day wherever it's read.
    expect(dateText("2026-01-01", "America/Denver", "en-GB")).toBe("1 JAN 2026");
    expect(dateText("2026-03-29T03:00:00Z", "America/Denver", "en-GB")).toBe("28 MAR 2026");
  });

  it("the filters as find_events takes them", () => {
    const now = new Date("2026-11-13T18:30:00-07:00");
    expect(filtersWire(NO_FILTERS, { now, zone: "America/Denver" })).toEqual({});
    expect(filtersWire({ ...NO_FILTERS, formats: ["modern", "cube"], when: "today", scope: "friends", team: true, open: true },
      { now, zone: "America/Denver", q: " open " })).toEqual({
      formats: ["modern", "cube"], from: "2026-11-13T07:00:00Z", to: "2026-11-14T07:00:00Z", q: "open", team: true, open: true, scope: "friends",
    });
    // A distance needs a place: without one the list is Everywhere and nothing about where is sent.
    expect(filtersWire({ ...NO_FILTERS, km: 50 }, { now, zone: "UTC" })).toEqual({});
    expect(filtersWire({ ...NO_FILTERS, km: 50 }, { now, zone: "UTC", here: { lat: 39.7, lng: -105 } })).toEqual({ lat: 39.7, lng: -105, km: 50 });
    // With a place and no distance every event still gets its km.
    expect(filtersWire(NO_FILTERS, { now, zone: "UTC", here: { lat: 39.7, lng: -105 } })).toEqual({ lat: 39.7, lng: -105 });
    // One letter isn't a search.
    expect(filtersWire(NO_FILTERS, { now, zone: "UTC", q: "m" })).toEqual({});
  });

  it("picks kept per device come back, and nonsense reads as the default", () => {
    const kept: Record<string, string> = { formats: '["cube","modern","nope"]', km: "50", when: "weekend", more: '["team","friends"]' };
    expect(loadFindFilters((k) => kept[k] ?? null)).toEqual(
      { formats: ["modern", "cube"], km: 50, when: "weekend", scope: "friends", team: true, league: false, open: false });
    expect(loadFindFilters(() => null)).toEqual(NO_FILTERS);
    expect(loadFindFilters((k) => ({ formats: "{", km: "7", when: "someday", more: "5" } as Record<string, string>)[k] ?? null)).toEqual(NO_FILTERS);
    expect(isFiltered(NO_FILTERS)).toBe(false);
    expect(isFiltered(NO_FILTERS, "mo")).toBe(true);
    expect(isFiltered({ ...NO_FILTERS, open: true })).toBe(true);
  });

  it("who can find it reads as three picks", () => {
    expect(findPickOf("public")).toBe("public");
    expect(findPickOf("friends")).toBe("friends");
    for (const v of ["link_only", "nearby", "private", null, undefined]) expect(findPickOf(v)).toBe("private");
    expect(counter(1240, 2000)).toBe("1,240 / 2,000");
  });

  it("results are public for a public event or one in a league", () => {
    expect(resultsPublic({ visibility: "public", league: null })).toBe(true);
    expect(resultsPublic({ visibility: "link_only", league: { name: "MMS" } })).toBe(true);
    expect(resultsPublic({ visibility: "friends", league: null })).toBe(false);
    expect(resultsPublic(null)).toBe(false);
  });

  it("a found event opens on the screen its viewer has", () => {
    expect(foundEventPath({ event_id: "e1", me: "organizer" })).toBe("/e/e1");
    expect(foundEventPath({ event_id: "e1", me: "player" })).toBe("/p/e1");
    expect(foundEventPath({ event_id: "e1", me: "waitlisted" })).toBe("/s/e1");
    expect(foundEventPath({ event_id: "e1", me: null })).toBe("/s/e1");
  });

  const ev = (over: Partial<LeagueEvent>): LeagueEvent => ({
    event_id: "e", name: "Modern Open", format_label: "Modern", format_key: "modern", starts_at: "2026-03-29T16:00:00Z", venue_name: "MeH Games",
    status: "setup", multiplier: 1, final: false, players: 12, winner: null, ...over,
  });

  it("a league's events: upcoming soonest first, then finished newest first", () => {
    const o = orderedLeagueEvents([
      ev({ event_id: "a", status: "completed", starts_at: "2026-01-10T16:00:00Z" }), ev({ event_id: "b", starts_at: "2026-12-05T16:00:00Z" }),
      ev({ event_id: "c", status: "completed", starts_at: "2026-02-10T16:00:00Z" }), ev({ event_id: "d", starts_at: "2026-11-20T16:00:00Z" }),
    ]);
    expect(o.upcoming.map((e) => e.event_id)).toEqual(["d", "b"]);
    expect(o.finished.map((e) => e.event_id)).toEqual(["c", "a"]);
  });

  it("league rows read as data", () => {
    expect(leagueEventLine(ev({ status: "completed", winner: "Bea" }), "UTC")).toMatch(/^29 MAR 2026 · MODERN · BEA WON$/);
    expect(leagueEventLine(ev({ final: true }), "UTC")).toContain("· MODERN · FINAL · MEH GAMES");
    expect(leagueEventLine(ev({ multiplier: 1.5 }), "UTC")).toContain("· 1.5× ·");
    expect(multiplierText(2)).toBe("2×");
    expect(finishLine({ place: 3, players: 24, format_label: "Modern", starts_at: "2026-03-29T16:00:00Z" }, "UTC")).toMatch(/^3RD OF 24 · MODERN · 29 MAR 2026$/);
    expect(standingLine({ events: 5, wins: 2, best: 1 })).toBe("5 EVENTS · 2 WINS · BEST 1ST");
    expect(standingLine({ events: 1, wins: 0, best: null })).toBe("1 EVENT");
  });

  it("a tile opens its league on that season, or its board", () => {
    expect(achievementPath({ kind: "board", board: "modern", label: "Modern", rank: 14, rating: 1612, matches: 30, to_go: 0, players: 124 })).toBe("/boards/modern");
    expect(achievementPath({
      kind: "league", league_id: "l", league_slug: "the-mountain-magic-series", league_name: "MMS", season_id: "s1", season_name: "2026",
      state: "active", rank: 4, players: 40, points: 30, wins: 0, qualified: null, champion: false,
    })).toBe("/league/the-mountain-magic-series?season=s1");
  });

  it("a function the server doesn't have yet is missing, not an error to show raw", () => {
    expect(isMissing({ code: "PGRST202", message: "Could not find the function public.find_events(p_filters, p_limit) in the schema cache" })).toBe(true);
    expect(isMissing({ status: 404, message: "Not Found" })).toBe(true);
    expect(isMissing({ code: "42501", message: "That event isn't available" })).toBe(false);
    expect(isMissing({ code: "P0002", status: 404, message: "That league isn't available" })).toBe(false);
    expect(isMissing({ code: "42883", message: "function public.find_events(jsonb, integer) does not exist" })).toBe(true);
    expect(isMissing(new Error("Failed to fetch"))).toBe(false);
    expect(leaguesError({ code: "PGRST202", message: "Could not find the function" })).toBe("This isn't available yet.");
    expect(leaguesError({ code: "P0002", message: "That league isn't available" })).toBe("That league isn't available");
    expect(leaguesError(null)).toBe("Couldn't load. Check your connection.");
  });
});

// Who runs a league (contract § 3: league_view `members`, league_member_set), on the dev demo's stand-in league.
describe("leagues: organizers", () => {
  it("only the owner gets actions on a member", () => {
    expect(memberActions("owner", { role: "organizer" })).toEqual(["make_owner", "remove"]);
    expect(memberActions("owner", { role: "owner" })).toEqual(["make_organizer", "remove"]);
    expect(memberActions("organizer", { role: "organizer" })).toEqual([]);
    expect(memberActions(null, { role: "owner" })).toEqual([]);
  });

  it("members reach the league's own organizers only, owner first", async () => {
    const demo = await import("./leaguesDemo");
    const mine = demo.leagueView("kitchen-table-pauper", null);
    expect(mine.me.role).toBe("owner");
    expect(mine.members?.map((m) => [m.name, m.role])).toEqual([["Sam Reyes", "owner"], ["Theo Vance", "organizer"]]);
    expect(mine.members?.every((m) => !!m.user_id)).toBe(true);
    // A league the demo account follows but doesn't run: names on the page, no accounts.
    const theirs = demo.leagueView("the-mountain-magic-series", null);
    expect(theirs.me.role).toBeNull();
    expect(theirs.members).toBeNull();
    expect(theirs.league.organizers).toEqual(["Ines Ruiz", "Kai Brandt"]);
  });

  it("the owner promotes, demotes and removes; a league keeps an owner", async () => {
    const demo = await import("./leaguesDemo");
    const id = demo.leagueView("kitchen-table-pauper", null).league.id;
    const [me, theo] = demo.leagueView(id, null).members!;
    // The only owner can't leave or step down.
    expect(() => demo.leagueMemberSet(id, me.user_id, null)).toThrow("A league keeps an owner");
    expect(() => demo.leagueMemberSet(id, me.user_id, "organizer")).toThrow("A league keeps an owner");
    demo.leagueMemberSet(id, theo.user_id, "owner");
    expect(demo.leagueView(id, null).members?.map((m) => m.role)).toEqual(["owner", "owner"]);
    demo.leagueMemberSet(id, theo.user_id, "organizer");
    demo.leagueMemberSet(id, theo.user_id, null);
    const after = demo.leagueView(id, null);
    expect(after.members?.map((m) => m.name)).toEqual(["Sam Reyes"]);
    expect(after.league.organizers).toEqual(["Sam Reyes"]);
    // Someone who doesn't own the league can't change who runs it.
    expect(() => demo.leagueMemberSet(demo.leagueView("the-mountain-magic-series", null).league.id, theo.user_id, "organizer")).toThrow("Only the owner");
  });
});
