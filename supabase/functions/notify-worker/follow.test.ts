// follow.updated and trade.wants alert text (contract/follows-2026-10-25.md). `deno test notify-worker/`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { followCopy, nameList, tradeWantsCopy } from "./follow.ts";

test("name lists", () => {
  assert.equal(nameList([], 0), "");
  assert.equal(nameList(["Opt"], 1), "Opt");
  assert.equal(nameList(["Opt", "Bolt"], 2), "Opt and Bolt");
  assert.equal(nameList(["Opt", "Bolt", "Ponder"], 3), "Opt, Bolt and Ponder");
  assert.equal(nameList(["Opt", "Bolt", "Ponder"], 13), "Opt, Bolt, Ponder and 10 more");
  assert.equal(nameList([], 4), "4 more");
});

test("added and taken out", () => {
  assert.deepEqual(followCopy({ name: "Lindmark Cube", owner_name: "Ana Lind", added: 12, removed: 8,
    in: ["Sheoldred, the Apocalypse", "Fable of the Mirror-Breaker"], in_n: 12, out: ["Ragavan"], out_n: 8 }),
    { title: "Lindmark Cube", body: "Ana Lind added 12 cards and took out 8. In: Sheoldred, the Apocalypse, Fable of the Mirror-Breaker and 10 more." });
});

test("only added, only taken out", () => {
  assert.equal(followCopy({ name: "Burn", owner_name: "Ana Lind", added: 1, removed: 0, in: ["Opt"], in_n: 1 }).body,
    "Ana Lind added 1 card: Opt.");
  assert.equal(followCopy({ name: "Burn", owner_name: "Ana Lind", added: 0, removed: 3, out: ["Opt", "Bolt"], out_n: 2 }).body,
    "Ana Lind took out 3 cards: Opt and Bolt.");
});

test("missing names fall back", () => {
  assert.deepEqual(followCopy({ added: 2, removed: 0 }), { title: "Something you follow", body: "Someone added 2 cards." });
});

test("trade wants", () => {
  assert.deepEqual(tradeWantsCopy({ owner_name: "Ana Lind", n: 1, names: ["Opt"] }),
    { title: "Trade match", body: "Ana Lind put a card you want up for trade: Opt." });
  assert.equal(tradeWantsCopy({ owner_name: "Ana Lind", n: 5, names: ["Counterspell", "Opt", "Ponder"] }).body,
    "Ana Lind put 5 cards you want up for trade: Counterspell, Opt, Ponder and 2 more.");
});
