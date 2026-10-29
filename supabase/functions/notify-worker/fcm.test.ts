// Android alert pushes through FCM (contract/event-night-2026-10-16.md § 4). `deno test notify-worker/`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { deadToken, fcmMessage } from "./fcm.ts";

test("fcm message: data only, strings, nulls left out", () => {
  const m = fcmMessage({
    token: "tok", title: "Round 2 is up", body: "Table 4 vs Ana", priority: 10, tag: "round.paired:e1", group: "e1",
    info: { kind: "round.paired", event_id: "e1", match_id: null, ranking_id: undefined, bug_id: 7, item_id: "" },
  });
  assert.deepEqual(m, {
    message: {
      token: "tok",
      data: { kind: "round.paired", event_id: "e1", bug_id: "7", title: "Round 2 is up", body: "Table 4 vs Ana", tag: "round.paired:e1", group: "e1" },
      android: { priority: "HIGH", ttl: "3600s" },
    },
  });
});

test("fcm message: priority 5 is NORMAL", () => {
  const m = fcmMessage({ token: "t", title: "a", body: "b", priority: 5, tag: "x", group: "wants", info: { kind: "want.price" } });
  assert.equal(m.message.android.priority, "NORMAL");
});

test("fcm dead tokens: unregistered and other projects only", () => {
  assert.equal(deadToken({ token: "t", status: 404, reason: "UNREGISTERED" }), true);
  assert.equal(deadToken({ token: "t", status: 403, reason: "SENDER_ID_MISMATCH" }), true);
  // A bad payload or a quota answer must never forget every Android phone.
  assert.equal(deadToken({ token: "t", status: 400, reason: "INVALID_ARGUMENT" }), false);
  assert.equal(deadToken({ token: "t", status: 429, reason: "QUOTA_EXCEEDED" }), false);
  assert.equal(deadToken({ token: "t", status: 0, reason: "TypeError" }), false);
});
