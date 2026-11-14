import { describe, expect, it } from "vitest";
import cases from "../../../testdata/leagues/cases.json";
import {
  BOARD_KEYS, FORMAT_KEYS, NO_FILTERS, PRESETS, achievementPath, achievementText, boardLine, counter, dateText, eventLine,
  filterLabels, filtersWire, findPickOf, finishLine, foundEventPath, isFiltered, isMissing, leagueEventLine, leagueLine,
  leaguesError, loadFindFilters, memberActions, multiplierText, orderedLeagueEvents, placePoints, pointsWords, presetOf, qualifyWords,
  resultsPublic, rowLabel, standingLine, whenText, whenWindow,
  SEAT_FORMATS, aboutRulesLine, alertLine, cutChoices, dueText, extensionText, finalInvitable, finalLine, finalStateLabel, judgeLine, rulesLine, seatLabel, teamLine,
  type Achievement, type FinalRow, type FindFilters, type LeagueEvent,
} from "./leagues";
import {
  PAYOUT_PRESETS, centsOf, centsText, feeLine, money, paidWord, payDoneState, payTag, paymentsMessage, payoutPresetOf, payoutTotal, payoutWords,
  poolOf, prizeAt, prizePaidTag, prizeTable, stripeLine, unpaidConfirm, unpaidHeader, PaymentsError,
  type KeepKind, type PayMode, type PayStatus, type PayMethod,
} from "./money";
import { memberMenu, movedOrder, leaveTeamMessage, teamError, teamLink, tidyTeamCode, type MyTeam } from "./teamSignup";

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

// Teams, the cut, alerts, fees and the room (contracts teams-finals-alerts, entry-fees and room-tools, 2026-11-13):
// the same shared cases, the keys added for phases 2 to 4.
describe("phases 2 to 4: shared cases (testdata/leagues)", () => {
  it("money", () => {
    expect(cases.money.length).toBeGreaterThan(0);
    for (const c of cases.money) expect(money(c.cents), String(c.cents)).toBe(c.want);
    expect(money(-750)).toBe("-$7.50");
  });

  it("the cuts a format can have", () => {
    expect(cases.cut_choices.length).toBeGreaterThan(0);
    for (const c of cases.cut_choices) expect(cutChoices(c.format_name, c.pairing), `${c.format_name} ${c.pairing}`).toEqual(c.want);
  });

  it("seat formats and seat labels", () => {
    expect(SEAT_FORMATS).toEqual(cases.seat_formats);
    for (const c of cases.seat_label) expect(seatLabel(c.slot, c.seat_formats), JSON.stringify(c)).toBe(c.want);
  });

  it("a team's line", () => {
    for (const c of cases.team_line) expect(teamLine(c.team, c.team_size)).toBe(c.want);
  });

  it("the Alerts row", () => {
    for (const c of cases.alert_line) expect(alertLine(c.alert), JSON.stringify(c.alert)).toBe(c.want);
  });

  it("the fee on a data line", () => {
    for (const c of cases.fee_line) {
      expect(feeLine(c.fee as { amount_cents: number; pay_mode: PayMode } | null), JSON.stringify(c.fee)).toBe(c.want);
    }
  });

  it("payment tags", () => {
    for (const c of cases.pay_tag) {
      expect(payTag(c.payment as { status: PayStatus; method: PayMethod }), JSON.stringify(c.payment)).toBe(c.want);
    }
  });

  it("payout presets, in words and in all", () => {
    expect(PAYOUT_PRESETS).toEqual(cases.payout_presets);
    expect(cases.payout_words.length).toBeGreaterThan(0);
    for (const c of cases.payout_words) {
      expect(payoutWords(c.payout), JSON.stringify(c.payout)).toBe(c.want);
      expect(payoutTotal(c.payout), JSON.stringify(c.payout)).toBeCloseTo(c.total, 9);
    }
    expect(payoutPresetOf(cases.payout_presets.top4)).toBe("top4");
    expect(payoutPresetOf([{ through: 1, percent: 50 }])).toBe("custom");
    expect(payoutPresetOf([])).toBe("custom");
  });

  it("a place's prize", () => {
    expect(cases.prize_at.length).toBeGreaterThan(0);
    for (const c of cases.prize_at) expect(prizeAt(c.payout, c.pool_cents, c.place, c.share), JSON.stringify(c)).toBe(c.want);
    expect(prizeTable(cases.payout_presets.top4, 4860)).toEqual([
      { place: 1, amount_cents: 1944 }, { place: 2, amount_cents: 1215 }, { place: 3, amount_cents: 850 }, { place: 4, amount_cents: 850 }]);
    expect(prizeTable([], 4860)).toEqual([]);
  });

  it("the pool", () => {
    expect(cases.pool.length).toBeGreaterThan(0);
    for (const c of cases.pool) {
      expect(poolOf(c.entries, c.amount_cents, c.cut_cents, c.keep_kind as KeepKind, c.keep_value, c.added_cents), JSON.stringify(c)).toEqual(c.want);
    }
  });

  it("extra time", () => {
    for (const c of cases.extension_text) expect(extensionText(c.seconds), String(c.seconds)).toBe(c.want);
    expect(extensionText(null)).toBe("");
  });

  it("a judge call's line", () => {
    for (const c of cases.judge_line) expect(judgeLine(c.call, new Date(c.now)), JSON.stringify(c.call)).toBe(c.want);
  });

  it("the rules line", () => {
    for (const c of cases.rules_line) expect(rulesLine(c.rel, c.due), JSON.stringify(c)).toBe(c.want);
    // The deadline in the device's zone, 24-hour: the cases' "SAT 14 NOV 09:30".
    expect(dueText("2026-11-14T16:30:00Z", "America/Denver")).toBe("SAT 14 NOV 09:30");
    expect(aboutRulesLine({ rel: "competitive", decklist_due_at: "2026-11-14T16:30:00Z" }, "America/Denver")).toBe(cases.rules_line[0].want);
    expect(aboutRulesLine({}, "UTC")).toBe("");
    expect(aboutRulesLine(null)).toBe("");
  });
});

describe("entry fees: the rest of the wording", () => {
  it("amounts typed into a field", () => {
    expect(centsOf("25")).toBe(2500);
    expect(centsOf("$7.50")).toBe(750);
    expect(centsOf("1,400")).toBe(140000);
    expect(centsOf("0")).toBe(0);
    expect(centsOf("7.505")).toBeNull();
    expect(centsOf("abc")).toBeNull();
    expect(centsOf("")).toBeNull();
    expect(centsText(2500)).toBe("25");
    expect(centsText(140050)).toBe("1400.50");
  });

  it("what a player and an organizer read", () => {
    expect(paidWord({ method: "app" })).toBe("PAID");
    expect(paidWord({ method: "door" })).toBe("PAID AT THE DOOR");
    expect(paidWord({ method: "comp" })).toBe("COMP");
    expect(unpaidHeader(4)).toBe("4 UNPAID");
    expect(unpaidHeader(0)).toBe("");
    expect(unpaidConfirm(4)).toBe("4 players haven't paid. Pair anyway?");
    expect(unpaidConfirm(1)).toBe("1 player hasn't paid. Pair anyway?");
    expect(prizePaidTag("cash")).toBe("PAID · CASH");
    expect(prizePaidTag("store credit")).toBe("PAID · STORE CREDIT");
    expect(prizePaidTag("other")).toBe("PAID");
    expect(prizePaidTag(null)).toBe("PAID");
    expect(stripeLine(null)).toBe("NOT CONNECTED");
    expect(stripeLine({ connected: true, ready: false })).toBe("FINISH SETTING UP");
    expect(stripeLine({ connected: true, ready: true })).toBe("READY");
  });

  it("a return from checkout proves nothing: the page says what event_money says", () => {
    const me = (status: PayStatus) => ({ fee: null, me: { participant_id: "p", status, method: null, can_pay: true, can_refund: false } });
    expect(payDoneState(false, me("paid"))).toBe("paid");
    expect(payDoneState(true, me("paid"))).toBe("paid");          // paid in another tab, then Back from a second checkout
    expect(payDoneState(false, me("pending"))).toBe("pending");
    expect(payDoneState(false, me("unpaid"))).toBe("pending");
    expect(payDoneState(true, me("unpaid"))).toBe("cancelled");
    expect(payDoneState(false, null)).toBe("unknown");            // signed out here: the app can see it, this page can't
    expect(payDoneState(false, { fee: null })).toBe("unknown");
  });

  it("the payments function's refusals: its own words, and the plain line before Table 1's keys exist", () => {
    expect(paymentsMessage(new PaymentsError("whatever the function said", 503))).toBe("Payments aren't set up yet");
    expect(new PaymentsError("x", 503).off).toBe(true);
    expect(paymentsMessage(new PaymentsError("Connect Stripe before taking payments in the app", 409))).toBe("Connect Stripe before taking payments in the app");
    expect(paymentsMessage(null)).toBe("Couldn't reach payments. Check your connection.");
  });
});

describe("teams that sign themselves up", () => {
  const team: MyTeam = {
    id: "t", name: "Glacial Chasm", captain_id: "u1", join_code: "GLCH7K2M", complete: true,
    members: [{ participant_id: "p1", user_id: "u1", name: "Ann", slot: 1 }, { participant_id: "p2", user_id: "u2", name: "Bo", slot: 2 },
              { participant_id: "p3", user_id: null, name: "Cy", slot: 3 }],
  };

  it("a code as typed, pasted or carried by a link", () => {
    expect(tidyTeamCode("glch7k2m")).toBe("GLCH7K2M");
    expect(tidyTeamCode(" GLCH-7K2M ")).toBe("GLCH7K2M");
    expect(tidyTeamCode("https://table-1.site/s/8f3c?team=glch7k2m")).toBe("GLCH7K2M");
    expect(tidyTeamCode("GLCH7K2MEXTRA")).toBe("GLCH7K2M");
    expect(teamLink("https://table-1.site", "8f3c", "GLCH7K2M")).toBe("https://table-1.site/s/8f3c?team=GLCH7K2M");
  });

  it("the captain's menu on a member", () => {
    expect(memberMenu(team, team.members[0])).toEqual(["down"]);                       // the captain: only moving
    expect(memberMenu(team, team.members[1])).toEqual(["up", "down", "captain", "remove"]);
    expect(memberMenu(team, team.members[2])).toEqual(["up", "remove"]);               // a guest can't be captain
    expect(movedOrder(team, "p2", -1)).toEqual(["p2", "p1", "p3"]);
    expect(movedOrder(team, "p3", 1)).toEqual(["p1", "p2", "p3"]);
  });

  it("leaving: the captain's confirm says who takes over", () => {
    expect(leaveTeamMessage(team, "u1")).toBe("You leave the event. Bo becomes captain.");
    expect(leaveTeamMessage(team, "u2")).toBe("You leave the event. Your seat on the team opens.");
    expect(leaveTeamMessage({ ...team, members: [team.members[0]] }, "u1")).toBe("You leave the event and the team closes.");
  });

  it("the server's refusals in words", () => {
    expect(teamError({ code: "P0002", message: "x" })).toBe("No team has that code.");
    expect(teamError({ code: "23505", message: "x" })).toBe("Another team has that name.");
    expect(teamError({ code: "55000", message: "The event is full" })).toBe("The event is full");
  });
});

describe("a season's final", () => {
  const row = (state: FinalRow["state"], user = true): FinalRow =>
    ({ key: `k-${state}-${user}`, user_id: user ? "u" : null, name: "N", rank: 1, points: 10, how: "winner", state });

  it("the Qualified row and each player's state", () => {
    const qualified = [row("in"), row("in"), row("invited"), row("declined"), row("none"), row("guest", false)];
    expect(finalLine({ qualified })).toBe("2 of 6 in");
    expect(finalStateLabel("in")).toBe("IN");
    expect(finalStateLabel("guest")).toBe("GUEST");
    expect(finalStateLabel("none")).toBeNull();          // the Invite button
    // Invite the qualified reaches whoever has an account and isn't in, invited or declined already.
    expect(finalInvitable(qualified).map((r) => r.state)).toEqual(["none"]);
  });
});
