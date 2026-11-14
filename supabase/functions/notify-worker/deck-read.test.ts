// Alert text for a decklist read from a deck photo (contract/deck-photo-lists-2026-11-13.md).
import { test } from "node:test";
import assert from "node:assert/strict";
import { deckReadCopy } from "./deck-read.ts";

test("a clean read", () => {
  assert.deepEqual(deckReadCopy({ event_name: "Friday draft", cards: 40, check: 0 }),
    { title: "Your decklist is ready", body: "40 cards read from your deck photo from Friday draft. Tap to check it and add it to your decks." });
});

test("lines to check, no event name, one card", () => {
  assert.equal(deckReadCopy({ cards: 38, check: 3 }).body, "38 cards read from your deck photo, 3 to check. Tap to correct it and add it to your decks.");
  assert.equal(deckReadCopy({ event_name: " ", cards: 1 }).body, "1 card read from your deck photo. Tap to check it and add it to your decks.");
});
