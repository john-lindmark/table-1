// Alert text for followed events (contract/event-follows-2026-11-09.md).
import { test } from "node:test";
import assert from "node:assert/strict";
import { eventFollowCopy } from "./event-follow.ts";

test("a round paired", () => {
  assert.deepEqual(eventFollowCopy("event.follow_round", { event_name: "Friday Modern", round: 2, of: 4, stage: "swiss" }),
    { title: "Friday Modern", body: "Round 2 of 4 is up. Tap for the pairings and standings." });
  assert.equal(eventFollowCopy("event.follow_round", { event_name: "Friday Modern", round: 5, of: 4, stage: "semifinal" }).body,
    "Semifinals is up. Tap for the pairings and standings.");
  assert.equal(eventFollowCopy("event.follow_round", { event_name: "X", round: 6, of: 4, stage: "final" }).body,
    "The final is up. Tap for the pairings and standings.");
  assert.equal(eventFollowCopy("event.follow_round", { round: 3 }).title, "An event you follow");
  assert.equal(eventFollowCopy("event.follow_round", { round: 3 }).body, "Round 3 is up. Tap for the pairings and standings.");
});

test("finished", () => {
  assert.deepEqual(eventFollowCopy("event.follow_done", { event_name: "Friday Modern" }), { title: "Friday Modern", body: "Final standings are up." });
});
