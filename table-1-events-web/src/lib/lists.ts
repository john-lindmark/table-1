// Decks and cubes (contract/lists-2026-10-15.md). The database is the source of truth: lists sync by seq with
// lists_changes and every change goes through a list_* RPC, whose answer (the list with all its versions)
// replaces the local copy. A per-account IndexedDB copy makes them show instantly. The dev demo (?demo) keeps
// its lists in memory only.
import { useEffect, useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";

export type Board = "main" | "side" | "maybe" | "commander";
export type ListKind = "deck" | "cube";

export type ListFinish = "nonfoil" | "foil" | "etched";

/** A line is printing × section × finish, so 2 foil and 2 non-foil copies of a card are two lines. */
export interface Entry {
  cardId: string;
  board: Board;
  qty: number;
  finish?: ListFinish; // absent = nonfoil
}

export const finishOf = (e: { finish?: ListFinish }): ListFinish => e.finish ?? "nonfoil";

export interface Version {
  number: number;
  at: number; // epoch seconds
  note: string;
  entries: Entry[];
}

export interface CardList {
  id: string;
  kind: ListKind;
  name: string;
  format: string;
  versions: Version[]; // oldest first, never empty
  /** A roto deck linked to its event: filled by the draft from the cube, so it never counts Missing. */
  eventId?: string | null;
  eventName?: string | null;
}

export interface Change {
  cardId: string;
  board: Board;
  delta: number;
  finish: ListFinish;
}

export const BOARD_ORDER: Board[] = ["commander", "main", "side", "maybe"];

export const current = (l: CardList) => l.versions[l.versions.length - 1];
export const entriesOf = (l: CardList) => current(l)?.entries ?? [];
export const countOf = (l: CardList, board: Board) => entriesOf(l).filter((e) => e.board === board).reduce((n, e) => n + e.qty, 0);
export const boardsOf = (l: CardList) => BOARD_ORDER.filter((b) => entriesOf(l).some((e) => e.board === b));
export const sectionsFor = (kind: ListKind): Board[] => (kind === "deck" ? ["main", "side", "maybe"] : ["main", "maybe"]);

export function boardTitle(kind: ListKind, board: Board): string {
  switch (board) {
    case "commander": return "Commander";
    case "main": return kind === "deck" ? "Main deck" : "Main";
    case "side": return "Sideboard";
    case "maybe": return "Considering";
  }
}

/** What changed from `older` (null = nothing) to `newer`, per card and section; removals first. */
export function diff(older: Version | null, newer: Version): Change[] {
  const q = new Map<string, number>();
  const key = (e: Entry) => `${e.board}|${e.cardId}|${finishOf(e)}`;
  for (const e of older?.entries ?? []) q.set(key(e), (q.get(key(e)) ?? 0) - e.qty);
  for (const e of newer.entries) q.set(key(e), (q.get(key(e)) ?? 0) + e.qty);
  const out: Change[] = [];
  for (const [k, d] of q) {
    if (d === 0) continue;
    const [board, cardId, finish] = k.split("|") as [Board, string, ListFinish];
    out.push({ cardId, board, delta: d, finish });
  }
  return out.sort((a, b) => BOARD_ORDER.indexOf(a.board) - BOARD_ORDER.indexOf(b.board) || a.delta - b.delta);
}

/** Key into the owned map: "card_id|finish". */
export const ownKey = (cardId: string, finish: ListFinish = "nonfoil") => `${cardId}|${finish}`;

/** Copies a list still needs: covered only by the printing and finish it names; Considering never counts. */
export function missingIn(l: CardList, owned: Map<string, number>): number {
  if (l.eventId) return 0; // a roto deck's cards come from the cube, never from your collection
  const need = new Map<string, number>();
  for (const e of entriesOf(l)) if (e.board !== "maybe") need.set(ownKey(e.cardId, finishOf(e)), (need.get(ownKey(e.cardId, finishOf(e))) ?? 0) + e.qty);
  let n = 0;
  for (const [id, q] of need) n += Math.max(0, q - (owned.get(id) ?? 0));
  return n;
}

/* ── wire format ──────────────────────────────────────────────────────── */

interface ListWire {
  id: string;
  deleted?: boolean;
  kind?: ListKind;
  name?: string;
  format?: string;
  event_id?: string | null;
  event_name?: string | null;
  versions?: { version: number; note: string; at: number; entries: ([string, Board, number] | [string, Board, number, ListFinish])[] }[];
}

export function fromWire(w: ListWire): CardList | null {
  if (w.deleted || !w.kind || !w.name || !w.versions?.length) return null;
  return {
    id: w.id, kind: w.kind, name: w.name, format: w.format ?? "",
    ...(w.event_id ? { eventId: w.event_id, eventName: w.event_name ?? null } : {}),
    versions: w.versions.map((v) => ({
      number: v.version, at: v.at, note: v.note,
      entries: v.entries.map(([cardId, board, qty, finish]) => (finish && finish !== "nonfoil" ? { cardId, board, qty, finish } : { cardId, board, qty })),
    })),
  };
}

/* ── store ────────────────────────────────────────────────────────────── */

interface ListsState {
  userId: string | null;
  lists: CardList[];
  ready: boolean;
  error: string | null;
  version: number;
}

const empty: ListsState = { userId: null, lists: [], ready: false, error: null, version: 0 };
let state = empty;
let cursor = 0;
let demo = false;
let running: Promise<void> | null = null;
let again = false;
const listeners = new Set<() => void>();

function set(patch: Partial<ListsState>) {
  state = { ...state, ...patch, version: state.version + 1 };
  listeners.forEach((l) => l());
}

function sorted(lists: CardList[]) {
  return lists.slice().sort((a, b) => a.name.localeCompare(b.name));
}

function merge(w: ListWire) {
  const rest = state.lists.filter((l) => l.id !== w.id);
  const l = fromWire(w);
  set({ lists: sorted(l ? [...rest, l] : rest) });
}

/* Per-account cache in IndexedDB: one record {cursor, lists}. */
function cacheDb(userId: string): Promise<IDBDatabase | null> {
  return new Promise((resolve) => {
    try {
      const req = indexedDB.open(`table1-lists-${userId}`, 1);
      req.onupgradeneeded = () => req.result.createObjectStore("state");
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => resolve(null);
    } catch {
      resolve(null);
    }
  });
}

async function loadCache(userId: string): Promise<{ cursor: number; lists: CardList[] } | null> {
  const db = await cacheDb(userId);
  if (!db) return null;
  return new Promise((resolve) => {
    const req = db.transaction("state").objectStore("state").get("v1");
    req.onsuccess = () => resolve((req.result as { cursor: number; lists: CardList[] }) ?? null);
    req.onerror = () => resolve(null);
  });
}

async function saveCache() {
  if (!state.userId || demo) return;
  const db = await cacheDb(state.userId);
  if (!db) return;
  db.transaction("state", "readwrite").objectStore("state").put({ cursor, lists: state.lists }, "v1");
}

export async function startLists(userId: string, demoLists?: CardList[]) {
  if (state.userId === userId && (demo || state.ready)) return void syncLists();
  cursor = 0;
  demo = !!demoLists;
  state = { ...empty, userId };
  listeners.forEach((l) => l());
  if (demoLists) return set({ lists: sorted(demoLists), ready: true });
  const cached = await loadCache(userId);
  if (cached && state.userId === userId) {
    cursor = cached.cursor;
    set({ lists: cached.lists, ready: true });
  }
  await syncLists();
}

/** Pulls every list changed after the local cursor; a call during a run schedules one more run. */
export function syncLists(): Promise<void> {
  if (!state.userId || demo) return Promise.resolve();
  if (running) {
    again = true;
    return running;
  }
  const user = state.userId;
  running = (async () => {
    try {
      for (let page = 0; page < 50; page++) {
        const { data, error } = await supabase.rpc("lists_changes", { p_after: cursor, p_limit: 100 });
        if (error) throw error;
        if (state.userId !== user) return;
        const r = data as { lists: ListWire[]; next: number; more: boolean };
        const byId = new Map(state.lists.map((l) => [l.id, l]));
        for (const w of r.lists) {
          const l = fromWire(w);
          if (l) byId.set(l.id, l);
          else byId.delete(w.id);
        }
        cursor = r.next;
        set({ lists: sorted([...byId.values()]), ready: true, error: null });
        await saveCache();
        if (!r.more) break;
      }
    } catch (e) {
      set({ error: e instanceof Error ? e.message : String((e as { message?: string })?.message ?? e) });
    } finally {
      running = null;
      if (again) {
        again = false;
        void syncLists();
      }
    }
  })();
  return running;
}

async function call(fn: string, args: Record<string, unknown>): Promise<void> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) {
    set({ error: error.message });
    void syncLists();
    throw error;
  }
  merge(data as ListWire);
  set({ error: null });
  await saveCache();
}

/* Demo: the same changes applied locally (versions grouped the way the server groups them). */
const openEdit = new Map<string, { number: number; at: number }>();

function localEdit(id: string, change: (entries: Entry[]) => Entry[], note = "Edited") {
  const l = state.lists.find((x) => x.id === id);
  if (!l) return;
  const cur = current(l);
  const entries = change(cur.entries.map((e) => ({ ...e })));
  const now = Date.now() / 1000;
  const open = openEdit.get(id);
  let versions: Version[];
  if (note === "Edited" && open && open.number === cur.number && now - open.at < 600) {
    versions = [...l.versions.slice(0, -1), { ...cur, at: now, entries }];
  } else {
    versions = [...l.versions, { number: Math.max(...l.versions.map((v) => v.number)) + 1, at: now, note, entries }];
  }
  openEdit.set(id, note === "Edited" ? { number: versions[versions.length - 1].number, at: now } : { number: -1, at: 0 });
  set({ lists: sorted([...state.lists.filter((x) => x.id !== id), { ...l, versions }]) });
}

/**
 * A new list, optionally starting with cards (a duplicate, an import or a found decklist).
 * `from` is for telemetry only: new / duplicate / import / finder / profile (a copy of a shared deck or cube).
 */
export async function createList(kind: ListKind, name: string, format: string, entries: Entry[] = [], note = "Created",
                                 from: "new" | "duplicate" | "import" | "finder" | "profile" = "new"): Promise<string> {
  const id = crypto.randomUUID();
  if (demo) {
    set({ lists: sorted([...state.lists, { id, kind, name, format, versions: [{ number: 1, at: Date.now() / 1000, note, entries: entries.map((e) => ({ ...e })) }] }]) });
    return id;
  }
  await call("list_create", {
    p_id: id, p_kind: kind, p_name: name, p_format: format, p_entries: entries.map((e) => (finishOf(e) === "nonfoil" ? [e.cardId, e.board, e.qty] : [e.cardId, e.board, e.qty, finishOf(e)])), p_note: note,
  });
  capture("list_created", { kind, format, from });
  return id;
}

/** A new list with the current version's cards; its history starts fresh and names where it came from. */
export function duplicateList(l: CardList): Promise<string> {
  const v = current(l);
  return createList(l.kind, `${l.name} (copy)`.slice(0, 60), l.format, v.entries, `Duplicated from ${l.name} v${v.number}`, "duplicate");
}

export type ListOp =
  | { card_id: string; board: Board; finish?: ListFinish; delta: number }
  | { card_id: string; board: Board; finish?: ListFinish; qty: number }
  | { card_id: string; finish?: ListFinish; from: Board; to: Board }
  /** Move qty copies (default all) to another printing and/or finish in the same section. */
  | { card_id: string; board: Board; finish?: ListFinish; to_card_id?: string; to_finish?: ListFinish; qty?: number; swap: true };

export async function editList(id: string, ops: ListOp[]): Promise<void> {
  if (demo) {
    return localEdit(id, (entries) => {
      const find = (cardId: string, board: Board, finish: ListFinish) =>
        entries.findIndex((e) => e.cardId === cardId && e.board === board && finishOf(e) === finish);
      const put = (cardId: string, board: Board, finish: ListFinish, q: number) => {
        const j = find(cardId, board, finish);
        if (j >= 0) entries[j].qty += q;
        else entries.push(finish === "nonfoil" ? { cardId, board, qty: q } : { cardId, board, qty: q, finish });
      };
      for (const op of ops) {
        const fin = op.finish ?? "nonfoil";
        if ("from" in op) {
          const i = find(op.card_id, op.from, fin);
          if (i < 0) continue;
          put(op.card_id, op.to, fin, entries.splice(i, 1)[0].qty);
        } else if ("swap" in op) {
          const i = find(op.card_id, op.board, fin);
          if (i < 0) continue;
          const n = Math.min(entries[i].qty, op.qty ?? entries[i].qty);
          entries[i].qty -= n;
          if (entries[i].qty <= 0) entries.splice(i, 1);
          put(op.to_card_id ?? op.card_id, op.board, op.to_finish ?? fin, n);
        } else {
          const i = find(op.card_id, op.board, fin);
          const q = "qty" in op ? op.qty : (i >= 0 ? entries[i].qty : 0) + op.delta;
          if (i >= 0 && q > 0) entries[i].qty = q;
          else if (i >= 0) entries.splice(i, 1);
          else if (q > 0) put(op.card_id, op.board, fin, q);
        }
      }
      return entries;
    });
  }
  // The server tells the printing move apart by its to_* fields; `swap` is a client-side tag.
  ops = ops.map((op) => ("swap" in op ? (({ swap: _swap, ...rest }) => rest)(op) : op)) as ListOp[];
  await call("list_edit", { p_list_id: id, p_ops: ops });
}

export async function restoreList(id: string, number: number): Promise<void> {
  if (demo) {
    const l = state.lists.find((x) => x.id === id);
    const v = l?.versions.find((x) => x.number === number);
    if (v) localEdit(id, () => v.entries.map((e) => ({ ...e })), `Restored v${number}`);
    return;
  }
  await call("list_restore", { p_list_id: id, p_version: number });
  const kind = listKindOf(id);
  if (kind) capture("list_version_restored", { kind });
}

export async function deleteList(id: string): Promise<void> {
  if (demo) return set({ lists: state.lists.filter((l) => l.id !== id) });
  const { error } = await supabase.rpc("list_delete", { p_list_id: id });
  if (error) {
    set({ error: error.message });
    throw error;
  }
  const kind = listKindOf(id);
  if (kind) capture("list_deleted", { kind });
  set({ lists: state.lists.filter((l) => l.id !== id) });
  await saveCache();
}

/** The Library cube an event's cube fields point at: a cube list with that name (any case) and no Cube Cobra link.
 *  Create event and Setup → Details show it as Selected; a roto draws its pool from it. */
export function chosenLibraryCube(lists: CardList[], cubeName: string, cubeUrl: string): CardList | undefined {
  const name = cubeName.trim().toLowerCase();
  if (!name || cubeUrl.trim()) return undefined;
  return lists.find((l) => l.kind === "cube" && l.name.trim().toLowerCase() === name);
}

/** The lists held right now (outside React). */
export const listsNow = (): CardList[] => state.lists;

/** Deck or cube for a list this browser has loaded (telemetry's screen name). */
export function listKindOf(id: string): ListKind | undefined {
  return state.lists.find((l) => l.id === id)?.kind;
}

export function useLists(userId: string | null, demoLists?: () => Promise<CardList[]>) {
  useEffect(() => {
    if (!userId) return;
    if (demoLists) void demoLists().then((ls) => startLists(userId, ls));
    else void startLists(userId);
  }, [userId]);
  const snap = useSyncExternalStore((l) => {
    listeners.add(l);
    return () => listeners.delete(l);
  }, () => state);
  return snap.userId === userId ? snap : empty;
}
