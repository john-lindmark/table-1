import { describe, expect, it } from "vitest";
import { canRedraft, redraftDetail, type RedraftCard } from "./redraft";

/* The redraft pile (contract/event-night-2026-10-16.md § 6), as iOS RedraftView and Android RedraftTest. */
describe("redraft", () => {
  const e = { formatName: "draft" as const, cubeName: null, cubeUrl: null, status: "completed" as const };
  it("is for finished set drafts only", () => {
    expect(canRedraft(e)).toBe(true);
    expect(canRedraft({ ...e, formatName: "team_draft" })).toBe(true);
    expect(canRedraft({ ...e, status: "in_progress" })).toBe(false);
    expect(canRedraft({ ...e, cubeName: "Vintage Cube" })).toBe(false);
    expect(canRedraft({ ...e, formatName: "sealed" })).toBe(false);
  });
  it("says printing, finish and who added it", () => {
    const c: RedraftCard = { id: "1", card_id: "x", finish: "foil", name: "Card", set: "mkm", cn: "12", usd: 3, added_by: "Ana", mine: false };
    expect(redraftDetail(c)).toBe("MKM 12 · Foil · Ana");
    expect(redraftDetail({ ...c, finish: "nonfoil", mine: true })).toBe("MKM 12 · You");
  });
});
