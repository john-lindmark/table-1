// Decks and cubes (contract/lists-2026-10-15.md). The database is the source of truth: lists sync by seq with
// lists_changes and every change goes through a list_* RPC, whose answer (the list with all its versions)
// replaces the local copy. A per-account IndexedDB copy makes them show instantly. The dev demo (?demo) keeps
// its lists in memory only.
import { useEffect, useSyncExternalStore } from "react";
import { holdings, shorts, type CardOf, type Need } from "./ownedByCard";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";
import { isNetworkError } from "./offline";

export type Board = "main" | "side" | "maybe" | "commander";
export type ListKind = "deck" | "cube";

export type ListFinish = "nonfoil" | "foil" | "etched";

/** A line is printing × section × finish × language, so 2 foil and 2 non-foil copies of a card are two lines
 *  (contract/lists-2026-10-15.md, "Languages"). */
export interface Entry {
  cardId: string;
  board: Board;
  qty: number;
  finish?: ListFinish; // absent = nonfoil
  lang?: string; // absent = en; a non-English printing is always its own
}

export const finishOf = (e: { finish?: ListFinish }): ListFinish => e.finish ?? "nonfoil";
export const langOf = (e: { lang?: string }): string => e.lang ?? "en";
/** An entry with only the fields that aren't their defaults. */
export function entry(cardId: string, board: Board, qty: number, finish: ListFinish = "nonfoil", lang = "en"): Entry {
  return { cardId, board, qty, ...(finish !== "nonfoil" ? { finish } : {}), ...(lang !== "en" ? { lang } : {}) };
}
/** An entry as list_create takes it: the finish and language only when they aren't non-foil / English. */
export function entryWire(e: Entry): (string | number)[] {
  const f = finishOf(e), l = langOf(e);
  return l !== "en" ? [e.cardId, e.board, e.qty, f, l] : f !== "nonfoil" ? [e.cardId, e.board, e.qty, f] : [e.cardId, e.board, e.qty];
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
  /** A roto deck linked to its event: filled by the draft from the cube, so it never counts Missing. */
  eventId?: string | null;
  eventName?: string | null;
  /** The server's seq (absent in the demo), and the link it syncs from (a Cube Cobra cube,
   *  contract/cube-sync-2026-10-30.md). */
  seq?: number;
  sourceUrl?: string | null;
}

export interface Change {
  cardId: string;
  board: Board;
  delta: number;
  finish: ListFinish;
  lang: string;
}

export const BOARD_ORDER: Board[] = ["commander", "main", "side", "maybe"];

export const current = (l: CardList) => l.versions[l.versions.length - 1];
export const entriesOf = (l: CardList) => current(l)?.entries ?? [];
export const countOf = (l: CardList, board: Board) => entriesOf(l).filter((e) => e.board === board).reduce((n, e) => n + e.qty, 0);
export const boardsOf = (l: CardList) => BOARD_ORDER.filter((b) => entriesOf(l).some((e) => e.board === b));
export const sectionsFor = (kind: ListKind): Board[] => (kind === "deck" ? ["main", "side", "maybe"] : ["main", "maybe"]);

export function boardTitle(kind: ListKind, board: Board, format?: string): string {
  switch (board) {
    case "commander": return format === "oathbreaker" ? "Command zone" : "Commander";
    case "main": return kind === "deck" ? "Main deck" : "Main";
    case "side": return "Sideboard";
    case "maybe": return "Considering";
  }
}

/** What changed from `older` (null = nothing) to `newer`, per card and section; removals first. */
export function diff(older: Version | null, newer: Version): Change[] {
  const q = new Map<string, number>();
  const key = (e: Entry) => `${e.board}|${e.cardId}|${finishOf(e)}|${langOf(e)}`;
  for (const e of older?.entries ?? []) q.set(key(e), (q.get(key(e)) ?? 0) - e.qty);
  for (const e of newer.entries) q.set(key(e), (q.get(key(e)) ?? 0) + e.qty);
  const out: Change[] = [];
  for (const [k, d] of q) {
    if (d === 0) continue;
    const [board, cardId, finish, lang] = k.split("|") as [Board, string, ListFinish, string];
    out.push({ cardId, board, delta: d, finish, lang });
  }
  return out.sort((a, b) => BOARD_ORDER.indexOf(a.board) - BOARD_ORDER.indexOf(b.board) || a.delta - b.delta);
}

/** Key into the owned map: "card_id|finish". */
export const ownKey = (cardId: string, finish: ListFinish = "nonfoil") => `${cardId}|${finish}`;

/** A list's lines for the owned-by-card rules (contract/owned-by-card-2026-10-31.md), in list order. */
export const needsOf = (l: CardList): Need[] => entriesOf(l).map((e) => ({ cardId: e.cardId, board: e.board, finish: finishOf(e), qty: e.qty, lang: langOf(e) }));

/** Copies a list still needs: any printing of a card covers its lines (contract/owned-by-card-2026-10-31.md);
 *  Considering and basic lands (`basics`, contract/basics-2026-10-24.md) never count. `cardOf` maps a printing to its card. */
export function missingIn(l: CardList, owned: Map<string, number>, basics: Set<string>, cardOf: CardOf = (id) => id): number {
  if (l.eventId) return 0; // a roto deck's cards come from the cube, never from your collection
  return shorts(needsOf(l), holdings(owned, cardOf), basics).reduce((a, b) => a + b, 0);
}

/** One line (or grid/stack card) reads short when you own fewer copies than it lists: never for Considering, never for
 *  a basic land (contract/basics-2026-10-24.md). */
export function isShort(board: string, qty: number, owned: number, basic: boolean): boolean {
  return board !== "maybe" && !basic && owned < qty;
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
  seq?: number;
  source_url?: string | null;
  versions?: { version: number; note: string; at: number; entries: ([string, Board, number] | [string, Board, number, ListFinish] | [string, Board, number, ListFinish, string])[] }[];
}

export function fromWire(w: ListWire): CardList | null {
  if (w.deleted || !w.kind || !w.name || !w.versions?.length) return null;
  return {
    id: w.id, kind: w.kind, name: w.name, format: w.format ?? "",
    ...(w.event_id ? { eventId: w.event_id, eventName: w.event_name ?? null } : {}),
    ...(typeof w.seq === "number" ? { seq: w.seq } : {}),
    ...(w.source_url ? { sourceUrl: w.source_url } : {}),
    versions: w.versions.map((v) => ({
      number: v.version, at: v.at, note: v.note,
      entries: v.entries.map(([cardId, board, qty, finish, lang]) => entry(cardId, board, qty, finish ?? "nonfoil", lang ?? "en")),
    })),
  };
}

/* ── store ────────────────────────────────────────────────────────────── */

interface ListsState {
  userId: string | null;
  lists: CardList[];
  ready: boolean;
  error: string | null;
  /** Lists made in this browser that the server hasn't saved yet, with why the last try failed ("" = not tried yet,
   *  or offline). Each sync sends them again until the server has them (contract/offline-2026-10-31.md § 4). */
  unsaved: Record<string, string>;
  /** Changes to saved lists that failed on the network, in order; sent before the next pull. The lists show them. */
  pending: PendingCall[];
  version: number;
}

export interface PendingCall { fn: string; args: Record<string, unknown> }

const empty: ListsState = { userId: null, lists: [], ready: false, error: null, unsaved: {}, pending: [], version: 0 };
let state = empty;
let cursor = 0;
let demo = false;
let running: Promise<void> | null = null;
let again = false;
const listeners = new Set<() => void>();

/** What a list's screen says while the server doesn't have it. */
export function unsavedNotice(l: CardList, why: string): string {
  const kind = l.kind === "cube" ? "cube" : "deck";
  return why === "" ? `Saving this ${kind} to your account…`
    : `This ${kind} isn't saved to your account yet: ${why} It's sent again each time Table 1 syncs.`;
}

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

interface ListsCache { cursor: number; lists: CardList[]; unsaved?: Record<string, string>; pending?: PendingCall[] }

async function loadCache(userId: string): Promise<ListsCache | null> {
  const db = await cacheDb(userId);
  if (!db) return null;
  return new Promise((resolve) => {
    const req = db.transaction("state").objectStore("state").get("v1");
    req.onsuccess = () => resolve((req.result as ListsCache) ?? null);
    req.onerror = () => resolve(null);
  });
}

async function saveCache() {
  if (!state.userId || demo) return;
  const db = await cacheDb(state.userId);
  if (!db) return;
  const c: ListsCache = { cursor, lists: state.lists, unsaved: state.unsaved, pending: state.pending };
  db.transaction("state", "readwrite").objectStore("state").put(c, "v1");
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
    set({ lists: cached.lists, ready: true, unsaved: cached.unsaved ?? {}, pending: cached.pending ?? [] });
  }
  await syncLists();
}

/** Sends the queued changes in order. False when the network stopped it: the pull is skipped so the server's copy
 *  doesn't hide what's still to send. A change the server refuses is dropped; the pull then sets things right. */
async function flushPending(user: string): Promise<boolean> {
  while (state.pending.length && state.userId === user) {
    const p = state.pending[0];
    const { data, error } = await supabase.rpc(p.fn, p.args);
    if (state.userId !== user) return false;
    if (error) {
      if (isNetworkError(error)) return false;
      set({ pending: state.pending.slice(1), error: `A change made offline was refused: ${error.message}` });
      await saveCache();
      continue;
    }
    set({ pending: state.pending.slice(1) });
    merge(data as ListWire);
    await saveCache();
  }
  return true;
}

/** Sends a list the server doesn't have yet with what this browser holds now; list_create returns the list it
 *  already has for a retried id. A failure is kept on the list, and the next sync tries again. */
const saving = new Map<string, Promise<void>>();
function saveUnsaved(id: string): Promise<void> {
  const run = saving.get(id);
  if (run) return run;
  const user = state.userId;
  const l = state.lists.find((x) => x.id === id);
  if (!user || demo || !l) { dropUnsaved(id); return Promise.resolve(); }
  const cur = current(l);
  const p = (async () => {
    const { data, error } = await supabase.rpc("list_create", {
      p_id: l.id, p_kind: l.kind, p_name: l.name, p_format: l.format, p_entries: cur.entries.map(entryWire), p_note: l.versions[0]?.note ?? "Created",
    });
    if (state.userId !== user) return;
    if (error) {
      set({ unsaved: { ...state.unsaved, [id]: error.message } });
      await saveCache();
      return;
    }
    dropUnsaved(id);
    merge(data as ListWire);
    await saveCache();
    // The Cube Cobra link set while the list was on its way (an import).
    if (l.sourceUrl && !(data as ListWire).source_url) void call("list_source_set", { p_list_id: id, p_source_url: l.sourceUrl });
  })().finally(() => saving.delete(id));
  saving.set(id, p);
  return p;
}
function dropUnsaved(id: string) {
  if (!(id in state.unsaved)) return;
  const unsaved = { ...state.unsaved };
  delete unsaved[id];
  set({ unsaved });
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
      if (!(await flushPending(user))) return;
      const seen = new Set<string>();
      for (let page = 0; page < 50; page++) {
        const { data, error } = await supabase.rpc("lists_changes", { p_after: cursor, p_limit: 100 });
        if (error) throw error;
        if (state.userId !== user) return;
        const r = data as { lists: ListWire[]; next: number; more: boolean };
        const byId = new Map(state.lists.map((l) => [l.id, l]));
        for (const w of r.lists) {
          seen.add(w.id);
          const l = fromWire(w);
          if (l) byId.set(l.id, l);
          else byId.delete(w.id);
        }
        cursor = r.next;
        set({ lists: sorted([...byId.values()]), ready: true, error: null });
        await saveCache();
        if (!r.more) break;
      }
      // Lists the server sent are saved; the rest are sent again.
      const unsaved = Object.fromEntries(Object.entries(state.unsaved).filter(([id]) => !seen.has(id)));
      set({ unsaved });
      for (const id of Object.keys(unsaved).sort()) await saveUnsaved(id);
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

/** A change that couldn't reach the server: applied here, queued in order, sent before the next pull. */
function queue(fn: string, args: Record<string, unknown>, apply: () => void) {
  apply();
  set({ pending: [...state.pending, { fn, args }] });
  capture("list_change_queued");
  void saveCache();
}

/** Sends one change and replaces the local list with the server's version (the source of truth: it groups edits
 *  into versions). On a network failure the change is applied here (`local`) and queued (contract/offline-2026-10-31.md
 *  § 4); on any other failure the local copy is re-synced. A change to a list the server doesn't have yet waits for
 *  the create, which carries the current cards. */
async function call(fn: string, args: Record<string, unknown>, local?: () => void): Promise<void> {
  const id = typeof args.p_list_id === "string" ? args.p_list_id : null;
  if (id && id in state.unsaved) {
    local?.();
    await saveCache();
    void saveUnsaved(id);
    return;
  }
  if (state.pending.length && local) return queue(fn, args, local);
  const { data, error } = await supabase.rpc(fn, args);
  if (error) {
    if (local && isNetworkError(error)) return queue(fn, args, local);
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
 * `from` is for telemetry only: new / duplicate / import / finder / profile (a copy of a shared deck or cube) / insights
 * (a finish from the metagame).
 */
export async function createList(kind: ListKind, name: string, format: string, entries: Entry[] = [], note = "Created",
                                 from: "new" | "duplicate" | "import" | "finder" | "profile" | "insights" = "new"): Promise<string> {
  const id = crypto.randomUUID();
  if (demo) {
    set({ lists: sorted([...state.lists, { id, kind, name, format, versions: [{ number: 1, at: Date.now() / 1000, note, entries: entries.map((e) => ({ ...e })) }] }]) });
    return id;
  }
  const { data, error } = await supabase.rpc("list_create", {
    p_id: id, p_kind: kind, p_name: name, p_format: format, p_entries: entries.map(entryWire), p_note: note,
  });
  if (error) {
    if (!isNetworkError(error)) {
      set({ error: error.message });
      throw error;
    }
    // Made here, saved to the account by the next sync (contract/offline-2026-10-31.md § 4).
    set({
      lists: sorted([...state.lists, { id, kind, name, format, versions: [{ number: 1, at: Date.now() / 1000, note, entries: entries.map((e) => ({ ...e })) }] }]),
      unsaved: { ...state.unsaved, [id]: "" },
    });
    await saveCache();
    capture("list_change_queued");
  } else {
    merge(data as ListWire);
    set({ error: null });
    await saveCache();
  }
  capture("list_created", { kind, format, from });
  return id;
}

/** Changes the list's format; the cards stay as they are. */
export async function setListFormat(id: string, format: string): Promise<void> {
  const l = state.lists.find((x) => x.id === id);
  if (!l || l.format === format) return;
  const local = () => {
    const now = state.lists.find((x) => x.id === id);
    if (now) set({ lists: sorted([...state.lists.filter((x) => x.id !== id), { ...now, format }]) });
  };
  if (demo) return local();
  await call("list_update", { p_list_id: id, p_format: format }, local);
  capture("list_format_changed", { kind: l.kind, from: l.format, to: format });
}

/** A name as the server keeps it (list_update): trimmed, at most 60 characters. Blank means "keep the old one". */
export function listName(raw: string): string {
  return raw.trim().slice(0, 60);
}

/** Renames the list; a blank name is ignored. */
export async function renameList(id: string, raw: string): Promise<void> {
  const name = listName(raw);
  const l = state.lists.find((x) => x.id === id);
  if (!l || !name || l.name === name) return;
  const local = () => {
    const now = state.lists.find((x) => x.id === id);
    if (now) set({ lists: sorted([...state.lists.filter((x) => x.id !== id), { ...now, name }]) });
  };
  if (demo) return local();
  await call("list_update", { p_list_id: id, p_name: name }, local);
  capture("list_renamed", { kind: l.kind });
}

/** Remembers the Cube Cobra link a cube was imported from, so syncing needs no link. */
export async function setListSource(id: string, url: string): Promise<void> {
  const l = state.lists.find((x) => x.id === id);
  if (!l || l.sourceUrl === url) return;
  const local = () => {
    const now = state.lists.find((x) => x.id === id);
    if (now) set({ lists: sorted([...state.lists.filter((x) => x.id !== id), { ...now, sourceUrl: url }]) });
  };
  if (demo) return local();
  await call("list_source_set", { p_list_id: id, p_source_url: url }, local);
}

/** Saves a cube synced with Cube Cobra as one new version (contract/cube-sync-2026-10-30.md). Throws the server's
 *  error; `code` "PT409" means the list changed since `seq` (the store syncs, and the caller asks to check again). */
export async function syncList(id: string, seq: number | undefined, entries: Entry[], sourceUrl: string): Promise<void> {
  if (demo) {
    localEdit(id, () => entries.map((e) => ({ ...e })), "Synced with Cube Cobra");
    const l = state.lists.find((x) => x.id === id);
    if (l) set({ lists: sorted([...state.lists.filter((x) => x.id !== id), { ...l, sourceUrl }]) });
    return;
  }
  const { data, error } = await supabase.rpc("list_sync", {
    p_list_id: id, p_seq: seq ?? -1, p_entries: entries.map(entryWire), p_source_url: sourceUrl,
  });
  if (error) {
    void syncLists();
    throw error;
  }
  openEdit.delete(id);
  merge(data as ListWire);
  set({ error: null });
  await saveCache();
}

/** A new list with the current version's cards; its history starts fresh and names where it came from. */
export function duplicateList(l: CardList): Promise<string> {
  const v = current(l);
  return createList(l.kind, `${l.name} (copy)`.slice(0, 60), l.format, v.entries, `Duplicated from ${l.name} v${v.number}`, "duplicate");
}

/** `lang` defaults to en everywhere; `to_lang` to the line's own. */
export type ListOp =
  | { card_id: string; board: Board; finish?: ListFinish; lang?: string; delta: number }
  | { card_id: string; board: Board; finish?: ListFinish; lang?: string; qty: number }
  | { card_id: string; finish?: ListFinish; lang?: string; from: Board; to: Board }
  /** Move qty copies (default all) to another printing, finish and/or language in the same section. */
  | { card_id: string; board: Board; finish?: ListFinish; lang?: string; to_card_id?: string; to_finish?: ListFinish; to_lang?: string; qty?: number; swap: true };

/** The ops applied to a version's entries the way the server applies them (the demo, and a change queued offline). */
export function applyListOps(entries: Entry[], ops: ListOp[]): Entry[] {
  const find = (cardId: string, board: Board, finish: ListFinish, lang: string) =>
    entries.findIndex((e) => e.cardId === cardId && e.board === board && finishOf(e) === finish && langOf(e) === lang);
  const put = (cardId: string, board: Board, finish: ListFinish, lang: string, q: number) => {
    const j = find(cardId, board, finish, lang);
    if (j >= 0) entries[j].qty += q;
    else entries.push(entry(cardId, board, q, finish, lang));
  };
  for (const op of ops) {
    const fin = op.finish ?? "nonfoil", lang = op.lang ?? "en";
    if ("from" in op) {
      const i = find(op.card_id, op.from, fin, lang);
      if (i < 0) continue;
      put(op.card_id, op.to, fin, lang, entries.splice(i, 1)[0].qty);
    } else if ("swap" in op || "to_card_id" in op || "to_finish" in op || "to_lang" in op) {
      // A printing move: tagged `swap` here, told apart by its to_* fields when queued and replayed.
      const mv = op as { card_id: string; board: Board; to_card_id?: string; to_finish?: ListFinish; to_lang?: string; qty?: number };
      const i = find(mv.card_id, mv.board, fin, lang);
      if (i < 0) continue;
      const n = Math.min(entries[i].qty, mv.qty ?? entries[i].qty);
      entries[i].qty -= n;
      if (entries[i].qty <= 0) entries.splice(i, 1);
      put(mv.to_card_id ?? mv.card_id, mv.board, mv.to_finish ?? fin, mv.to_lang ?? lang, n);
    } else {
      const i = find(op.card_id, op.board, fin, lang);
      const q = "qty" in op ? op.qty : (i >= 0 ? entries[i].qty : 0) + op.delta;
      if (i >= 0 && q > 0) entries[i].qty = q;
      else if (i >= 0) entries.splice(i, 1);
      else if (q > 0) put(op.card_id, op.board, fin, lang, q);
    }
  }
  return entries;
}

export async function editList(id: string, ops: ListOp[]): Promise<void> {
  const local = () => localEdit(id, (entries) => applyListOps(entries, ops));
  if (demo) return local();
  // The server tells the printing move apart by its to_* fields; `swap` is a client-side tag.
  ops = ops.map((op) => ("swap" in op ? (({ swap: _swap, ...rest }) => rest)(op) : op)) as ListOp[];
  await call("list_edit", { p_list_id: id, p_ops: ops }, local);
}

export async function restoreList(id: string, number: number): Promise<void> {
  const local = () => {
    const l = state.lists.find((x) => x.id === id);
    const v = l?.versions.find((x) => x.number === number);
    if (v) localEdit(id, () => v.entries.map((e) => ({ ...e })), `Restored v${number}`);
  };
  if (demo) return local();
  await call("list_restore", { p_list_id: id, p_version: number }, local);
  const kind = listKindOf(id);
  if (kind) capture("list_version_restored", { kind });
}

export async function deleteList(id: string): Promise<void> {
  if (demo) return set({ lists: state.lists.filter((l) => l.id !== id) });
  if (id in state.unsaved) {
    // Never reached the server: forgotten here.
    dropUnsaved(id);
    set({ lists: state.lists.filter((l) => l.id !== id) });
    await saveCache();
    return;
  }
  const { error } = await supabase.rpc("list_delete", { p_list_id: id });
  if (error) {
    if (!isNetworkError(error)) {
      set({ error: error.message });
      throw error;
    }
    queue("list_delete", { p_list_id: id }, () => set({ lists: state.lists.filter((l) => l.id !== id) }));
    return;
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
