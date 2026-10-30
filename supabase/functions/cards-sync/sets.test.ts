// cards-sync new-set search checks. Runs under Deno (`deno test`) and Node 23+ (`node --test sets.test.ts`).
import { test } from "node:test";
import assert from "node:assert/strict";
import { nextPage, setSearchUrl } from "./sets.ts";

test("a set's search asks for every printing", () => {
  assert.equal(setSearchUrl("fdn"),
    "https://api.scryfall.com/cards/search?q=e%3Afdn&unique=prints&include_extras=true&include_variations=true&order=set");
});

test("only Scryfall's own next page is followed", () => {
  assert.equal(nextPage({ has_more: true, next_page: "https://api.scryfall.com/cards/search?page=2" }), "https://api.scryfall.com/cards/search?page=2");
  assert.equal(nextPage({ has_more: true, next_page: "https://evil.example/cards" }), null);
  assert.equal(nextPage({ has_more: false, next_page: "https://api.scryfall.com/cards/search?page=2" }), null);
  assert.equal(nextPage({}), null);
});
