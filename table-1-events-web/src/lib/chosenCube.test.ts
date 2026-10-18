import { describe, expect, it } from "vitest";
import { chosenLibraryCube, type CardList } from "./lists";

// Create event / Setup → Details: which Library cube the cube fields point at (iOS: CubeFieldsTests).
const list = (id: string, kind: "deck" | "cube", name: string): CardList => ({
  id, kind, name, format: kind === "cube" ? "cube" : "modern",
  versions: [{ number: 1, at: 0, note: "", entries: [] }],
} as unknown as CardList);
const lists = [list("d1", "deck", "Vintage Cube"), list("c1", "cube", "Vintage Cube"), list("c2", "cube", "Pauper Cube"), list("c3", "cube", "pauper cube")];

describe("chosenLibraryCube", () => {
  it("matches a cube by name, ignoring case and spaces", () => {
    expect(chosenLibraryCube(lists, "  vintage CUBE ", "")?.id).toBe("c1");
  });
  it("never picks a deck with the same name", () => {
    expect(chosenLibraryCube([lists[0]], "Vintage Cube", "")).toBeUndefined();
  });
  it("a Cube Cobra link means it isn't the Library cube", () => {
    expect(chosenLibraryCube(lists, "Vintage Cube", "https://cubecobra.com/cube/overview/abc")).toBeUndefined();
  });
  it("no name, no match", () => {
    expect(chosenLibraryCube(lists, "  ", "")).toBeUndefined();
  });
  it("two cubes with one name: the first is the one selected", () => {
    expect(chosenLibraryCube(lists, "Pauper Cube", "")?.id).toBe("c2");
  });
});
