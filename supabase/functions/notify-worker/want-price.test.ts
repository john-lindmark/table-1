// want.price alert text (contract/want-prices-2026-10-26.md). `deno test notify-worker/`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { wantPriceCopy } from "./want-price.ts";

test("one drop", () => {
  assert.deepEqual(wantPriceCopy({ n: 1, names: ["Counterspell"], name: "Counterspell", price: 7.5, pct: 25, reason: "drop", max: null }),
    { title: "Price alert", body: "Counterspell is $7.50, 25% under its 30-day average." });
});

test("under the max", () => {
  assert.deepEqual(wantPriceCopy({ n: 1, names: ["Lightning Bolt"], name: "Lightning Bolt", price: 1.4, pct: 22, reason: "under_max", max: 1.5 }),
    { title: "Price alert", body: "Lightning Bolt is $1.40, under your max of $1.50." });
});

test("several", () => {
  assert.deepEqual(wantPriceCopy({ n: 2, names: ["Lightning Bolt", "Counterspell"], name: "Lightning Bolt", price: 1.4, reason: "under_max", max: 1.5 }),
    { title: "Price alerts", body: "Lightning Bolt is $1.40, under your max of $1.50. Also cheaper: Counterspell." });
  assert.deepEqual(wantPriceCopy({ n: 6, names: ["Counterspell", "Opt", "Ponder"], name: "Counterspell", price: 8, pct: 20, reason: "drop" }),
    { title: "Price alerts", body: "Counterspell is $8.00, 20% under its 30-day average. Also cheaper: Opt, Ponder and 3 more." });
});
