import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { deckPhotoSize, turnDeckPhoto, turnedSize } from "./deckPhotos";

/* Deck photo size and Rotate left / right (contract/event-night-2026-10-16.md § 7) against
   testdata/deck-photos/cases.json (also iOS DeckPhotoTests and Android DeckPhotosTest). */

interface Cases {
  turn: { turns: number; by: number; out: number }[];
  size: { width: number; height: number; turns: number; out: [number, number] }[];
}
const c: Cases = JSON.parse(readFileSync(new URL("../../../testdata/deck-photos/cases.json", import.meta.url), "utf8"));

describe("deck photo size", () => {
  it("brings the longest side down to 2048 px, keeping the shape", () => {
    expect(deckPhotoSize(4032, 3024)).toEqual({ width: 2048, height: 1536 });
    expect(deckPhotoSize(3024, 4032)).toEqual({ width: 1536, height: 2048 });
  });
  it("never upscales a small photo", () => {
    expect(deckPhotoSize(1200, 900)).toEqual({ width: 1200, height: 900 });
  });
  it("swaps the sides for a quarter turn (shared cases)", () => {
    for (const s of c.size) {
      const size = deckPhotoSize(s.width, s.height);
      const out = turnedSize(size.width, size.height, s.turns);
      expect([out.width, out.height], `${s.width}x${s.height} turned ${s.turns}`).toEqual(s.out);
    }
  });
});

describe("deck photo turns", () => {
  it("stays within 0-3 (shared cases)", () => {
    for (const t of c.turn) expect(turnDeckPhoto(t.turns, t.by), `${t.turns} by ${t.by}`).toBe(t.out);
  });
});
