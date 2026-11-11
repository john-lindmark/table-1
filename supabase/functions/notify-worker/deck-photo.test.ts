// Alert text for the deck photo nudge (contract/event-night-2026-10-16.md § 7).
import { test } from "node:test";
import assert from "node:assert/strict";
import { deckPhotoCopy } from "./deck-photo.ts";

test("last match in", () => {
  assert.deepEqual(deckPhotoCopy({ event_name: "Friday Modern", why: "last" }),
    { title: "Add your deck photo", body: "That was your last match in Friday Modern. Tap to add a photo of your deck." });
  assert.equal(deckPhotoCopy({ why: "last" }).body, "That was your last match. Tap to add a photo of your deck.");
});

test("event over", () => {
  assert.deepEqual(deckPhotoCopy({ event_name: "Friday Modern", why: "over" }),
    { title: "Add your deck photo", body: "Friday Modern is over. Tap to add a photo of your deck." });
  assert.equal(deckPhotoCopy({ event_name: "  ", why: "over" }).body, "Your event is over. Tap to add a photo of your deck.");
});
