import { describe, expect, it } from "vitest";
import { isDemoLocation, personTarget, profilePath } from "./personLink";

// contract/friends-sharing-2026-10-18.md § Tapping a person
describe("personLink", () => {
  it("leaves guests untappable", () => {
    expect(personTarget(null)).toBeNull();
    expect(personTarget(undefined)).toBeNull();
    expect(personTarget("  ")).toBeNull();
  });
  it("opens the account's profile", () => {
    const id = "D0000000-0000-0000-0000-0000000F0001";
    expect(personTarget(id)).toBe(id.toLowerCase());
    expect(profilePath(personTarget(id)!)).toBe("/u/d0000000-0000-0000-0000-0000000f0001");
  });
  it("keeps the demos in the demo", () => {
    expect(isDemoLocation("/dev/events", "")).toBe(true);
    expect(isDemoLocation("/me", "?demo")).toBe(true);
    expect(isDemoLocation("/e/abc", "")).toBe(false);
    expect(profilePath("u1", true)).toBe("/u/u1?demo");
  });
});
