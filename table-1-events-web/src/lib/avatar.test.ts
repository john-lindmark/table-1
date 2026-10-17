import { describe, expect, it } from "vitest";
import { avatarColorIndex, avatarInitials, avatarSeed } from "./avatar";

// Expected values come from the iOS implementation (apps/ios/Table1/UI/Avatar.swift) run on the same inputs.
describe("avatar initials", () => {
  it.each([
    ["Jane van Dyke", "JD"],
    ["jane", "J"],
    ["  ", "?"],
    ["", "?"],
    ["(Bob) Smith-Jones", "BS"],
    ["émile zola", "ÉZ"],
    ["李 小龍", "李小"],
    ["- Ann -", "A"],
    ["42 Wallaby", "4W"],
  ])("%j → %s", (name, want) => {
    expect(avatarInitials(name)).toBe(want);
  });
});

describe("avatar color", () => {
  it.each([
    ["", 5],
    ["a", 4],
    ["jane", 1],
    ["jane van dyke", 7],
    ["3f2a9c1e-5b7d-4e8a-9c0f-1a2b3c4d5e6f", 7],
    ["00000000-0000-0000-0000-000000000000", 1],
    ["émile", 4],
  ])("%j → %i", (seed, want) => {
    expect(avatarColorIndex(seed)).toBe(want);
  });

  it("seeds from the lowercased account id, else the trimmed lowercased name", () => {
    expect(avatarSeed("3F2A9C1E-5B7D-4E8A-9C0F-1A2B3C4D5E6F", "x")).toBe("3f2a9c1e-5b7d-4e8a-9c0f-1a2b3c4d5e6f");
    expect(avatarSeed(null, "  Jane Van Dyke ")).toBe("jane van dyke");
  });
});
