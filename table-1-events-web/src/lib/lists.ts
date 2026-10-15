// Decks and cubes (contract/lists-2026-10-15.md). The database is the source of truth: lists sync by seq with
// lists_changes and every change goes through a list_* RPC, whose answer (the list with all its versions)
// replaces the local copy. A per-account IndexedDB copy makes them show instantly. The dev demo (?demo) keeps
// its lists in memory only.
import { useEffect, useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";

export type Board = "main" | "side" | "maybe" | "commander";
export type ListKind = "deck" | "cube";

export interface Entry {
  cardId: string;
  board: Board;
  qty: number;
}

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
}

export interface Change {
  cardId: string;
  board: Board;
  delta: number;
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
  for (const e of older?.entries ?? []) q.set(`${e.board}|${e.cardId}`, (q.get(`${e.board}|${e.cardId}`) ?? 0) - e.qty);
  for (const e of newer.entries) q.set(`${e.board}|${e.cardId}`, (q.get(`${e.board}|${e.cardId}`) ?? 0) + e.qty);
  const out: Change[] = [];
  for (const [k, d] of q) {
    if (d === 0) continue;
    const [board, cardId] = k.split("|") as [Board, string];
    out.push({ cardId, board, delta: d });
  }
  return out.sort((a, b) => BOARD_ORDER.indexOf(a.board) - BOARD_ORDER.indexOf(b.board) || a.delta - b.delta);
}

/** Copies a list still needs: covered only by the printing it names; Considering never counts. */
export function missingIn(l: CardList, owned: Map<string, number>): number {
  const need = new Map<string, number>();
  for (const e of entriesOf(l)) if (e.board !== "maybe") need.set(e.cardId, (need.get(e.cardId) ?? 0) + e.qty);
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
  versions?: { version: number; note: string; at: number; entries: [string, Board, number][] }[];
}

export function fromWire(w: ListWire): CardList | null {
  if (w.deleted || !w.kind || !w.name || !w.versions?.length) return null;
  return {
    id: w.id, kind: w.kind, name: w.name, format: w.format ?? "",
    versions: w.versions.map((v) => ({
      number: v.version, at: v.at, note: v.note,
      entries: v.entries.map(([cardId, board, qty]) => ({ cardId, board, qty })),
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

export async function createList(kind: ListKind, name: string, format: string): Promise<string> {
  const id = crypto.randomUUID();
  if (demo) {
    set({ lists: sorted([...state.lists, { id, kind, name, format, versions: [{ number: 1, at: Date.now() / 1000, note: "Created", entries: [] }] }]) });
    return id;
  }
  await call("list_create", { p_id: id, p_kind: kind, p_name: name, p_format: format, p_entries: [], p_note: "Created" });
  return id;
}

export type ListOp =
  | { card_id: string; board: Board; delta: number }
  | { card_id: string; board: Board; qty: number }
  | { card_id: string; from: Board; to: Board };

export async function editList(id: string, ops: ListOp[]): Promise<void> {
  if (demo) {
    return localEdit(id, (entries) => {
      for (const op of ops) {
        if ("from" in op) {
          const i = entries.findIndex((e) => e.cardId === op.card_id && e.board === op.from);
          if (i < 0) continue;
          const q = entries.splice(i, 1)[0].qty;
          const j = entries.findIndex((e) => e.cardId === op.card_id && e.board === op.to);
          if (j >= 0) entries[j].qty += q;
          else entries.push({ cardId: op.card_id, board: op.to, qty: q });
        } else {
          const i = entries.findIndex((e) => e.cardId === op.card_id && e.board === op.board);
          const q = "qty" in op ? op.qty : (i >= 0 ? entries[i].qty : 0) + op.delta;
          if (i >= 0 && q > 0) entries[i].qty = q;
          else if (i >= 0) entries.splice(i, 1);
          else if (q > 0) entries.push({ cardId: op.card_id, board: op.board, qty: q });
        }
      }
      return entries;
    });
  }
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
}

export async function deleteList(id: string): Promise<void> {
  if (demo) return set({ lists: state.lists.filter((l) => l.id !== id) });
  const { error } = await supabase.rpc("list_delete", { p_list_id: id });
  if (error) {
    set({ error: error.message });
    throw error;
  }
  set({ lists: state.lists.filter((l) => l.id !== id) });
  await saveCache();
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
