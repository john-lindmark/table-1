import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
import { toBundle, toPreview, toPublicEvent } from "./api";

/* event_bundle / event_public / event_preview (contract/privacy-lockdown-2026-10-18.md), decoded from what the real RPCs
   return: testdata/event-bundle/make.sh writes the fixtures from a database with every migration. */
const fixture = (name: string) =>
  JSON.parse(readFileSync(new URL(`../../../testdata/event-bundle/${name}.json`, import.meta.url), "utf8"));

describe("event reads", () => {
  it("decodes event_bundle as the screens expect", () => {
    const b = toBundle(fixture("bundle"));
    expect(b.event.shortCode).toBe("FIXT");
    expect(b.event.status).toBe("in_progress");
    expect(b.event.formatLabel).toBe("Draft · Murders at Karlov Manor");
    expect(b.participants.map((p) => p.displayName)).toEqual(["Ana Organizer", "Ben Player", "Guest Cara"]);
    expect(b.participants[2].userId).toBeNull();
    expect(b.rounds.map((r) => r.number)).toEqual([1, 2]);
    const played = b.rounds[0].matches[0];
    expect(played.sides.map((s) => s.gameWins)).toEqual([2, 1]);
    expect(played.gameDraws).toBe(1);
    expect(b.rounds[1].matches.map((m) => m.isBye)).toEqual([true, false]);
  });

  it("decodes event_public with no account ids", () => {
    const raw = fixture("public");
    expect(JSON.stringify(raw)).not.toContain("user_id");
    const e = toPublicEvent(raw);
    expect(e.name).toBe("Fixture draft");
    expect(e.round?.number).toBe(2);
    expect(e.round?.timerStatus).toBe("paused");
    expect(e.pairings.map((m) => (m.isBye ? "bye" : m.sides.map((s) => s.displayName).join(" vs ")))).toEqual(
      expect.arrayContaining(["Ana Organizer vs Ben Player", "bye"]),
    );
  });

  it("decodes event_preview, and a miss as nothing", () => {
    const p = toPreview(fixture("preview"));
    expect(p).toMatchObject({ shortCode: "FIXT", players: 3, organizerName: "Ana Organizer", access: "link" });
    expect(JSON.stringify(fixture("preview"))).not.toContain("user_id");
    expect(toPreview({ event_id: null, access: "none" })).toBeNull();
  });
});
