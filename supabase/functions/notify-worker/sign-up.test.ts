// event.signed_up / event.dropped alert text (contract/scheduled-events-2026-10-27.md § Organizer pushes).
import { test } from "node:test";
import assert from "node:assert/strict";
import { signUpCopy } from "./sign-up.ts";

test("signed up, capped event", () => {
  assert.deepEqual(signUpCopy("event.signed_up", { event_name: "Friday Modern", name: "Ana", waitlist: false },
    { players: 12, capacity: 16, waiting: 0 }),
    { title: "Friday Modern", body: "Ana signed up · 12/16 players" });
});

test("no cap, one player", () => {
  assert.deepEqual(signUpCopy("event.signed_up", { event_name: "Draft", name: "Ana", waitlist: false },
    { players: 1, capacity: null, waiting: 0 }).body, "Ana signed up · 1 player");
});

test("waitlist in and out", () => {
  assert.equal(signUpCopy("event.signed_up", { name: "Bea", waitlist: true }, { players: 16, capacity: 16, waiting: 3 }).body,
    "Bea joined the waitlist · 16/16 players · 3 waiting");
  assert.equal(signUpCopy("event.dropped", { name: "Bea", waitlist: true }, { players: 16, capacity: 16, waiting: 2 }).body,
    "Bea left the waitlist · 16/16 players · 2 waiting");
});

test("dropped, count read later", () => {
  assert.deepEqual(signUpCopy("event.dropped", { event_name: "Friday Modern", name: "Cal", waitlist: false }, null),
    { title: "Friday Modern", body: "Cal dropped." });
  assert.equal(signUpCopy("event.dropped", { name: "Cal" }, { players: 7, capacity: 8, waiting: 0 }).body, "Cal dropped · 7/8 players");
});
