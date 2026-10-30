// Android live messages (android.ts): data-only FCM with the state as JSON text, silent for players, the organizer's
// alerts kept. `deno test live-activity/`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { fcmMessage } from "../notify-worker/fcm.ts";
import { organizerMessage, organizerPlan, playerMessage, playerPlan } from "./android.ts";
import type { OrgState } from "./organizer.ts";
import type { PlayerState } from "./state.ts";

const ps = {
  userId: "u1", participantId: "p1",
  attributes: { eventId: "e1", eventName: "Friday Modern", participantId: "p1" },
  state: { phase: "playing", round: 2, rounds: 4, table: 3, status: "pending" },
} as unknown as PlayerState;

const org = {
  attributes: { eventId: "e1", eventName: "Friday Modern" },
  state: { phase: "live", round: 2, rounds: 4, matches: 8, done: 5, waiting: 3, disputes: 1, guestWaiting: 0 },
} as unknown as OrgState;

test("a player's update is silent and carries the snapshot the app decodes", () => {
  const m = fcmMessage(playerMessage("tok", ps, "update", 10)).message;
  assert.equal(m.data.kind, "live.player");
  assert.equal(m.data.event_id, "e1");
  assert.equal(m.data.title, "");
  assert.equal(m.android.priority, "HIGH");
  const live = JSON.parse(m.data.live);
  assert.equal(live.eventName, "Friday Modern");
  assert.equal(live.participantId, "p1");
  assert.equal(live.state.table, 3);
  assert.ok(Object.values(m.data).every((v) => typeof v === "string"), "FCM data values are strings");
});

test("an organizer's message keeps its alert", () => {
  const m = fcmMessage(organizerMessage("tok", org, "update", 10, { title: "Dispute at table 4", body: "Friday Modern" })).message;
  assert.equal(m.data.kind, "live.organizer");
  assert.equal(m.data.title, "Dispute at table 4");
  assert.equal(JSON.parse(m.data.live).state.done, 5);
  assert.equal(m.data.tag, "live:o:e1");
});

test("plans follow the APNs mapping", () => {
  assert.deepEqual(playerPlan("round_recorded"), { event: "update", priority: 5 });
  assert.deepEqual(playerPlan("dropped"), { event: "end", priority: 10 });
  assert.deepEqual(organizerPlan("dropped"), { event: "update", priority: 5 });
  assert.deepEqual(organizerPlan("event_ended"), { event: "end", priority: 10 });
  assert.equal(playerPlan("nonsense"), null);
});
