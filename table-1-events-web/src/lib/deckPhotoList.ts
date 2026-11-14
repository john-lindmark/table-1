import { supabase } from "./supabaseClient";

/* The decklist read from a deck photo (contract/deck-photo-lists-2026-11-13.md): the list beside the photo,
   corrections by whoever may edit the photo, and Add to my decks for everyone who sees it. Same rules as iOS
   DeckPhotoList and Android DeckPhotoList, checked against testdata/deck-photo-lists/cases.json. */

export type DeckListBoard = "main" | "side" | "out";

/** One line of a photo's decklist. `cardId` null = a title the reader couldn't match to a card. */
export interface DeckListEntry {
  cardId: string | null;
  name: string;
  qty: number;
  board: DeckListBoard;
  sure: boolean;
  /** What the reader saw, for a line to check ("pile of about 7, no die"). */
  read?: string;
}

/** A photo row's `list`: where its decklist stands. */
export interface DeckListBrief {
  status: string;
  cards: number;
  check: number;
  checked: boolean;
}

export interface DeckPhotoListData {
  photoId: string;
  eventId: string;
  player: string;
  path: string;
  turns: number;
  /** none | queued | reading | done | failed */
  status: string;
  steps: string[];
  entries: DeckListEntry[];
  message: string;
  notes: string;
  pool: { kind: string; label: string; size: number };
  checked: boolean;
  editable: boolean;
  mine: boolean;
  readsLeft: number;
  event: { name: string; format: string; eventType: string; formatLabel: string };
}

export interface DeckListCounts { main: number; side: number; out: number; check: number }
export interface DeckListCard { cardId: string; name: string }

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function toDeckListBrief(raw: any): DeckListBrief | null {
  if (!raw || typeof raw !== "object") return null;
  return { status: String(raw.status ?? "done"), cards: Number(raw.cards ?? 0) || 0, check: Number(raw.check ?? 0) || 0, checked: !!raw.checked };
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function toDeckListEntry(raw: any): DeckListEntry {
  const board = raw?.board === "side" || raw?.board === "out" ? raw.board : "main";
  const e: DeckListEntry = {
    cardId: raw?.card_id ? String(raw.card_id) : null, name: String(raw?.name ?? ""), qty: Number(raw?.qty ?? 1) || 1, board,
    sure: raw?.sure == null ? true : !!raw.sure,
  };
  if (raw?.read) e.read = String(raw.read);
  return e;
}

/** An entry as `deck_photo_list_save` takes it. */
export function deckListEntryWire(e: DeckListEntry): Record<string, string | number | boolean> {
  return {
    ...(e.cardId ? { card_id: e.cardId } : {}), name: e.name, qty: e.qty, board: e.board, sure: e.sure,
    ...(e.read ? { read: e.read } : {}),
  };
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function toDeckPhotoList(raw: any): DeckPhotoListData {
  return {
    photoId: String(raw?.photo_id ?? ""), eventId: String(raw?.event_id ?? ""), player: String(raw?.player ?? ""),
    path: String(raw?.path ?? ""), turns: Number(raw?.turns ?? 0) || 0, status: String(raw?.status ?? "none"),
    steps: Array.isArray(raw?.steps) ? raw.steps.map(String) : [],
    entries: Array.isArray(raw?.entries) ? raw.entries.map(toDeckListEntry) : [],
    message: String(raw?.message ?? ""), notes: String(raw?.notes ?? ""),
    pool: { kind: String(raw?.pool?.kind ?? ""), label: String(raw?.pool?.label ?? ""), size: Number(raw?.pool?.size ?? 0) || 0 },
    checked: !!raw?.checked, editable: !!raw?.editable, mine: !!raw?.mine, readsLeft: Number(raw?.reads_left ?? 0) || 0,
    event: {
      name: String(raw?.event?.name ?? ""), format: String(raw?.event?.format ?? ""),
      eventType: String(raw?.event?.event_type ?? ""), formatLabel: String(raw?.event?.format_label ?? ""),
    },
  };
}

export const deckListReading = (d: { status: string } | null | undefined): boolean => d?.status === "queued" || d?.status === "reading";

export async function loadDeckPhotoList(photoId: string): Promise<DeckPhotoListData> {
  const { data, error } = await supabase.rpc("deck_photo_list", { p_photo_id: photoId });
  if (error) throw error;
  return toDeckPhotoList(data);
}

/** Queues a read (the first, or again for editors); the list as it stands comes back. */
export async function startDeckPhotoRead(photoId: string): Promise<DeckPhotoListData> {
  const { data, error } = await supabase.rpc("deck_photo_read_start", { p_photo_id: photoId });
  if (error) throw error;
  return toDeckPhotoList(data);
}

export async function saveDeckPhotoList(photoId: string, entries: DeckListEntry[]): Promise<DeckPhotoListData> {
  const { data, error } = await supabase.rpc("deck_photo_list_save", { p_photo_id: photoId, p_entries: entries.map(deckListEntryWire) });
  if (error) throw error;
  return toDeckPhotoList(data);
}

/* ── rules ─────────────────────────────────────────────────────────────── */

const cards = (n: number) => `${n} ${n === 1 ? "card" : "cards"}`;

/** The line under a photo. */
export function deckListRow(brief: DeckListBrief | null | undefined): string {
  if (!brief) return "Read decklist";
  if (brief.status === "queued" || brief.status === "reading") return "Reading the decklist…";
  if (brief.status === "failed") return "Decklist · couldn't read · try again";
  if (brief.cards <= 0) return "Decklist · no cards read";
  const text = `Decklist · ${cards(brief.cards)}`;
  if (brief.checked) return `${text} · checked`;
  return brief.check > 0 ? `${text} · ${brief.check} to check` : text;
}

/** Cards the main deck should hold, when the event says. */
export function deckListTarget(eventType: string | null | undefined, format: string | null | undefined): number | null {
  const f = (format ?? "").toLowerCase(), t = (eventType ?? "").toLowerCase();
  if (t === "limited") return 40;
  if (f === "commander" || f === "canadian_highlander" || f === "canlander") return 100;
  if (t === "constructed") return 60;
  return null;
}

/** A line to check: no card, or the reader wasn't sure. Left-out lines are never checked. */
export const deckListToCheck = (e: DeckListEntry): boolean => e.board !== "out" && (!e.cardId || !e.sure);

export function deckListCounts(entries: DeckListEntry[]): DeckListCounts {
  const c: DeckListCounts = { main: 0, side: 0, out: 0, check: 0 };
  for (const e of entries) {
    c[e.board] += e.qty;
    if (deckListToCheck(e)) c.check += 1;
  }
  return c;
}

export function deckListSizeLine(main: number, target: number | null | undefined): string {
  const text = cards(main);
  if (target && main < target) return `${text} · ${target - main} short of ${target}`;
  if (target === 100 && main > 100) return `${text} · ${main - 100} over 100`;
  return text;
}

const ORDER: Record<DeckListBoard, number> = { main: 0, side: 1, out: 2 };
const keyOf = (e: DeckListEntry) => `${e.cardId ?? "?" + e.name.toLowerCase()}|${e.board}`;

/** The same card on the same board is one line (first place kept); main, then side, then out. */
export function tidyDeckList(entries: DeckListEntry[]): DeckListEntry[] {
  const out: DeckListEntry[] = [];
  const at = new Map<string, number>();
  for (const e of entries) {
    const i = at.get(keyOf(e));
    if (i !== undefined) {
      const had = out[i];
      had.qty = Math.min(99, had.qty + e.qty);
      if (!e.sure) {
        had.sure = false;
        if (e.read && !had.read) had.read = e.read;
      }
    } else {
      at.set(keyOf(e), out.length);
      out.push({ ...e });
    }
  }
  return out.map((e, i) => ({ e, i })).sort((a, b) => ORDER[a.e.board] - ORDER[b.e.board] || a.i - b.i).map((x) => x.e);
}

/** 0 removes the line; 99 at most. */
export function setDeckListQty(entries: DeckListEntry[], i: number, qty: number): DeckListEntry[] {
  if (i < 0 || i >= entries.length) return entries;
  if (qty <= 0) return entries.filter((_, j) => j !== i);
  return entries.map((e, j) => (j === i ? { ...e, qty: Math.min(99, qty) } : e));
}

export function moveDeckListLine(entries: DeckListEntry[], i: number, board: DeckListBoard): DeckListEntry[] {
  if (i < 0 || i >= entries.length) return entries;
  return tidyDeckList(entries.map((e, j) => (j === i ? { ...e, board } : e)));
}

/** The player picked the card this line really is: sure, nothing left to check. */
export function replaceDeckListCard(entries: DeckListEntry[], i: number, card: DeckListCard): DeckListEntry[] {
  if (i < 0 || i >= entries.length) return entries;
  return tidyDeckList(entries.map((e, j) => (j === i ? { cardId: card.cardId, name: card.name, qty: e.qty, board: e.board, sure: true } : e)));
}

/** Looks right: a line with a card stops being one to check. */
export function confirmDeckListLine(entries: DeckListEntry[], i: number): DeckListEntry[] {
  if (i < 0 || i >= entries.length || !entries[i].cardId) return entries;
  return entries.map((e, j) => {
    if (j !== i) return e;
    const { read: _read, ...rest } = e;
    return { ...rest, sure: true };
  });
}

export function addDeckListCard(entries: DeckListEntry[], card: DeckListCard, board: DeckListBoard): DeckListEntry[] {
  return tidyDeckList([...entries, { cardId: card.cardId, name: card.name, qty: 1, board, sure: true }]);
}

/** What a new deck takes: main and sideboard lines with a card; lines without one are left out and counted. */
export function deckListDeckEntries(entries: DeckListEntry[]): { entries: [string, "main" | "side", number][]; skipped: number } {
  const out: [string, "main" | "side", number][] = [];
  let skipped = 0;
  for (const e of entries) {
    if (e.board === "out") continue;
    if (!e.cardId) { skipped += 1; continue; }
    const had = out.find((x) => x[0] === e.cardId && x[1] === e.board);
    if (had) had[2] += e.qty;
    else out.push([e.cardId, e.board, e.qty]);
  }
  return { entries: out, skipped };
}

/** The new deck's name: the event's; "<player> · <event>" for someone else's; 60 characters. */
export function deckListDeckName(event: string | null | undefined, player: string | null | undefined, mine: boolean): string {
  let name = (event ?? "").trim() || "Deck photo";
  const p = (player ?? "").trim();
  if (!mine && p) name = `${p} · ${name}`;
  return Array.from(name).slice(0, 60).join("").trim();
}

const DECK_FORMATS = ["standard", "pioneer", "modern", "legacy", "vintage", "pauper", "commander"];

/** The new deck's format: the event's constructed format, else Other. */
export function deckListDeckFormat(_eventType: string | null | undefined, format: string | null | undefined): string {
  const f = (format ?? "").toLowerCase();
  if (f === "canadian_highlander") return "canlander";
  return DECK_FORMATS.includes(f) ? f : "other";
}

/** "2 lines without a card were left out." */
export function deckListSkippedNote(skipped: number): string {
  return `${skipped} line${skipped === 1 ? "" : "s"} without a card ${skipped === 1 ? "was" : "were"} left out.`;
}
