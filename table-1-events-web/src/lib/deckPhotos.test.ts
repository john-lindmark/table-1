import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { deckPhotoDone, deckPhotoPrompt, deckPhotoSize, deckPhotoWhyLabel, myDeckPhotoDetail, promptRounds, type DeckPhotoWhy, type PromptRound, myDeckPhotoGroups, myDeckPhotoSummary, toMyPhotos, toPhotos, turnDeckPhoto, turnedSize } from "./deckPhotos";

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

describe("your deck photos on your account (shared cases)", () => {
  interface Mine {
    summary: { total: number; events: number; out: string }[];
    groups: { photos: { id: string; event_id: string; event_name: string }[]; out: { event_id: string; title: string; ids: string[] }[] }[];
  }
  const m = c as unknown as Mine;
  it("says how many photos and events", () => {
    for (const s of m.summary) expect(myDeckPhotoSummary(s.total, s.events)).toBe(s.out);
  });
  it("heads consecutive photos of one event", () => {
    for (const g of m.groups) {
      const out = myDeckPhotoGroups(g.photos.map((p) => ({ id: p.id, eventId: p.event_id, eventName: p.event_name })));
      expect(out.map((x) => ({ event_id: x.eventId, title: x.title, ids: x.photos.map((p) => p.id) }))).toEqual(g.out);
    }
  });
  it("reads the server's rows and leaves out a format the name says", () => {
    const mine = toMyPhotos({ total: 1, events: 1, photos: [{ id: "d1", participant_id: "p1", player: "Bea", path: "e/d1.jpg",
      note: "", created_at: "2026-11-06T10:00:00+00:00", turns: 1, mine: true, editable: true, event_id: "e1",
      event_name: "Old draft", event_status: "completed", format_label: "Draft", event_at: "2026-10-29T18:00:00+00:00" }] });
    expect(mine.photos[0]).toMatchObject({ id: "d1", turns: 1, eventId: "e1", eventStatus: "completed" });
    expect(myDeckPhotoDetail(mine.photos[0])).toMatch(/2026$/);
    expect(myDeckPhotoDetail({ ...mine.photos[0], eventName: "Old" })).toMatch(/2026 · Draft$/);
  });
});

interface PromptCase {
  name: string;
  event: { status: string; rounds: number; top_cut?: number };
  me: { status: string; dropped_in_round: number | null } | null;
  rounds: PromptRound[];
  photo: boolean;
  why: DeckPhotoWhy | null;
  show: "add" | "added" | null;
}
const prompt: { cases: PromptCase[] } = JSON.parse(readFileSync(new URL("../../../testdata/deck-photos/prompt.json", import.meta.url), "utf8"));

describe("deck photo prompt (shared cases)", () => {
  it("has cases", () => expect(prompt.cases.length).toBeGreaterThan(10));
  for (const pc of prompt.cases) {
    it(pc.name, () => {
      const why = deckPhotoDone({ status: pc.event.status, rounds: pc.event.rounds, topCut: pc.event.top_cut ?? 0 },
        pc.me && { status: pc.me.status, droppedInRound: pc.me.dropped_in_round }, pc.rounds);
      expect(why).toBe(pc.why);
      expect(deckPhotoPrompt(why, pc.photo ? 1 : 0)).toBe(pc.show);
    });
  }
  it("reads your own side from the bundle", () => {
    const rounds = promptRounds([{ number: 1, stage: "swiss", matches: [
      { isBye: false, status: "confirmed", sides: [{ participantId: "b", gameWins: 2 }, { participantId: "a", gameWins: 1 }] },
    ] }], "a");
    expect(rounds[0].mine).toEqual({ bye: false, status: "confirmed", my: 1, their: 2 });
    expect(deckPhotoWhyLabel("last")).toBe("Last match in");
  });
});

describe("who may turn a photo", () => {
  const row = { id: "d1", participant_id: "p1", player: "Bea", path: "e/d1.jpg", note: "", created_at: "", turns: 0, mine: false };
  it("the organizer turns a player's photo but doesn't edit it", () => {
    expect(toPhotos({ photos: [{ ...row, editable: false, turnable: true }] }).photos[0]).toMatchObject({ editable: false, turnable: true });
  });
  it("servers before 2026-11-13 send no turnable: it follows editable", () => {
    expect(toPhotos({ photos: [{ ...row, editable: true }] }).photos[0].turnable).toBe(true);
    expect(toPhotos({ photos: [{ ...row, editable: false }] }).photos[0].turnable).toBe(false);
  });
});
