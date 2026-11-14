import { describe, expect, it } from "vitest";
import cases from "../../../testdata/leagues/cases.json";
import { formatClock } from "../components/kit";
import {
  bareAddress,
  clockText,
  clockWord,
  displayAuto,
  displayClock,
  displayPages,
  displayPath,
  displaySize,
  displayView,
  elapsedSeconds,
  fitScale,
  fitType,
  listScale,
  pageAt,
  pairingsByPlayer,
  pairingsByTable,
  parseShow,
  remainingSeconds,
  resultsCount,
  scaled,
  showForKey,
  MESSAGE_BAND,
  effectiveShow,
  extensionsLine,
  messageType,
  pinnedShow,
  type DisplayMatch,
  type DisplayRoom,
  type DisplayTimer,
} from "./display";
import { DEMO_DISPLAYS, demoDisplay } from "./displayDemo";

// The TV display (contract/public-events-leagues-2026-11-13.md § 5). The auto view and the paging are shared cases
// (testdata/leagues/cases.json from make_cases.py); the pairings lists and the clock's text are the web's own.

describe("display: shared cases (testdata/leagues)", () => {
  it("auto picks the view", () => {
    expect(cases.display_auto.length).toBeGreaterThan(0);
    for (const c of cases.display_auto) {
      expect(displayAuto(c.status, c.round, c.elapsed, c.results_in, c.matches, c.t), JSON.stringify(c)).toBe(c.want);
    }
  });

  it("pages lists by the screen's height", () => {
    expect(cases.display_pages.length).toBeGreaterThan(0);
    for (const c of cases.display_pages) {
      const got = displayPages(c.rows, c.height, c.row_height, c.header);
      expect({ per_page: got.perPage, pages: got.pages }, JSON.stringify(c)).toEqual(c.want);
    }
  });
});

describe("display: which view", () => {
  const live = { status: "in_progress", round: 2, roundOpen: true, elapsed: 900, resultsIn: 3, matches: 8, t: 50 };

  it("reads ?show=", () => {
    expect(parseShow(null)).toBe("auto");
    expect(parseShow("")).toBe("auto");
    expect(parseShow("clock")).toBe("clock");
    expect(parseShow("PAIRINGS")).toBe("pairings");
    expect(parseShow("standings")).toBe("standings");
    expect(parseShow("welcome")).toBe("auto");
    expect(parseShow("nonsense")).toBe("auto");
  });

  it("keys 1 2 3 pick a view and A goes back to auto", () => {
    expect(showForKey("1")).toBe("clock");
    expect(showForKey("2")).toBe("pairings");
    expect(showForKey("3")).toBe("standings");
    expect(showForKey("a")).toBe("auto");
    expect(showForKey("A")).toBe("auto");
    expect(showForKey("4")).toBeNull();
    expect(showForKey("ArrowRight")).toBeNull();
  });

  it("a picked view shows while a round runs; auto follows the rule", () => {
    expect(displayView("clock", live)).toBe("clock");
    expect(displayView("pairings", live)).toBe("pairings");
    expect(displayView("standings", live)).toBe("standings");
    expect(displayView("auto", live)).toBe("clock");
    expect(displayView("auto", { ...live, t: 100 })).toBe("standings");
    expect(displayView("auto", { ...live, elapsed: 60 })).toBe("pairings");
  });

  it("before round 1 is the welcome and after the finish the final standings, whatever was asked", () => {
    for (const show of ["auto", "clock", "pairings", "standings"] as const) {
      expect(displayView(show, { ...live, status: "setup", round: 0, roundOpen: false })).toBe("welcome");
      expect(displayView(show, { ...live, status: "seated", round: 0, roundOpen: false })).toBe("welcome");
      expect(displayView(show, { ...live, status: "completed", roundOpen: false })).toBe("standings");
      expect(displayView(show, { ...live, status: "archived", roundOpen: false })).toBe("standings");
    }
  });

  it("auto reads Standings between rounds, when no round is open", () => {
    expect(displayView("auto", { ...live, roundOpen: false, elapsed: 0, resultsIn: 0, matches: 0 })).toBe("standings");
    expect(displayView("clock", { ...live, roundOpen: false })).toBe("clock");
  });

  it("pages wrap both ways", () => {
    expect([0, 1, 2, 3, 6, 7].map((n) => pageAt(n, 3))).toEqual([0, 1, 2, 0, 0, 1]);
    expect(pageAt(-1, 3)).toBe(2);
    expect(pageAt(-4, 3)).toBe(2);
    expect(pageAt(5, 1)).toBe(0);
    expect(pageAt(5, 0)).toBe(0);
  });

  it("sizes rows from the window: 1080 tall is the reference's 72 px rows under 240 px", () => {
    const tv = displaySize(1920, 1080);
    expect(tv).toEqual({ unit: 1, row: 72, header: 240, wide: true });
    expect(displayPages(64, 1080, tv.row, tv.header)).toEqual({ perPage: 11, pages: 6 });
    const laptop = displaySize(1280, 720);
    expect(laptop.row).toBe(48);
    expect(laptop.header).toBe(160);
    expect(displayPages(64, 720, laptop.row, laptop.header).perPage).toBe(11);
    // A taller window than 16:9 fits more rows; a portrait one holds one list at a time.
    expect(displayPages(64, 800, displaySize(1280, 800).row, displaySize(1280, 800).header).perPage).toBe(13);
    expect(displaySize(800, 1200).wide).toBe(false);
    expect(displaySize(320, 200).row).toBeGreaterThanOrEqual(28);
  });

  it("a short list is drawn larger, never past its page", () => {
    expect(listScale(11, 11)).toBe(1);
    expect(listScale(64, 11)).toBe(1);
    expect(listScale(0, 11)).toBe(1);
    expect(listScale(10, 11)).toBeCloseTo(1.1);
    expect(listScale(8, 11)).toBeCloseTo(1.375);
    expect(listScale(2, 11)).toBe(1.6);
    for (let rows = 1; rows <= 11; rows++) {
      const big = scaled(displaySize(1920, 1080), listScale(rows, 11));
      expect(rows * big.row).toBeLessThanOrEqual(1080 - 240 + 24);
    }
    expect(scaled(displaySize(1920, 1080), 1.5)).toEqual({ unit: 1.5, row: 108, header: 240, wide: true });
    // …and never so large that a name is cut: 222 px of row plus two 12-character names in a 920 px list.
    expect(fitScale(1.6, 920, 222, 24, 30)).toBeCloseTo((0.96 * 920) / (222 + 24 * 30 * 0.61));
    expect(fitScale(1.6, 1888, 614, 12, 30)).toBe(1.6);
    expect(fitScale(1.6, 920, 222, 56, 30)).toBe(1);
    expect(fitScale(1, 920, 222, 10, 30)).toBe(1);
  });

  it("the address", () => {
    expect(displayPath("E1")).toBe("/d/E1");
    expect(displayPath("E1", "auto")).toBe("/d/E1");
    expect(displayPath("E1", "clock")).toBe("/d/E1?show=clock");
    expect(bareAddress("https://table-1.site/d/E1")).toBe("table-1.site/d/E1");
    expect(bareAddress("http://localhost:5173/d/E1/")).toBe("localhost:5173/d/E1");
  });
});

describe("display: pairings", () => {
  const match = (table: number | null, a: string, b: string | null, status = "pending", wins: [number, number] = [0, 0], gameDraws = 0): DisplayMatch => ({
    tableNumber: table, isBye: b == null, status: b == null ? "confirmed" : status, gameDraws,
    sides: [{ side: 0, displayName: a, gameWins: b == null ? 2 : wins[0] }, ...(b == null ? [] : [{ side: 1, displayName: b, gameWins: wins[1] }])],
  });
  // As event_public hands them over: no particular order, the bye without a table.
  const round = [
    match(3, "dee Okafor", "Bo Lindqvist"),
    match(null, "Cy Park", null),
    match(1, "Ann Ito", "Zed Åberg", "confirmed", [2, 1]),
    match(10, "Élise Moreau", "Ann Ito", "reported", [1, 1], 1),
    match(2, "Gus Varga", "Hal Brandt"),
  ];

  it("by table: tables in order, results in, byes last", () => {
    expect(pairingsByTable(round)).toEqual([
      { table: "1", a: "Ann Ito", b: "Zed Åberg", bye: false, score: "2–1" },
      { table: "2", a: "Gus Varga", b: "Hal Brandt", bye: false, score: null },
      { table: "3", a: "dee Okafor", b: "Bo Lindqvist", bye: false, score: null },
      { table: "10", a: "Élise Moreau", b: "Ann Ito", bye: false, score: "1–1–1" },
      { table: "BYE", a: "Cy Park", b: null, bye: true, score: null },
    ]);
  });

  it("A–Z: one row per player with their table and opponent; a bye reads BYE", () => {
    expect(pairingsByPlayer(round)).toEqual([
      // Two players with one name: both rows, by table.
      { name: "Ann Ito", table: "1", opponent: "Zed Åberg", bye: false },
      { name: "Ann Ito", table: "10", opponent: "Élise Moreau", bye: false },
      { name: "Bo Lindqvist", table: "3", opponent: "dee Okafor", bye: false },
      { name: "Cy Park", table: "BYE", opponent: null, bye: true },
      // Case and accents don't move a name out of its place.
      { name: "dee Okafor", table: "3", opponent: "Bo Lindqvist", bye: false },
      { name: "Élise Moreau", table: "10", opponent: "Ann Ito", bye: false },
      { name: "Gus Varga", table: "2", opponent: "Hal Brandt", bye: false },
      { name: "Hal Brandt", table: "2", opponent: "Gus Varga", bye: false },
      { name: "Zed Åberg", table: "1", opponent: "Ann Ito", bye: false },
    ]);
  });

  it("every player is on the A–Z list once, whatever the round", () => {
    expect(pairingsByPlayer([])).toEqual([]);
    expect(pairingsByTable([])).toEqual([]);
    const d = demoDisplay("demo")!;
    const rows = pairingsByPlayer(d.event.pairings);
    expect(rows).toHaveLength(64);
    expect(new Set(rows.map((r) => r.name)).size).toBe(64);
    expect(pairingsByTable(d.event.pairings).map((r) => r.table)).toEqual(Array.from({ length: 32 }, (_, i) => String(i + 1)));
    // A missing name or table never breaks a row.
    const odd: DisplayMatch = { tableNumber: null, isBye: false, status: "pending", gameDraws: 0, sides: [{ side: 0, displayName: "Ann Ito", gameWins: 0 }] };
    expect(pairingsByTable([odd])).toEqual([{ table: "–", a: "Ann Ito", b: "—", bye: false, score: null }]);
    expect(pairingsByPlayer([odd]).map((r) => r.name)).toEqual(["—", "Ann Ito"]);
  });

  it("results in: byes aren't matches", () => {
    expect(resultsCount(round)).toEqual({ resultsIn: 2, matches: 4 });
    expect(resultsCount([])).toEqual({ resultsIn: 0, matches: 0 });
  });
});

describe("display: clock", () => {
  const T0 = Date.parse("2026-11-13T18:00:00Z");
  const running = (remaining: number, startedSecondsAgo: number): DisplayTimer => ({
    timerStatus: "running", timerDurationSeconds: 3000, timerRemainingAtChange: remaining,
    timerLastStartedAt: new Date(T0 - startedSecondsAgo * 1000).toISOString(),
  });
  const paused = (remaining: number): DisplayTimer => ({
    timerStatus: "paused", timerDurationSeconds: 3000, timerRemainingAtChange: remaining, timerLastStartedAt: null,
  });

  it("running: counts down from when it last started", () => {
    const r = running(3000, 1579);
    expect(remainingSeconds(r, T0)).toBe(1421);
    expect(elapsedSeconds(r, T0)).toBe(1579);
    expect(displayClock(r, T0, true)).toEqual({ text: "23:41", state: "running" });
    expect(displayClock(r, T0 + 60_000, true)).toEqual({ text: "22:41", state: "running" });
    // Resumed after a pause: the time left at the resume, less what has run since.
    expect(displayClock(running(1200, 30), T0, true)).toEqual({ text: "19:30", state: "running" });
  });

  it("the last 5 minutes read low", () => {
    expect(displayClock(running(3000, 2699), T0, true)).toEqual({ text: "05:01", state: "running" });
    expect(displayClock(running(3000, 2700), T0, true)).toEqual({ text: "05:00", state: "low" });
    expect(displayClock(running(3000, 2999), T0, true)).toEqual({ text: "00:01", state: "low" });
  });

  it("over time: 00:00, then counting up behind a minus", () => {
    expect(displayClock(running(3000, 3000), T0, true)).toEqual({ text: "00:00", state: "over" });
    expect(displayClock(running(3000, 3135), T0, true)).toEqual({ text: "−02:15", state: "over" });
    expect(clockWord("over")).toBe("Time");
    expect(elapsedSeconds(running(3000, 3135), T0)).toBe(3135);
  });

  it("paused: holds its time, however long ago", () => {
    expect(displayClock(paused(1724), T0, true)).toEqual({ text: "28:44", state: "paused" });
    expect(displayClock(paused(1724), T0 + 3_600_000, true)).toEqual({ text: "28:44", state: "paused" });
    expect(elapsedSeconds(paused(1724), T0 + 3_600_000)).toBe(1276);
    expect(clockWord("paused")).toBe("Paused");
    // Paused before it ever ran: nothing has elapsed, so auto keeps the pairings up.
    expect(elapsedSeconds(paused(3000), T0)).toBe(0);
    // Paused past the end stays paused.
    expect(displayClock(paused(-20), T0, true)).toEqual({ text: "−00:20", state: "paused" });
  });

  it("timer off: no clock at all, and none without an open round", () => {
    expect(displayClock(running(3000, 600), T0, false)).toEqual({ text: null, state: "off" });
    expect(displayClock(null, T0, true)).toEqual({ text: null, state: "off" });
    expect(clockWord("off")).toBeNull();
    expect(clockWord("running")).toBeNull();
  });

  it("reads like every other round clock in the app", () => {
    for (const s of [0, 1, 59, 60, 61, 599, 600, 3000, 5999, 6000, -1, -135, -3600]) expect(clockText(s)).toBe(formatClock(s));
    // A started-at the browser can't read falls back to the paused reading instead of NaN.
    expect(remainingSeconds({ ...running(1800, 10), timerLastStartedAt: "not a date" }, T0)).toBe(1800);
  });

  it("the clock is as large as fits", () => {
    // 1920 × 1080: the height is the limit for "23:41", the width once a minus makes it six characters.
    expect(fitType("23:41", 1920 * 0.92, 920 * 0.62)).toBe(570);
    expect(fitType("−02:15", 1920 * 0.92, 920 * 0.62)).toBe(482);
    expect(fitType("23:41", 4000, 300)).toBe(300);
    expect(fitType("", 10, 10)).toBe(12);
  });
});

describe("display: demo events (dev)", () => {
  it("every stand-in event builds, with the states the views need", () => {
    for (const id of DEMO_DISPLAYS) expect(demoDisplay(id), id).not.toBeNull();
    expect(demoDisplay("nope")).toBeNull();
    const big = demoDisplay("demo", { now: 0 })!;
    expect(big.event.currentRound).toBe(2);
    expect(resultsCount(big.event.pairings)).toEqual({ resultsIn: 9, matches: 32 });
    expect(big.standings.rows).toHaveLength(64);
    expect(elapsedSeconds(big.event.round!, 0)).toBe(720);
    expect(resultsCount(demoDisplay("demo", { resultsIn: 32 })!.event.pairings).resultsIn).toBe(32);
    expect(elapsedSeconds(demoDisplay("demo", { now: 0, elapsed: 3100 })!.event.round!, 0)).toBe(3100);
    const small = demoDisplay("demo-small")!;
    expect(pairingsByTable(small.event.pairings).filter((r) => r.bye)).toHaveLength(1);
    expect(displayClock(small.event.round, Date.now(), small.event.showClock).state).toBe("paused");
    const team = demoDisplay("demo-team")!;
    expect(team.standings.teams?.map((t) => t.members.length)).toEqual([3, 3]);
    expect(demoDisplay("demo-off")!.event.showClock).toBe(false);
    const welcome = demoDisplay("demo-welcome")!;
    expect([welcome.event.currentRound, welcome.event.signUp, !!welcome.event.startsAt]).toEqual([0, "open", true]);
    const final = demoDisplay("demo-final")!;
    expect([final.event.status, final.event.round, final.standings.rows[0].rank]).toEqual(["completed", null, 1]);
  });
});

// The room tools on the display (contract/room-tools-2026-11-13.md §§ 1, 2).
describe("display: the organizer's remote, the announcement, extra time", () => {
  const room = (show: DisplayRoom["display"]["show"], message: string | null = null, extensions: DisplayRoom["extensions"] = []): DisplayRoom =>
    ({ display: { show, message }, extensions });

  it("follows the remote unless the address carries ?show= (the address wins)", () => {
    expect(effectiveShow(null, room("standings"))).toBe("standings");
    expect(effectiveShow("clock", room("standings"))).toBe("clock");
    // ?show=auto pins the display to auto whatever the remote says.
    expect(effectiveShow("auto", room("standings"))).toBe("auto");
    // No room (a server before the room tools, or a failed read): auto, as before.
    expect(effectiveShow(null, null)).toBe("auto");
    expect(effectiveShow(null, undefined)).toBe("auto");
  });

  it("reads the pin from the address", () => {
    expect(pinnedShow("pairings")).toBe("pairings");
    expect(pinnedShow("AUTO")).toBe("auto");
    expect(pinnedShow(null)).toBeNull();
    expect(pinnedShow("")).toBeNull();
    expect(pinnedShow("scores")).toBeNull();
  });

  it("the announcement: as large as fits one line, never under the size that wraps onto two", () => {
    const short = messageType("Lunch is in the back room", 1824, 1);
    expect(short).toBe(40);
    const long = messageType("x".repeat(140), 1824, 1);
    expect(long).toBe(26);
    // 140 characters at the smallest size fit two lines of the band.
    expect(Math.ceil((140 * long * 0.61) / 1824)).toBeLessThanOrEqual(2);
    expect(2 * long * 1.18).toBeLessThanOrEqual(MESSAGE_BAND);
    expect(messageType("Round 3 at 14:30", 912, 0.5)).toBe(20);
  });

  it("lists the tables on extra time in table order, for under the clock", () => {
    expect(extensionsLine(room("auto", null, [{ table_number: 9, extra_seconds: 300 }, { table_number: 5, extra_seconds: 180 }])))
      .toBe("TABLE 5 +3:00 · TABLE 9 +5:00");
    expect(extensionsLine(room("auto", null, [{ table_number: 4, extra_seconds: 0 }, { table_number: null, extra_seconds: 300 }]))).toBe("");
    expect(extensionsLine(null)).toBe("");
  });

  it("the demo displays carry a room: an announcement, extra time, the remote's pick", () => {
    const made = demoDisplay("demo-room", { now: Date.UTC(2026, 10, 13, 12) })!;
    expect(made.room?.display.message).toBeTruthy();
    expect(extensionsLine(made.room)).toBe("TABLE 9 +5:00 · TABLE 12 +3:00");
    expect(effectiveShow(null, demoDisplay("demo-remote")!.room)).toBe("standings");
    // Events without the room tools have no room at all, and `&message=` gives any of them an announcement.
    expect(demoDisplay("demo")!.room).toBeNull();
    expect(demoDisplay("demo", { message: "Hello" })!.room?.display).toEqual({ show: "auto", message: "Hello" });
  });
});
