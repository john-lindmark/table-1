import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  addDeckListCard, confirmDeckListLine, deckListCounts, deckListDeckEntries, deckListDeckFormat, deckListDeckName,
  deckListEntryWire, deckListRow, deckListSizeLine, deckListSkippedNote, deckListTarget, moveDeckListLine,
  replaceDeckListCard, setDeckListQty, toDeckListBrief, toDeckListEntry, toDeckPhotoList, type DeckListBoard, type DeckListEntry,
} from "./deckPhotoList";
import { toMyPhotos } from "./deckPhotos";

/* The decklist screen's rules (contract/deck-photo-lists-2026-11-13.md § Clients "Rules") against
   testdata/deck-photo-lists/cases.json (also iOS DeckPhotoListTests and Android DeckPhotoListTest). */

interface WireEntry { card_id: string | null; name: string; qty: number; board: string; sure: boolean; read?: string }
interface WireCard { card_id: string; name: string }
interface Cases {
  row: { brief: { status: string; cards: number; check: number; checked: boolean } | null; text: string }[];
  target: { event_type: string | null; format: string | null; target: number | null }[];
  counts: { entries: WireEntry[]; counts: { main: number; side: number; out: number; check: number } }[];
  sizeLine: { main: number; target: number | null; text: string }[];
  edits: { op: string; i?: number; qty?: number; board?: DeckListBoard; card?: WireCard; entries: WireEntry[]; out: WireEntry[] }[];
  deckEntries: { entries: WireEntry[]; out: { entries: [string, string, number][]; skipped: number } }[];
  deckName: { event: string | null; player: string | null; mine: boolean; name: string }[];
  deckFormat: { event_type: string | null; format: string | null; deck: string }[];
}
const c: Cases = JSON.parse(readFileSync(new URL("../../../testdata/deck-photo-lists/cases.json", import.meta.url), "utf8"));

const entries = (es: WireEntry[]): DeckListEntry[] => es.map(toDeckListEntry);
/** Back to the cases' shape: card_id always there (null without a card), read only when set. */
const wire = (es: DeckListEntry[]) => es.map((e) => ({ card_id: e.cardId, name: e.name, qty: e.qty, board: e.board, sure: e.sure, ...(e.read ? { read: e.read } : {}) }));
const card = (w: WireCard) => ({ cardId: w.card_id, name: w.name });

describe("deck photo lists (shared cases)", () => {
  it("has every group of cases", () => {
    for (const k of ["row", "target", "counts", "sizeLine", "edits", "deckEntries", "deckName", "deckFormat"] as const) {
      expect(c[k].length, k).toBeGreaterThan(0);
    }
  });

  it("words the row under a photo", () => {
    for (const r of c.row) expect(deckListRow(toDeckListBrief(r.brief)), JSON.stringify(r.brief)).toBe(r.text);
  });

  it("knows the main deck's size from the event", () => {
    for (const t of c.target) expect(deckListTarget(t.event_type, t.format), `${t.event_type} ${t.format}`).toBe(t.target);
  });

  it("counts boards and lines to check", () => {
    for (const k of c.counts) expect(deckListCounts(entries(k.entries))).toEqual(k.counts);
  });

  it("words the size line", () => {
    for (const s of c.sizeLine) expect(deckListSizeLine(s.main, s.target), `${s.main} of ${s.target}`).toBe(s.text);
  });

  it("edits the list", () => {
    for (const e of c.edits) {
      const before = entries(e.entries);
      const frozen = JSON.stringify(before);
      let out: DeckListEntry[];
      switch (e.op) {
        case "setQty": out = setDeckListQty(before, e.i!, e.qty!); break;
        case "move": out = moveDeckListLine(before, e.i!, e.board!); break;
        case "replace": out = replaceDeckListCard(before, e.i!, card(e.card!)); break;
        case "confirm": out = confirmDeckListLine(before, e.i!); break;
        case "add": out = addDeckListCard(before, card(e.card!), e.board!); break;
        default: throw new Error(`unknown op ${e.op}`);
      }
      const label = `${e.op} ${e.i ?? ""} ${e.qty ?? e.board ?? ""} ${e.card?.name ?? ""}`;
      expect(wire(out), label).toEqual(e.out);
      expect(JSON.stringify(before), `${label} left its input alone`).toBe(frozen);
    }
  });

  it("makes a deck's entries, leaving out lines without a card", () => {
    for (const d of c.deckEntries) expect(deckListDeckEntries(entries(d.entries))).toEqual(d.out);
  });

  it("names the deck", () => {
    for (const d of c.deckName) expect(deckListDeckName(d.event, d.player, d.mine), `${d.event} / ${d.player}`).toBe(d.name);
  });

  it("picks the deck's format", () => {
    for (const d of c.deckFormat) expect(deckListDeckFormat(d.event_type, d.format), `${d.format}`).toBe(d.deck);
  });
});

describe("deck photo lists on the wire", () => {
  it("reads an entry with its defaults and writes it as deck_photo_list_save takes it", () => {
    expect(toDeckListEntry({ name: "Room of", board: "nowhere" })).toEqual({ cardId: null, name: "Room of", qty: 1, board: "main", sure: true });
    expect(deckListEntryWire({ cardId: null, name: "Room of", qty: 1, board: "main", sure: false })).toEqual({ name: "Room of", qty: 1, board: "main", sure: false });
    expect(deckListEntryWire({ cardId: "i", name: "Island", qty: 16, board: "side", sure: false, read: "pile of about 16" }))
      .toEqual({ card_id: "i", name: "Island", qty: 16, board: "side", sure: false, read: "pile of about 16" });
  });

  it("reads the list with what a server may leave out", () => {
    const d = toDeckPhotoList({ photo_id: "p1", status: "done", entries: [{ card_id: "g", name: "Goblin Guide", qty: 2, board: "main", sure: true }],
                                reads_left: 4, editable: true, event: { name: "Friday draft", event_type: "limited", format: "draft" } });
    expect(d.entries).toEqual([{ cardId: "g", name: "Goblin Guide", qty: 2, board: "main", sure: true }]);
    expect([d.readsLeft, d.editable, d.mine, d.checked, d.turns, d.pool.size]).toEqual([4, true, false, false, 0, 0]);
    expect(d.event).toEqual({ name: "Friday draft", format: "draft", eventType: "limited", formatLabel: "" });
    expect(toDeckPhotoList({}).status).toBe("none");
  });

  it("puts a photo row's list on the photo, null when never queued", () => {
    const mine = toMyPhotos({ total: 2, events: 1, photos: [
      { id: "a", participant_id: "p", path: "e/a.jpg", list: { status: "done", cards: 40, check: 2, checked: false } },
      { id: "b", participant_id: "p", path: "e/b.jpg" },
    ] });
    expect(mine.photos[0].list).toEqual({ status: "done", cards: 40, check: 2, checked: false });
    expect(mine.photos[1].list).toBeNull();
  });

  it("says how many lines were left out", () => {
    expect(deckListSkippedNote(1)).toBe("1 line without a card was left out.");
    expect(deckListSkippedNote(2)).toBe("2 lines without a card were left out.");
  });
});
