// Organizer Live Activity state (contract/widgets-2026-10-22.md). `deno test live-activity/`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildOrganizerState, organizerAlert } from "./organizer.ts";
import type { Match, Participant, RoundWithMatches } from "./types.ts";

const p = (id: string, userId: string | null, status: "active" | "dropped" = "active"): Participant =>
  ({ id, eventId: "e", podId: null, displayName: id, seat: null, status, droppedInRound: null, userId });

const players = [p("a", "ua"), p("b", "ub"), p("c", "uc"), p("d", "ud"), p("g1", null), p("g2", null), p("x", "ux", "dropped")];

const m = (id: string, a: string | null, b: string | null, status: Match["status"], extra: Partial<Match> = {}): Match => ({
  id, eventId: "e", roundId: "r2", tableNumber: null, isBye: false, gameDraws: 0, intentionalDraw: false, status,
  sides: [{ id: `${id}0`, matchId: id, participantId: a, side: 0, gameWins: 0 },
          { id: `${id}1`, matchId: id, participantId: b, side: 1, gameWins: 0 }],
  ...extra,
});

const round = (n: number, status: RoundWithMatches["status"], matches: Match[], timer: Partial<RoundWithMatches> = {}): RoundWithMatches => ({
  id: `r${n}`, eventId: "e", number: n, status, timerDurationSeconds: 3000, timerRemainingAtChange: 1200,
  timerStatus: "paused", timerLastStartedAt: null, matches, ...timer,
});

const event = { id: "e", name: "Friday Modern", status: "in_progress", current_round: 2, number_of_rounds: 3,
  round_length_seconds: 3000, show_clock: true };

const live = round(2, "active", [
  m("m1", "a", "b", "confirmed"),
  m("m2", "c", "d", "reported", { disputed: true }),
  m("m3", "g1", "g2", "pending"),
  m("bye", "x", null, "confirmed", { isBye: true }),
]);

test("live round: counts, disputes and guest-only matches", () => {
  const o = buildOrganizerState(event, players, [round(1, "recorded", []), live]);
  assert.equal(o.state.phase, "live");
  assert.equal(o.state.round, 2);
  assert.equal(o.state.matches, 3, "byes don't count");
  assert.equal(o.state.done, 1);
  assert.equal(o.state.waiting, 2);
  assert.equal(o.state.disputes, 1);
  assert.equal(o.state.guestWaiting, 1);
  assert.equal(o.state.players, 6, "dropped players don't count");
  assert.equal(o.state.pausedRemaining, 1200);
  assert.equal(o.state.endsAt, undefined);
  assert.deepEqual(o.attributes, { eventId: "e", eventName: "Friday Modern" });
});

test("a pending match with one account is not the organizer's to enter", () => {
  const o = buildOrganizerState(event, players, [round(2, "active", [m("m1", "a", "g1", "pending")])]);
  assert.equal(o.state.guestWaiting, 0);
  assert.equal(o.state.waiting, 1);
});

test("running clock gives endsAt; hidden clocks give neither", () => {
  const started = "2026-10-22T18:00:00Z";
  const running = round(2, "active", [], { timerStatus: "running", timerLastStartedAt: started, timerRemainingAtChange: 3000 });
  const o = buildOrganizerState(event, players, [running]);
  assert.equal(o.state.endsAt, Date.parse(started) / 1000 + 3000);
  const hidden = buildOrganizerState({ ...event, show_clock: false }, players, [running]);
  assert.equal(hidden.state.endsAt, undefined);
  assert.equal(hidden.state.pausedRemaining, undefined);
});

test("between rounds: last round's number, no clock, nothing waiting", () => {
  const o = buildOrganizerState(event, players, [round(1, "recorded", []), round(2, "recorded", [m("m1", "a", "b", "confirmed")])]);
  assert.equal(o.state.phase, "between");
  assert.equal(o.state.round, 2);
  assert.equal(o.state.matches, 0);
  assert.equal(o.state.pausedRemaining, undefined);
});

test("cancelled and completed events", () => {
  assert.equal(buildOrganizerState({ ...event, status: "cancelled" }, players, [live]).state.phase, "cancelled");
  const done = buildOrganizerState({ ...event, status: "completed" }, players, [live]);
  assert.equal(done.state.phase, "complete");
  assert.equal(done.state.pausedRemaining, undefined);
});

test("alerts: a new dispute, and the last result settling", () => {
  const o = buildOrganizerState(event, players, [live]);
  assert.equal(organizerAlert(o, { disputed: true }, 4)?.title, "Dispute at table 4");
  assert.equal(organizerAlert(o, { settled: true }), undefined, "two still waiting");
  const allIn = buildOrganizerState(event, players, [round(2, "active", [m("m1", "a", "b", "reported")])]);
  assert.equal(organizerAlert(allIn, { settled: true })?.title, "All results in · Pair round 3");
  const finalRound = buildOrganizerState({ ...event, current_round: 3 }, players, [round(3, "active", [m("m1", "a", "b", "confirmed")])]);
  assert.equal(organizerAlert(finalRound, { settled: true })?.title, "All results in · Finish event");
  assert.equal(organizerAlert(allIn, {}), undefined, "an edit that settles nothing doesn't alert");
});
