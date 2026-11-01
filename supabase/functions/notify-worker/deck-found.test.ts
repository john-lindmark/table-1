// deck.found alert text (contract/deck-finder-2026-10-15.md § Jobs).
import { test } from "node:test";
import assert from "node:assert/strict";
import { deckFoundCopy } from "./deck-found.ts";

test("a deck: the headline, never the list", () => {
  assert.deepEqual(deckFoundCopy({ status: "deck", name: "Boros Energy", placement: "1st", event: "Modern Challenge 32", date: "2026-10-30", job_id: "j" }),
    { title: "Deck found", body: "Boros Energy · 1st · Modern Challenge 32 · 2026-10-30. Tap to create it." });
  assert.equal(deckFoundCopy({ status: "deck", name: "Affinity" }).body, "Affinity. Tap to create it.");
  assert.equal(deckFoundCopy({ status: "deck" }).body, "A list. Tap to create it.");
});

test("a question, nothing found, a failure", () => {
  assert.deepEqual(deckFoundCopy({ status: "question", question: "Which Energy deck?" }), { title: "Which deck?", body: "Which Energy deck? Tap to answer." });
  assert.deepEqual(deckFoundCopy({ status: "not_found", message: "No Premodern list this month." }), { title: "No list found", body: "No Premodern list this month." });
  assert.equal(deckFoundCopy({ status: "not_found" }).body, "Nothing suitable turned up. Try naming the archetype and format.");
  assert.deepEqual(deckFoundCopy({ status: "error", message: "The deck finder couldn't finish that search. Try again." }),
    { title: "Deck finder", body: "The deck finder couldn't finish that search. Try again." });
  assert.equal(deckFoundCopy({}).body, "The search couldn't finish. Try again.");
});
