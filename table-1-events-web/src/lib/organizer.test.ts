import { describe, expect, it } from "vitest";
import {
  applyClock,
  derivePhase,
  detailsFromEvent,
  detailsToInput,
  formatMmSs,
  gameRecord,
  groupMatches,
  liveAction,
  clinchText,
  liveSubtitle,
  matchDetail,
  matchGroupOf,
  matchTitle,
  matchValue,
  nameLookup,
  openMatchCount,
  phaseTabs,
  remainingSeconds,
  resolveTab,
  resultsSubtitle,
  roundCaption,
  setupSubtitle,
  startBlocker,
  startDialog,
} from "./organizer";
import type { EventStatus, Match, Participant, RoundWithMatches, Table1Event } from "./types";

let seq = 0;
function match(table: number, a: string, aWins: number, b: string | null, bWins: number, extra: Partial<Match> = {}): Match {
  const id = `m${++seq}`;
  const sides: Match["sides"] = [{ id: `${id}a`, matchId: id, participantId: a, side: 0, gameWins: aWins }];
  if (b) sides.push({ id: `${id}b`, matchId: id, participantId: b, side: 1, gameWins: bWins });
  return {
    id, eventId: "e1", roundId: "r1", tableNumber: table, isBye: !b, gameDraws: 0, intentionalDraw: false,
    status: b ? "pending" : "confirmed", sides, ...extra,
  };
}
const bye = (table: number, a: string) => match(table, a, 2, null, 0);

function round(number: number, matches: Match[], extra: Partial<RoundWithMatches> = {}): RoundWithMatches {
  return {
    id: `r${number}`, eventId: "e1", number, status: "active", timerDurationSeconds: 3000, timerRemainingAtChange: 3000,
    timerStatus: "paused", timerLastStartedAt: null, timerEndsAt: null, matches, ...extra,
  };
}

function event(extra: Partial<Table1Event> = {}): Table1Event {
  return {
    id: "e1", shortCode: "K7Q2", name: "Friday draft", format: "draft", status: "setup", numberOfRounds: 3, currentRound: 0,
    roundLengthSeconds: 3000, allowPlayerReporting: true, createdBy: "u1", cancelReason: null, formatName: "draft",
    formatLabel: "Draft", eventType: "limited", teamSize: null, setName: null, cubeName: null, cubeUrl: null, setCode: null,
    formatOther: null, cancelledAt: null, updatedAt: "2026-10-12T20:00:00Z", showClock: true, autoName: false, pairing: "swiss", topCut: 0, autoRounds: false,
    capacity: null, startsAt: null, venueName: null, decklists: "off", ...extra,
  };
}

const people: Participant[] = ["Alex", "Brit", "Casey", "Dee", "Eli"].map((n) => ({
  id: n, eventId: "e1", podId: null, displayName: n, seat: null, status: "active", droppedInRound: null,
}));
const nameOf = nameLookup(people);

describe("derivePhase", () => {
  const cases: [EventStatus, number, string][] = [
    ["setup", 0, "setup"],
    ["seated", 0, "setup"],
    ["setup", 1, "live"],
    ["seated", 2, "live"],
    ["in_progress", 0, "live"],
    ["in_progress", 3, "live"],
    ["completed", 3, "results"],
    ["archived", 3, "results"],
    ["cancelled", 0, "results"],
    ["cancelled", 2, "results"],
  ];
  it.each(cases)("%s with %i rounds → %s", (status, rounds, phase) => {
    expect(derivePhase(status, rounds)).toBe(phase);
  });
});

describe("phase tabs", () => {
  it("setup shows Seating for drafts and Teams for team events, Details last", () => {
    expect(phaseTabs("setup", { isTeam: false, isDraft: false })).toEqual(["players", "details"]);
    expect(phaseTabs("setup", { isTeam: false, isDraft: true })).toEqual(["players", "seating", "details"]);
    expect(phaseTabs("setup", { isTeam: true, isDraft: true })).toEqual(["players", "seating", "teams", "details"]);
    expect(phaseTabs("setup", { isTeam: true, isDraft: false })).toEqual(["players", "teams", "details"]);
  });
  it("live and results", () => {
    expect(phaseTabs("live", { isTeam: false, isDraft: true })).toEqual(["round", "standings", "players"]);
    expect(phaseTabs("live", { isTeam: true, isDraft: false })).toEqual(["round", "standings", "players", "teams"]);
    expect(phaseTabs("results", { isTeam: true, isDraft: true })).toEqual(["standings", "rounds", "players"]);
  });
  it("a phase change resets to the first tab", () => {
    const setup = phaseTabs("setup", { isTeam: false, isDraft: true });
    const live = phaseTabs("live", { isTeam: false, isDraft: true });
    expect(resolveTab(null, "setup", setup)).toBe("players");
    expect(resolveTab({ phase: "setup", tab: "details" }, "setup", setup)).toBe("details");
    // "players" exists in Live too, but the phase changed: back to Round.
    expect(resolveTab({ phase: "setup", tab: "players" }, "live", live)).toBe("round");
    // A tab that disappeared (format changed away from draft) falls back too.
    expect(resolveTab({ phase: "setup", tab: "seating" }, "setup", ["players", "details"])).toBe("players");
  });
});

describe("groupMatches", () => {
  it("orders Disputed, Waiting, Results in; byes last; by table inside each group", () => {
    const waiting2 = match(2, "Alex", 0, "Brit", 0);
    const disputed = match(4, "Casey", 2, "Dee", 1, { status: "reported", disputed: true });
    const confirmed = match(3, "Eli", 2, "Alex", 0, { status: "confirmed" });
    const reported = match(1, "Brit", 1, "Casey", 2, { status: "reported" });
    const waiting5 = match(5, "Dee", 0, "Eli", 0);
    const b = bye(6, "Eli");
    const g = groupMatches([b, waiting5, confirmed, disputed, waiting2, reported]);
    expect(g.disputed.map((m) => m.tableNumber)).toEqual([4]);
    expect(g.waiting.map((m) => m.tableNumber)).toEqual([2, 5]);
    expect(g.results.map((m) => m.tableNumber)).toEqual([1, 3, 6]);
    expect(g.results.at(-1)!.isBye).toBe(true);
  });

  it("a dispute the organizer settled is a result, not a dispute", () => {
    expect(matchGroupOf(match(1, "Alex", 2, "Brit", 0, { status: "confirmed", disputed: true }))).toBe("results");
    expect(matchGroupOf(match(1, "Alex", 2, "Brit", 0, { status: "reported", disputed: true }))).toBe("disputed");
    expect(matchGroupOf(bye(1, "Alex"))).toBe("results");
  });

  it("counts open matches (waiting + disputed), never byes", () => {
    const r = round(1, [
      match(1, "Alex", 0, "Brit", 0),
      match(2, "Casey", 2, "Dee", 1, { status: "reported", disputed: true }),
      match(3, "Eli", 2, "Alex", 0, { status: "reported" }),
      bye(4, "Eli"),
    ]);
    expect(openMatchCount(r)).toBe(2);
    expect(openMatchCount(null)).toBe(0);
  });

  it("row text: title, detail, value", () => {
    const disputed = match(4, "Casey", 2, "Dee", 1, { status: "reported", disputed: true });
    expect(matchTitle(disputed, nameOf)).toBe("T4 · Casey v Dee");
    expect(matchDetail(disputed, nameOf)).toBe("Reported differently · tap to set");
    expect(matchDetail(disputed, nameOf, "1–2")).toBe("Reported 2–1 and 1–2 · tap to set");
    expect(matchValue(disputed)).toBe("Set");

    const waiting = match(2, "Alex", 0, "Brit", 0);
    expect(matchDetail(waiting, nameOf)).toBe("No result yet");
    expect(matchValue(waiting)).toBe("Set");

    const reported = match(1, "Brit", 1, "Casey", 2, { status: "reported", reportedByParticipant: "Casey" });
    expect(matchDetail(reported, nameOf)).toBe("Reported by Casey");
    expect(matchValue(reported)).toBe("1–2");
    expect(matchDetail(match(1, "A", 2, "B", 0, { status: "confirmed", resultSource: "player" }), nameOf)).toBe("Confirmed");
    expect(matchDetail(match(1, "A", 2, "B", 0, { status: "confirmed", resultSource: "organizer" }), nameOf)).toBe(
      "Set by organizer",
    );

    const b = bye(6, "Eli");
    expect(matchTitle(b, nameOf)).toBe("Eli · Bye");
    expect(matchValue(b)).toBe("Bye");
  });
});

describe("round clock", () => {
  const t0 = Date.parse("2026-10-12T19:00:00Z");
  it("running: last_started_at + remaining_at_change; never below 0", () => {
    const r = round(1, [], { timerStatus: "running", timerLastStartedAt: new Date(t0).toISOString(), timerRemainingAtChange: 600 });
    expect(remainingSeconds(r, t0)).toBe(600);
    expect(remainingSeconds(r, t0 + 61_000)).toBe(539);
    expect(remainingSeconds(r, t0 + 601_000)).toBe(0);
  });
  it("running with only timer_ends_at; paused shows remaining_at_change", () => {
    const r = round(1, [], { timerStatus: "running", timerEndsAt: new Date(t0 + 90_000).toISOString() });
    expect(remainingSeconds(r, t0)).toBe(90);
    expect(remainingSeconds(round(1, [], { timerRemainingAtChange: 125 }), t0 + 999_999)).toBe(125);
  });
  it("formats m:ss", () => {
    expect(formatMmSs(3000)).toBe("50:00");
    expect(formatMmSs(245)).toBe("4:05");
    expect(formatMmSs(-3)).toBe("0:00");
  });
  it("pause, resume and +5 min mirror set_round_clock", () => {
    const running = round(1, [], { timerStatus: "running", timerLastStartedAt: new Date(t0).toISOString(), timerRemainingAtChange: 600 });
    const paused = applyClock(running, "pause", 300, t0 + 100_000);
    expect(paused).toMatchObject({ timerStatus: "paused", timerRemainingAtChange: 500, timerLastStartedAt: null, timerEndsAt: null });
    const resumed = applyClock(paused, "resume", 300, t0 + 200_000);
    expect(resumed.timerStatus).toBe("running");
    expect(remainingSeconds(resumed, t0 + 200_000)).toBe(500);
    const added = applyClock(resumed, "add", 300, t0 + 200_000);
    expect(remainingSeconds(added, t0 + 200_000)).toBe(800);
    expect(added.timerDurationSeconds).toBe(3300);
    const addedPaused = applyClock(paused, "add", 300, t0);
    expect(addedPaused).toMatchObject({ timerStatus: "paused", timerRemainingAtChange: 800 });
    // Pausing a paused clock changes nothing.
    expect(applyClock(paused, "pause", 300, t0)).toBe(paused);
  });
});

describe("bar and captions", () => {
  const t0 = Date.parse("2026-10-12T19:00:00Z");
  it("setup subtitle", () => {
    expect(setupSubtitle(event(), 8)).toBe("K7Q2 · Setup · 8 players · Draft");
    expect(setupSubtitle(event(), 1)).toBe("K7Q2 · Setup · 1 player · Draft");
  });
  it("live subtitle: time left, paused, time", () => {
    const e = event({ status: "in_progress", numberOfRounds: 4 });
    const running = round(2, [], { timerStatus: "running", timerLastStartedAt: new Date(t0).toISOString(), timerRemainingAtChange: 754 });
    expect(liveSubtitle(e, [round(1, [], { status: "recorded" }), running], t0)).toBe("Round 2 of 4 · 12:34 left · Draft");
    expect(liveSubtitle(e, [running], t0 + 800_000)).toBe("Round 2 of 4 · time · Draft");
    expect(liveSubtitle(e, [round(2, [])], t0)).toBe("Round 2 of 4 · paused · Draft");
    expect(liveSubtitle(e, [round(1, [], { status: "recorded" })], t0)).toBe("Round 1 of 4 · Draft");
  });
  it("round caption", () => {
    const e = event({ numberOfRounds: 4 });
    const matches = [
      match(1, "Alex", 0, "Brit", 0),
      match(2, "Casey", 2, "Dee", 1, { status: "reported", disputed: true }),
      match(3, "Eli", 2, "Alex", 0, { status: "confirmed" }),
      bye(4, "Eli"),
    ];
    expect(roundCaption(e, round(2, matches, { timerStatus: "running" }))).toBe("Round 2 of 4 · 1 of 3 results in · 1 disputed");
    expect(roundCaption(e, round(2, matches))).toBe("Paused · Round 2 of 4");
  });
  it("results subtitle: final and cancelled", () => {
    const date = (iso: string | null | undefined) => (iso ? iso.slice(5, 10) : "");
    const rounds = [round(1, [], { status: "recorded" }), round(2, [], { status: "recorded" })];
    expect(resultsSubtitle(event({ status: "completed" }), rounds, 8, date)).toBe("Final · 10-12 · 8 players · Draft");
    expect(
      resultsSubtitle(event({ status: "cancelled", cancelledAt: "2026-10-11T10:00:00Z", numberOfRounds: 4 }), rounds, 8, date),
    ).toBe("Cancelled · 10-11 · after round 2 of 4");
  });
});

describe("big actions", () => {
  it("start: blocked under 2 players or by a team problem; draft dialog copy", () => {
    expect(startBlocker(1, null)).toBe("Add at least 2 players");
    expect(startBlocker(4, "Every team needs 3 players")).toBe("Every team needs 3 players");
    expect(startBlocker(4, null)).toBeNull();
    expect(startDialog(event())).toEqual({
      title: "Start Friday draft?",
      message: "Pairs round 1 across the table and starts the 50-minute clock. Format, rounds and teams lock.",
    });
    expect(startDialog(event({ formatName: "modern", name: "Modern night", roundLengthSeconds: 2700 })).message).toBe(
      "Pairs round 1 and starts the 45-minute clock. Format, rounds and teams lock.",
    );
    expect(startDialog(event({ showClock: false })).message).toBe(
      "Pairs round 1 across the table and starts the round (clocks hidden). Format, rounds and teams lock.",
    );
  });
  it("live: waiting → pair next → finish on the last round", () => {
    const e = event({ status: "in_progress", numberOfRounds: 2 });
    const open = round(1, [match(1, "Alex", 0, "Brit", 0), match(2, "Casey", 0, "Dee", 0)]);
    expect(liveAction(e, [open])).toEqual({ kind: "waiting", open: 2, label: "Waiting on 2 results" });
    const oneOpen = round(1, [match(1, "Alex", 2, "Brit", 0, { status: "confirmed" }), match(2, "Casey", 0, "Dee", 0)]);
    expect(liveAction(e, [oneOpen]).label).toBe("Waiting on 1 result");
    const done1 = round(1, [match(1, "Alex", 2, "Brit", 0, { status: "reported" }), bye(2, "Eli")]);
    expect(liveAction(e, [done1])).toEqual({ kind: "pair", round: 2, label: "Pair round 2" });
    const done2 = round(2, [match(1, "Alex", 2, "Brit", 1, { status: "confirmed" })]);
    expect(liveAction(e, [{ ...done1, status: "recorded" }, done2])).toEqual({ kind: "finish", label: "Finish event" });
    // Between rounds (round recorded, next not paired yet).
    expect(liveAction(e, [{ ...done1, status: "recorded" }]).label).toBe("Pair round 2");
  });
  it("live: a clinched team lets the organizer finish early, but not over a dispute", () => {
    const e = event({ status: "in_progress", numberOfRounds: 3 });
    const clinch = { teamId: "A", name: "Alpha", matchWins: 5, opponentMatchWins: 1, remaining: 3 };
    const open = round(2, [match(1, "Alex", 2, "Brit", 0, { status: "confirmed" }), match(2, "Casey", 0, "Dee", 0)]);
    expect(liveAction(e, [open], clinch)).toEqual({ kind: "finish", label: "Finish event", clinch });
    const done = round(2, [match(1, "Alex", 2, "Brit", 0, { status: "confirmed" })]);
    expect(liveAction(e, [done], clinch)).toEqual({ kind: "finish", label: "Finish event", clinch, pairRound: 3 });
    const disputed = round(2, [match(1, "Alex", 2, "Brit", 0, { status: "reported", disputed: true }), match(2, "Casey", 0, "Dee", 0)]);
    expect(liveAction(e, [disputed], clinch).kind).toBe("waiting");
    expect(clinchText(clinch)).toBe("Team Alpha has clinched it: 5–1 in match wins with 3 matches left to play.");
  });

  it("live action: Swiss then the top 8", () => {
    const e = event({ formatName: "modern", numberOfRounds: 2, topCut: 8 });
    const done = (n: number, stage: RoundWithMatches["stage"] = "swiss") =>
      round(n, [match(1, "Alex", 2, "Brit", 0)], { status: "recorded", stage });
    expect(liveAction(e, [done(1)], null, 12).label).toBe("Pair round 2");
    expect(liveAction(e, [done(1), done(2)], null, 12)).toEqual({ kind: "cut", label: "Cut to top 8" });
    expect(liveAction(e, [done(1), done(2)], null, 8)).toEqual({ kind: "finish", label: "Finish event" });
    expect(liveAction(e, [done(1), done(2), done(3, "quarterfinal")], null, 12).label).toBe("Pair semifinals");
    expect(liveAction(e, [done(1), done(2), done(3, "quarterfinal"), done(4, "semifinal")], null, 12).label).toBe("Pair the final");
    expect(liveAction(e, [done(1), done(2), done(3, "quarterfinal"), done(4, "semifinal"), done(5, "final")], null, 12).kind).toBe("finish");
  });
});

describe("records and details", () => {
  it("game record skips byes and unreported matches", () => {
    const rounds = [
      round(1, [match(1, "Alex", 2, "Brit", 1, { status: "confirmed" }), bye(2, "Casey")]),
      round(2, [match(1, "Brit", 2, "Alex", 0, { status: "reported" }), match(2, "Casey", 0, "Alex", 0)]),
    ];
    expect(gameRecord("Alex", rounds)).toEqual({ won: 2, lost: 3 });
    expect(gameRecord("Casey", rounds)).toEqual({ won: 0, lost: 0 });
  });
  it("details: full state, only what applies to the format", () => {
    const s = detailsFromEvent(event({ setCode: "dsk", setName: "Duskmourn", roundLengthSeconds: 3000 }));
    expect(detailsToInput(s)).toEqual({
      name: "Friday draft", autoName: false, formatName: "draft", rounds: 3, showClock: true, setCode: "dsk", setName: "Duskmourn",
      cubeName: null, cubeUrl: null, teamSize: null, formatOther: null, topCut: 0, autoRounds: false, decklists: "off",
    });
    expect(detailsToInput({ ...s, formatName: "team_draft", teamSize: 4 }).teamSize).toBe(4);
    expect(detailsToInput({ ...s, product: "cube", cubeName: " Vintage Cube ", cubeUrl: "https://cubecobra.com/x" })).toMatchObject({
      setCode: null, setName: null, cubeName: "Vintage Cube", cubeUrl: "https://cubecobra.com/x",
    });
    expect(detailsToInput({ ...s, formatName: "other_constructed", formatOther: "Oathbreaker" })).toMatchObject({
      setCode: null, setName: null, cubeName: null, formatOther: "Oathbreaker", teamSize: null,
    });
    expect(detailsToInput({ ...s, showClock: false }).showClock).toBe(false);
    // Auto-named events never send a name; the server names them.
    expect(detailsToInput(detailsFromEvent(event({ autoName: true }))).name).toBeNull();
    expect(detailsToInput(detailsFromEvent(event({ autoName: true }))).autoName).toBe(true);
    // Any event can be named (2026-10-27); emptying the field goes back to the automatic name.
    expect(detailsToInput({ ...detailsFromEvent(event({ autoName: true })), name: " Store  Champs " })).toMatchObject({ name: "Store Champs", autoName: false });
    expect(detailsToInput({ ...s, name: "  " })).toMatchObject({ name: null, autoName: true });
    // Top 8, auto rounds and decklists only where they apply.
    const modern = detailsFromEvent(event({ formatName: "modern", topCut: 8, autoRounds: true, decklists: "required" }));
    expect(detailsToInput(modern)).toMatchObject({ topCut: 8, autoRounds: true, decklists: "required" });
    expect(detailsToInput({ ...modern, formatName: "team_sealed" })).toMatchObject({ topCut: 0, autoRounds: false, decklists: "off" });
  });
});
