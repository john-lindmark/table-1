// The signed-in user's collection, mirrored locally (contract/collection-2026-10-15.md).
// Items live in IndexedDB per account and in memory while the page is open; the server is asked only for
// what changed since the highest seq we hold. Writes go through collection_apply and are reflected locally
// at once, then confirmed by a delta sync.
import { useCallback, useEffect, useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";
import { isLibraryDemo, loadDemo, type DemoBackend } from "./libraryDemo";
import { isNetworkError, outboxDeltas, queues } from "./offline";
import { reflectBinders, shiftBinders, startBinders, syncBinders, type Alloc, type AllocRow, type WantRow } from "./binders";

export type Finish = "nonfoil" | "foil" | "etched";
export type Condition = "NM" | "LP" | "MP" | "HP" | "DMG";

export interface Item {
  k: string;
  cardId: string;
  finish: Finish;
  condition: Condition;
  lang: string;
  qty: number;
  seq: number;
}

export interface LibrarySummary {
  total_qty: number;
  unique_printings: number;
  unique_cards: number;
  value_usd: number;
  value_eur: number;
  seq: number;
}

export interface CollectionOp {
  card_id: string;
  finish?: Finish;
  condition?: Condition;
  lang?: string;
  delta?: number;
  qty?: number;
  /** With a delta: added copies go into this binder; removed copies come out of it first (contract/binders-wants-2026-10-17.md). */
  binder_id?: string | null;
}

export interface ApplyResult {
  batch_id: string;
  duplicate: boolean;
  changes: number;
  items: { card_id: string; finish: Finish; condition: Condition; lang: string; qty: number; seq: number }[];
  summary: LibrarySummary;
  /** Allocations the batch changed, and wants a trade met or an undo put back. */
  binder_items?: AllocRow[];
  wants?: WantRow[];
}

/** The account id the dev demo runs under. */
export const DEMO_USER = "demo";

export const itemKey = (cardId: string, finish: string, condition: string, lang: string) =>
  `${cardId}|${finish}|${condition}|${lang}`;

/* ── IndexedDB (one database per account) ─────────────────────────────── */

function openDb(userId: string): Promise<IDBDatabase | null> {
  return new Promise((resolve) => {
    try {
      const req = indexedDB.open(`table1-library-${userId}`, 1);
      req.onupgradeneeded = () => {
        req.result.createObjectStore("items", { keyPath: "k" });
        req.result.createObjectStore("meta");
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => resolve(null);
    } catch {
      resolve(null); // no IndexedDB (some private windows): work from memory and the server
    }
  });
}

function idbAll<T>(db: IDBDatabase, store: string): Promise<T[]> {
  return new Promise((resolve, reject) => {
    const req = db.transaction(store).objectStore(store).getAll();
    req.onsuccess = () => resolve(req.result as T[]);
    req.onerror = () => reject(req.error);
  });
}

function idbGet<T>(db: IDBDatabase, store: string, key: string): Promise<T | undefined> {
  return new Promise((resolve, reject) => {
    const req = db.transaction(store).objectStore(store).get(key);
    req.onsuccess = () => resolve(req.result as T | undefined);
    req.onerror = () => reject(req.error);
  });
}

/** Upserts and deletes items and moves the cursor in one transaction, so a crash never splits them. */
function idbCommit(db: IDBDatabase, put: Item[], del: string[], meta: Record<string, unknown>): Promise<void> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(["items", "meta"], "readwrite");
    const items = tx.objectStore("items");
    for (const it of put) items.put(it);
    for (const k of del) items.delete(k);
    const m = tx.objectStore("meta");
    for (const [k, v] of Object.entries(meta)) m.put(v, k);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

function idbClear(db: IDBDatabase): Promise<void> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(["items", "meta"], "readwrite");
    tx.objectStore("items").clear();
    tx.objectStore("meta").clear();
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

/* ── store ────────────────────────────────────────────────────────────── */

export interface CollectionState {
  userId: string | null;
  ready: boolean;
  syncing: boolean;
  error: string | null;
  items: Map<string, Item>;
  summary: LibrarySummary | null;
  /** Batches of adds that failed on the network and wait to be sent (contract/offline-2026-10-31.md § 3). */
  outbox: OutboxBatch[];
  /** Bumped on every change so components can memo on it. */
  version: number;
}

/** A batch waiting in the outbox, with the idempotency key it was first sent under. */
export interface OutboxBatch { key: string; source: string; ops: CollectionOp[] }

const empty: CollectionState = {
  userId: null, ready: false, syncing: false, error: null, items: new Map(), summary: null, outbox: [], version: 0,
};

/** "3 changes waiting to send" on the Collection home while the outbox isn't empty. */
export const outboxNotice = (s: CollectionState) =>
  s.outbox.length === 0 ? null : s.outbox.length === 1 ? "1 change waiting to send" : `${s.outbox.length} changes waiting to send`;

const outboxKey = (userId: string) => `table1.outbox.${userId}`;
function loadOutbox(userId: string): OutboxBatch[] {
  try { return (JSON.parse(localStorage.getItem(outboxKey(userId)) ?? "[]") as OutboxBatch[]) ?? []; } catch { return []; }
}
function saveOutbox(outbox: OutboxBatch[]) {
  if (!state.userId) return;
  try {
    if (outbox.length) localStorage.setItem(outboxKey(state.userId), JSON.stringify(outbox));
    else localStorage.removeItem(outboxKey(state.userId));
  } catch { /* private window */ }
  set({ outbox });
}

/** A result for a batch that waits in the outbox: Undo takes it out again. */
const queuedResult = (key: string): ApplyResult => ({
  batch_id: `queued:${key}`, duplicate: false, changes: 0, items: [],
  summary: state.summary ?? { total_qty: 0, unique_printings: 0, unique_cards: 0, value_usd: 0, value_eur: 0, seq: 0 },
});

/** Sends the outbox in order before a sync. A batch the server refuses is taken back; a network failure keeps the
 *  rest for next time. */
async function flushOutbox(userId: string) {
  let sent = 0;
  while (state.outbox.length && state.userId === userId) {
    const b = state.outbox[0];
    const { data, error } = await supabase.rpc("collection_apply", {
      p_ops: b.ops, p_source: b.source, p_source_id: null, p_idempotency_key: b.key,
    });
    if (state.userId !== userId) return;
    if (error) {
      if (isNetworkError(error)) break;
      showAdds(b.ops, -1);
      saveOutbox(state.outbox.slice(1));
      set({ error: `A change made offline was refused: ${error.message}` });
      continue;
    }
    saveOutbox(state.outbox.slice(1));
    reflect(data as ApplyResult);
    sent++;
  }
  if (sent) capture("outbox_sent", { batches: sent });
}

let state = empty;
let db: IDBDatabase | null = null;
let cursor = 0;
let syncRun: Promise<void> | null = null;
let syncAgain = false;
/** Dev-only demo (lib/libraryDemo.ts): reads and writes stay in memory. */
let demo: DemoBackend | null = null;
const listeners = new Set<() => void>();

function set(patch: Partial<CollectionState>) {
  state = { ...state, ...patch, version: state.version + 1 };
  listeners.forEach((l) => l());
}

function toItem(r: [string, Finish, Condition, string, number, number]): Item {
  const [cardId, finish, condition, lang, qty, seq] = r;
  return { k: itemKey(cardId, finish, condition, lang), cardId, finish, condition, lang, qty, seq };
}

async function start(userId: string) {
  if (state.userId === userId) return;
  if (import.meta.env.DEV && userId === DEMO_USER && isLibraryDemo()) {
    demo = await loadDemo();
    state = { ...empty, userId, items: new Map(demo.items), summary: demo.summary, ready: true, version: state.version + 1 };
    listeners.forEach((l) => l());
    startBinders(userId);
    return;
  }
  demo = null;
  db?.close();
  db = null;
  cursor = 0;
  state = { ...empty, userId };
  listeners.forEach((l) => l());
  const d = await openDb(userId);
  if (state.userId !== userId) return d?.close();
  db = d;
  if (db) {
    try {
      const [rows, saved, summary] = await Promise.all([
        idbAll<Item>(db, "items"),
        idbGet<number>(db, "meta", "cursor"),
        idbGet<LibrarySummary>(db, "meta", "summary"),
      ]);
      cursor = saved ?? 0;
      set({ items: new Map(rows.map((r) => [r.k, r])), summary: summary ?? null, ready: rows.length > 0 || cursor > 0 });
    } catch {
      cursor = 0;
    }
  }
  // Adds made offline: on screen again on top of the mirror, sent with the first sync.
  const outbox = loadOutbox(userId);
  set({ outbox });
  for (const b of outbox) showAdds(b.ops, 1);
  await sync();
}

/**
 * Pulls every change after the local cursor. A call made while a run is in flight schedules one more run
 * afterwards, so a write that lands mid-sync is always picked up.
 */
export function sync(): Promise<void> {
  if (!state.userId || demo) return Promise.resolve();
  if (syncRun) {
    syncAgain = true;
    return syncRun;
  }
  const userId = state.userId;
  syncRun = (async () => {
    set({ syncing: true, error: null });
    try {
      await flushOutbox(userId);
      if (state.userId !== userId) return;
      for (let pages = 0; pages < 200; pages++) {
        const { data, error } = await supabase.rpc("collection_changes", { p_after: cursor, p_limit: 5000 });
        if (error) throw error;
        if (state.userId !== userId) return;
        const r = data as {
          resync: boolean; items: [string, Finish, Condition, string, number, number][];
          next: number; more: boolean; summary: LibrarySummary;
        };
        if (r.resync) {
          cursor = 0;
          if (db) await idbClear(db);
          set({ items: new Map() });
          for (const b of state.outbox) showAdds(b.ops, 1);
          continue;
        }
        // The server hasn't counted adds still in the outbox: rows show its count plus them (the mirror keeps the
        // server's, so the next load adds them once).
        const queued = outboxDeltas(state.outbox.map((b) => b.ops));
        const items = new Map(state.items);
        const put: Item[] = [];
        const del: string[] = [];
        for (const row of r.items) {
          const it = toItem(row);
          const held = items.get(it.k);
          if (held && held.seq > it.seq) continue; // a newer write is already reflected
          if (it.qty > 0) put.push(it);
          else del.push(it.k);
          const shown = it.qty + (queued.get(it.k) ?? 0);
          if (shown > 0) items.set(it.k, { ...it, qty: shown });
          else items.delete(it.k);
        }
        cursor = r.next;
        if (db) await idbCommit(db, put, del, { cursor, summary: r.summary });
        set({ items, summary: r.summary, ready: true });
        if (!r.more) break;
      }
    } catch (e) {
      set({ error: e instanceof Error ? e.message : String((e as { message?: string })?.message ?? e) });
    } finally {
      syncRun = null;
      set({ syncing: false });
      if (syncAgain) {
        syncAgain = false;
        void sync();
      } else {
        // Binders, allocations and wants follow the items (their own cursor, library_changes).
        void syncBinders();
      }
    }
  })();
  return syncRun;
}

/**
 * One user action = one batch. Added copies show before the server answers (`showAdds`), the answer replaces them,
 * then a delta sync confirms. `key`: a caller that retries
 * a batch itself (an import's chunks) passes the same key each time, so a batch that already landed replays as a duplicate.
 */
export async function applyOps(ops: CollectionOp[], source: "manual" | "scan" | "import" | "adjust" | "trade" = "manual",
                               key: string = crypto.randomUUID()): Promise<ApplyResult> {
  if (demo) {
    const res = demo.apply(ops, source);
    reflect(res);
    return res;
  }
  showAdds(ops, 1);
  // Behind batches already waiting: sent after them, in order, so the server sees them as they were made.
  if (state.outbox.length && queues(ops, true)) {
    saveOutbox([...state.outbox, { key, source, ops }]);
    capture("outbox_queued", { ops: ops.length });
    void sync();
    return queuedResult(key);
  }
  let res: ApplyResult;
  try {
    const { data, error } = await supabase.rpc("collection_apply", {
      p_ops: ops, p_source: source, p_source_id: null, p_idempotency_key: key,
    });
    if (error) throw error;
    res = data as ApplyResult;
  } catch (e) {
    // Adds that couldn't reach the server stay on screen and wait in the outbox (contract/offline-2026-10-31.md § 3).
    if (state.userId && queues(ops, isNetworkError(e))) {
      saveOutbox([...state.outbox, { key, source, ops }]);
      capture("outbox_queued", { ops: ops.length });
      return queuedResult(key);
    }
    showAdds(ops, -1);
    void sync();
    throw e;
  }
  capture("collection_changed", { source, ops: ops.length, copies: ops.reduce((n, op) => n + (op.delta ?? 0), 0) });
  reflect(res);
  void sync();
  return res;
}

export async function undoBatch(batchId: string): Promise<ApplyResult> {
  if (demo) {
    const res = demo.undo(batchId);
    reflect(res);
    return res;
  }
  // A batch still in the outbox: out of the outbox and off the screen, nothing to undo on the server.
  if (batchId.startsWith("queued:")) {
    const key = batchId.slice("queued:".length);
    const b = state.outbox.find((x) => x.key === key);
    if (b) {
      showAdds(b.ops, -1);
      saveOutbox(state.outbox.filter((x) => x.key !== key));
    }
    capture("collection_undone");
    return queuedResult(key);
  }
  const { data, error } = await supabase.rpc("collection_undo", {
    p_batch_id: batchId, p_idempotency_key: crypto.randomUUID(),
  });
  if (error) throw error;
  capture("collection_undone");
  const res = data as ApplyResult;
  reflect(res);
  void sync();
  return res;
}

/**
 * A batch's added copies (and the binders they go into), shown while the server works (sign 1), or taken back when
 * the call fails (-1). Removals wait for the server, which owns the binder rules. Memory only: the answer or a sync
 * replaces these rows.
 */
function showAdds(ops: CollectionOp[], sign: 1 | -1) {
  if (!ops.some((op) => (op.delta ?? 0) > 0)) return;
  const { items, allocs } = shiftAdds(state.items, ops, sign);
  set({ items });
  shiftBinders(allocs);
}

/**
 * The items with each op's added copies shifted by `sign`, keeping a held item's seq so the sync row that follows is
 * never skipped as older, and the binder copies to shift with them. Cases: testdata/show-adds/cases.json.
 */
export function shiftAdds(held: Map<string, Item>, ops: CollectionOp[], sign: 1 | -1): { items: Map<string, Item>; allocs: Alloc[] } {
  const items = new Map(held);
  const allocs: Alloc[] = [];
  for (const op of ops) {
    const d = op.delta ?? 0;
    if (d <= 0) continue;
    const finish = op.finish ?? "nonfoil", condition = op.condition ?? "NM", lang = op.lang ?? "en";
    const k = itemKey(op.card_id, finish, condition, lang), it = items.get(k);
    const qty = (it?.qty ?? 0) + sign * d;
    if (qty > 0) items.set(k, { k, cardId: op.card_id, finish, condition, lang, qty, seq: it?.seq ?? 0 });
    else items.delete(k);
    if (op.binder_id) allocs.push({ binderId: op.binder_id, cardId: op.card_id, finish, condition, lang, qty: sign * d, seq: 0 });
  }
  return { items, allocs };
}

/** Writes a batch result into memory (not IndexedDB or the cursor: the following sync owns those). */
function reflect(res: ApplyResult) {
  const items = new Map(state.items);
  for (const r of res.items) {
    const it = toItem([r.card_id, r.finish, r.condition, r.lang, r.qty, r.seq]);
    if (it.qty > 0) items.set(it.k, it);
    else items.delete(it.k);
  }
  set({ items, summary: res.summary });
  reflectBinders(res);
}

export interface HistoryEntry {
  at: string;
  finish: Finish;
  condition: Condition;
  lang: string;
  delta: number;
  qty_after: number;
  source: string;
  batch_id: string;
  undone: boolean;
}

export async function fetchHistory(cardId: string): Promise<HistoryEntry[]> {
  if (demo) return demo.history(cardId);
  const { data, error } = await supabase.rpc("collection_card_history", { p_card_id: cardId, p_limit: 50 });
  if (error) throw error;
  return (data ?? []) as HistoryEntry[];
}

/** The collection for the signed-in account; starts (or switches) the store when userId changes. */
export function useCollection(userId: string | null): CollectionState & { refresh: () => Promise<void> } {
  useEffect(() => {
    if (userId) void start(userId);
  }, [userId]);
  const snap = useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => state,
  );
  const refresh = useCallback(() => sync(), []);
  return { ...(snap.userId === userId ? snap : empty), refresh };
}

/** The dev demo backend while it's running (prices and trades read from it). */
export const demoBackend = (): DemoBackend | null => demo;
