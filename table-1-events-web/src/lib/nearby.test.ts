import { describe, expect, it } from "vitest";
import { nearbyDetail } from "./nearby";

describe("nearby", () => {
  it("says distance, format, players and venue", () => {
    const e = { event_id: "e", name: "Draft", venue_name: "Denver Card Shop", format: "draft", status: "setup", players: 6, capacity: 8, distance_m: 45, joined: false };
    expect(nearbyDetail(e)).toBe("45 m · draft · 6/8 players · Denver Card Shop");
    expect(nearbyDetail({ ...e, venue_name: null, capacity: null })).toBe("45 m · draft · 6 players");
  });
});
