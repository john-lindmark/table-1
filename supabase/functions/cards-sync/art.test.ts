// cards-sync artist and frame mapping checks. Runs under Deno (`deno test`) and Node 23+ (`node --test art.test.ts`).
import { test } from "node:test";
import assert from "node:assert/strict";
import { artRow } from "./art.ts";

test("artist and frame come from the card, the front face standing in", () => {
  assert.deepEqual(artRow({ id: "c1", artist: "Shelly Wan", frame: "1997" }), { id: "c1", artist: "Shelly Wan", frame: "1997" });
  assert.deepEqual(artRow({ id: "c2", frame: "2015", card_faces: [{ artist: "Zezhou Chen" }, { artist: "Someone Else" }] }),
    { id: "c2", artist: "Zezhou Chen", frame: "2015" });
  assert.deepEqual(artRow({ id: "c3" }), { id: "c3", artist: "", frame: "" });
  assert.deepEqual(artRow({ id: "c4", artist: 7, frame: null }), { id: "c4", artist: "", frame: "" });
});
