import { describe, expect, it } from "vitest";
import { deckPhotoSize } from "./deckPhotos";

describe("deck photo size", () => {
  it("brings the longest side down to 2048 px, keeping the shape", () => {
    expect(deckPhotoSize(4032, 3024)).toEqual({ width: 2048, height: 1536 });
    expect(deckPhotoSize(3024, 4032)).toEqual({ width: 1536, height: 2048 });
  });
  it("never upscales a small photo", () => {
    expect(deckPhotoSize(1200, 900)).toEqual({ width: 1200, height: 900 });
  });
});
