// Binders, "for trade" and wants (contract/binders-wants-2026-10-17.md). A binder holds some of an item's copies
// (an allocation); copies no binder holds are Unsorted. Allocations only change through collection_apply,
// binder_move and binder_delete on the server, which keeps them within each item's copies; this store mirrors
// binders, allocations and wants in memory (cached in localStorage per account) and syncs them by seq
// (library_changes) right after the collection's own sync. Same rules as apps/ios/Table1/Library/Binders.swift.
import { useEffect, useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";
import { DEMO_USER, demoBackend, itemKey, type ApplyResult, type Finish, type Item } from "./collection";
import { entriesOf, finishOf, type CardList } from "./lists";

export interface Binder { id: string; name: string; for_trade: boolean; seq: number }
export interface Alloc { binderId: string; cardId: string; finish: Finish; condition: Item["condition"]; lang: string; qty: number; seq: number }
/** No cardId = any printing; no finish = any finish of that printing. */
export interface Want { oracleId: string; cardId: string | null; finish: Finish | null; qty: number; maxUsd: number | null; seq: number }

export type AllocRow = [string, string, Finish, Item["condition"], string, number, number];
export type WantRow = [string, string | null, Finish | null, number, number | string | null, number];

export const allocItemKey = (a: Alloc) => itemKey(a.cardId, a.finish, a.condition, a.lang);
export const allocKey = (a: Alloc) => `${a.binderId}|${allocItemKey(a)}`;
export const wantKey = (o: string, c: string | null, f: string | null) => `${o}|${c ?? ""}|${f ?? ""}`;

export const toAlloc = ([binderId, cardId, finish, condition, lang, qty, seq]: AllocRow): Alloc =>
  ({ binderId, cardId, finish, condition, lang, qty, seq });
export const toWant = ([oracleId, cardId, finish, qty, max, seq]: WantRow): Want =>
  ({ oracleId, cardId, finish, qty, maxUsd: max == null ? null : Number(max), seq });

export interface BinderMove { item: Item; from: string | null; to: string | null; qty: number }
export interface WantOp { oracle_id: string; card_id?: string | null; finish?: Finish | null; qty?: number; delta?: number; max_usd?: number | null }

/* ── rules (shared with the dev demo; the server is the authority) ─────── */

/**
 * One item's allocations after a change: hints first (a binder's copies added, or taken out of it first), then
 * whatever exceeds `newQty` comes out of binders not for trade, then for-trade binders, each by name. Unsorted copies
 * are what's left over, so they always go first.
 */
export function planAllocations(current: Map<string, number>, hints: Map<string, number>, newQty: number,
                                binders: Map<string, Binder>): Map<string, number> {
  const out = new Map(current);
  for (const [b, d] of hints) if (binders.has(b)) out.set(b, Math.max(0, (out.get(b) ?? 0) + d));
  let excess = [...out.values()].reduce((n, q) => n + q, 0) - newQty;
  if (excess > 0) {
    const order = [...out.keys()].filter((b) => (out.get(b) ?? 0) > 0).sort((a, b) => {
      const x = binders.get(a), y = binders.get(b);
      const ka = [x?.for_trade ? 1 : 0, x?.name.toLowerCase() ?? "", a] as const, kb = [y?.for_trade ? 1 : 0, y?.name.toLowerCase() ?? "", b] as const;
      return ka[0] - kb[0] || (ka[1] < kb[1] ? -1 : ka[1] > kb[1] ? 1 : 0) || (ka[2] < kb[2] ? -1 : ka[2] > kb[2] ? 1 : 0);
    });
    for (const b of order) {
      if (excess <= 0) break;
      const take = Math.min(out.get(b) ?? 0, excess);
      out.set(b, (out.get(b) ?? 0) - take);
      excess -= take;
    }
  }
  return out;
}

/** The want a trade's get meets first: that printing and finish, then that printing, then any printing. */
export function wantFor(oracleId: string, cardId: string, finish: string, wants: Want[]): Want | undefined {
  const live = wants.filter((w) => w.oracleId === oracleId && w.qty > 0);
  return live.find((w) => w.cardId === cardId && w.finish === finish) ?? live.find((w) => w.cardId === cardId && w.finish == null)
    ?? live.find((w) => w.cardId == null);
}

/** Takes `qty` copies of a printing off the wants they meet, in that order. Returns the wants that changed. */
export function meetWants(oracleId: string, cardId: string, finish: string, qty: number, wants: Map<string, Want>): Want[] {
  let left = qty;
  const changed: Want[] = [];
  while (left > 0) {
    const w = wantFor(oracleId, cardId, finish, [...wants.values()]);
    if (!w) break;
    const n = Math.min(left, w.qty);
    const nw = { ...w, qty: w.qty - n };
    wants.set(wantKey(w.oracleId, w.cardId, w.finish), nw);
    changed.push(nw);
    left -= n;
  }
  return changed;
}

export interface MissingLine { cardId: string; finish: Finish; short: number; lists: string[] }

/**
 * Every list line (not Considering, not roto event decks) short of copies, per printing × finish, with the largest
 * need across lists: lists don't reserve copies, so one set of copies covers them all. Basic lands (`basics`) are never
 * missing (contract/basics-2026-10-24.md).
 */
export function missingLines(lists: CardList[], owned: Map<string, number>, basics: Set<string>): MissingLine[] {
  const need = new Map<string, { max: number; lists: string[] }>();
  for (const l of lists) {
    if (l.eventId) continue;
    const mine = new Map<string, number>();
    for (const e of entriesOf(l)) {
      if (e.board === "maybe" || basics.has(e.cardId)) continue;
      const k = `${e.cardId}|${finishOf(e)}`;
      mine.set(k, (mine.get(k) ?? 0) + e.qty);
    }
    for (const [k, n] of mine) {
      if (n <= (owned.get(k) ?? 0)) continue;
      const v = need.get(k) ?? { max: 0, lists: [] };
      v.max = Math.max(v.max, n);
      v.lists.push(l.name);
      need.set(k, v);
    }
  }
  return [...need].map(([k, v]) => {
    const [cardId, finish] = k.split("|") as [string, Finish];
    return { cardId, finish, short: v.max - (owned.get(k) ?? 0), lists: v.lists.sort() };
  }).sort((a, b) => b.short - a.short || (`${a.cardId}|${a.finish}` < `${b.cardId}|${b.finish}` ? -1 : 1));
}

/* ── store ────────────────────────────────────────────────────────────── */

export interface BindersState {
  userId: string | null;
  binders: Binder[]; // live, by name
  allocs: Map<string, Alloc>;
  wants: Map<string, Want>;
  error: string | null;
  version: number;
}

const empty: BindersState = { userId: null, binders: [], allocs: new Map(), wants: new Map(), error: null, version: 0 };
let state = empty;
let cursor = 0;
let byItem = new Map<string, Alloc[]>();
let syncRun: Promise<void> | null = null;
let syncAgain = false;
const listeners = new Set<() => void>();

const byName = (a: Binder, b: Binder) => (a.name.toLowerCase() < b.name.toLowerCase() ? -1 : a.name.toLowerCase() > b.name.toLowerCase() ? 1 : 0);

function set(patch: Partial<BindersState>) {
  state = { ...state, ...patch, version: state.version + 1 };
  if (patch.allocs) {
    byItem = new Map();
    for (const a of state.allocs.values()) {
      if (a.qty <= 0) continue;
      const k = allocItemKey(a);
      byItem.set(k, [...(byItem.get(k) ?? []), a]);
    }
  }
  listeners.forEach((l) => l());
}

const cacheKey = (userId: string) => `table1.library.binders.${userId}`;

function saveCache() {
  if (!state.userId || demoBackend()) return;
  try {
    localStorage.setItem(cacheKey(state.userId), JSON.stringify({
      binders: state.binders, allocs: [...state.allocs.values()], wants: [...state.wants.values()], cursor,
    }));
  } catch {
    /* storage blocked or full: the next visit syncs from 0 */
  }
}

export function startBinders(userId: string) {
  if (state.userId === userId) return void syncBinders();
  const demo = demoBackend();
  if (userId === DEMO_USER && !demo) return; // the collection store starts this once the demo has loaded
  cursor = 0;
  if (demo) {
    state = { ...empty, userId, version: state.version + 1 };
    set({ binders: [...demo.binders.values()].sort(byName), allocs: new Map(demo.allocs), wants: new Map(demo.wants) });
    return;
  }
  state = { ...empty, userId, version: state.version + 1 };
  try {
    const saved = JSON.parse(localStorage.getItem(cacheKey(userId)) ?? "null") as
      { binders: Binder[]; allocs: Alloc[]; wants: Want[]; cursor: number } | null;
    if (saved) {
      cursor = saved.cursor;
      set({ binders: saved.binders, allocs: new Map(saved.allocs.map((a) => [allocKey(a), a])),
            wants: new Map(saved.wants.map((w) => [wantKey(w.oracleId, w.cardId, w.finish), w])) });
    }
  } catch {
    cursor = 0;
  }
  void syncBinders();
}

export function stopBinders() {
  state = { ...empty, version: state.version + 1 };
  cursor = 0;
  byItem = new Map();
  listeners.forEach((l) => l());
}

/** Pulls binders, allocations and wants changed after the local cursor. */
export function syncBinders(): Promise<void> {
  if (!state.userId || demoBackend()) return Promise.resolve();
  if (syncRun) {
    syncAgain = true;
    return syncRun;
  }
  const userId = state.userId;
  syncRun = (async () => {
    try {
      for (let pages = 0; pages < 200; pages++) {
        const { data, error } = await supabase.rpc("library_changes", { p_after: cursor, p_limit: 5000 });
        if (error) throw error;
        if (state.userId !== userId) return;
        const r = data as { resync: boolean; binders: (Binder & { deleted: boolean })[]; binder_items: AllocRow[]; wants: WantRow[]; next: number; more: boolean };
        if (r.resync) {
          cursor = 0;
          set({ binders: [], allocs: new Map(), wants: new Map() });
          continue;
        }
        let binders = state.binders;
        for (const b of r.binders) {
          binders = binders.filter((x) => x.id !== b.id);
          if (!b.deleted) binders = [...binders, { id: b.id, name: b.name, for_trade: b.for_trade, seq: b.seq }];
        }
        set({ binders: binders.sort(byName), allocs: merged(r.binder_items.map(toAlloc)), wants: mergedWants(r.wants.map(toWant)) });
        cursor = r.next;
        if (!r.more) break;
      }
      set({ error: null });
      saveCache();
    } catch (e) {
      set({ error: e instanceof Error ? e.message : String((e as { message?: string })?.message ?? e) });
    } finally {
      syncRun = null;
      if (syncAgain) {
        syncAgain = false;
        void syncBinders();
      }
    }
  })();
  return syncRun;
}

function merged(rows: Alloc[]): Map<string, Alloc> {
  const allocs = new Map(state.allocs);
  for (const a of rows) {
    const k = allocKey(a), held = allocs.get(k);
    if (held && held.seq > a.seq) continue;
    if (a.qty > 0) allocs.set(k, a);
    else allocs.delete(k);
  }
  return allocs;
}

function mergedWants(rows: Want[]): Map<string, Want> {
  const wants = new Map(state.wants);
  for (const w of rows) {
    const k = wantKey(w.oracleId, w.cardId, w.finish), held = wants.get(k);
    if (held && held.seq > w.seq) continue;
    if (w.qty > 0) wants.set(k, w);
    else wants.delete(k);
  }
  return wants;
}

/** Writes rows a call returned into memory (the next sync owns the cursor and the cache). */
export function reflectBinders(res: { binder_items?: AllocRow[]; wants?: WantRow[] }) {
  const a = res.binder_items ?? [], w = res.wants ?? [];
  if (!a.length && !w.length) return;
  set({ allocs: merged(a.map(toAlloc)), wants: mergedWants(w.map(toWant)) });
}

/** Adds (or, negative, takes back) copies shown in binders before the server answers (collection `showAdds`). */
export function shiftBinders(rows: Alloc[]) {
  if (rows.length) set({ allocs: shiftAllocs(state.allocs, rows) });
}

export function shiftAllocs(held: Map<string, Alloc>, rows: Alloc[]): Map<string, Alloc> {
  const allocs = new Map(held);
  for (const a of rows) {
    const k = allocKey(a), it = allocs.get(k);
    const qty = (it?.qty ?? 0) + a.qty;
    if (qty > 0) allocs.set(k, { ...(it ?? a), qty });
    else allocs.delete(k);
  }
  return allocs;
}

/* ── reading ──────────────────────────────────────────────────────────── */

export const bindersNow = () => state;
export const binderById = (id: string | null | undefined) => (id ? state.binders.find((b) => b.id === id) : undefined);
export const liveWants = () => [...state.wants.values()].filter((w) => w.qty > 0).sort((a, b) => b.seq - a.seq);

/** Where an item's copies are: each binder holding some, by name, then Unsorted (never below 0). */
export function placement(it: Item): { binders: { binder: Binder; qty: number }[]; unsorted: number } {
  const held = (byItem.get(it.k) ?? []).flatMap((a) => {
    const b = binderById(a.binderId);
    return b ? [{ binder: b, qty: a.qty }] : [];
  }).sort((x, y) => byName(x.binder, y.binder));
  return { binders: held, unsorted: Math.max(0, it.qty - held.reduce((n, h) => n + h.qty, 0)) };
}

/** "Trade binder 2 · Unsorted 1", or null when every copy is Unsorted. */
export function placementText(it: Item): string | null {
  const p = placement(it);
  if (!p.binders.length) return null;
  return [...p.binders.map((h) => `${h.binder.name} ${h.qty}`), ...(p.unsorted ? [`Unsorted ${p.unsorted}`] : [])].join(" · ");
}

/** Copies of an item in for-trade binders, and the for-trade binder holding most of them. */
export function forTrade(k: string): { qty: number; binderId: string | null } {
  const held = (byItem.get(k) ?? []).filter((a) => binderById(a.binderId)?.for_trade);
  const top = held.reduce<Alloc | null>((m, a) => (!m || a.qty > m.qty ? a : m), null);
  return { qty: held.reduce((n, a) => n + a.qty, 0), binderId: top?.binderId ?? null };
}

/** Copies each binder holds (clamped to what each item has), and the Unsorted total. */
export function binderTotals(items: Map<string, Item>): { byBinder: Map<string, number>; unsorted: number } {
  const by = new Map<string, number>();
  let unsorted = 0;
  for (const it of items.values()) {
    const p = placement(it);
    for (const h of p.binders) by.set(h.binder.id, (by.get(h.binder.id) ?? 0) + Math.min(h.qty, it.qty));
    unsorted += p.unsorted;
  }
  return { byBinder: by, unsorted };
}

/** Items with copies in a binder (null = Unsorted), as items whose qty is the copies there. */
export function itemsIn(binderId: string | null, items: Map<string, Item>): Item[] {
  const out: Item[] = [];
  for (const it of items.values()) {
    const p = placement(it);
    const n = binderId == null ? p.unsorted : p.binders.find((h) => h.binder.id === binderId)?.qty ?? 0;
    if (n > 0) out.push({ ...it, qty: Math.min(n, it.qty) });
  }
  return out;
}

/* ── writing ──────────────────────────────────────────────────────────── */

/** Creates (new id) or renames / flags a binder. */
export async function saveBinder(id: string | null, name: string, forTradeFlag: boolean): Promise<Binder> {
  const old = binderById(id);
  const bid = id ?? crypto.randomUUID();
  const demo = demoBackend();
  let saved: Binder;
  if (demo) saved = demo.saveBinder(bid, name, forTradeFlag);
  else {
    const { data, error } = await supabase.rpc("binder_save", { p_id: bid, p_name: name, p_for_trade: forTradeFlag });
    if (error) throw error;
    const r = data as Binder;
    saved = { id: r.id, name: r.name, for_trade: r.for_trade, seq: r.seq };
  }
  set({ binders: [...state.binders.filter((b) => b.id !== saved.id), saved].sort(byName) });
  if (!old) capture("binder_created", { for_trade: saved.for_trade });
  else if (old.name !== saved.name || old.for_trade !== saved.for_trade) {
    capture("binder_updated", { renamed: old.name !== saved.name, for_trade: saved.for_trade });
  }
  if (!demo) void syncBinders();
  return saved;
}

/** Deletes a binder; its copies go back to Unsorted. */
export async function deleteBinder(b: Binder) {
  const copies = [...state.allocs.values()].filter((a) => a.binderId === b.id).reduce((n, a) => n + a.qty, 0);
  const demo = demoBackend();
  let rows: AllocRow[];
  if (demo) rows = demo.deleteBinder(b.id);
  else {
    const { data, error } = await supabase.rpc("binder_delete", { p_id: b.id, p_idempotency_key: crypto.randomUUID() });
    if (error) throw error;
    rows = (data as { binder_items: AllocRow[] }).binder_items ?? [];
  }
  const allocs = merged(rows.map(toAlloc));
  for (const [k, a] of allocs) if (a.binderId === b.id) allocs.delete(k);
  set({ binders: state.binders.filter((x) => x.id !== b.id), allocs });
  capture("binder_deleted", { copies });
  if (!demo) void syncBinders();
}

/** Moves copies; one batch, so Undo moves them back. Returns the batch id. */
export async function moveCopies(moves: BinderMove[]): Promise<string> {
  if (!moves.length) return "";
  const demo = demoBackend();
  let res: ApplyResult;
  if (demo) res = demo.move(moves);
  else {
    const { data, error } = await supabase.rpc("binder_move", {
      p_moves: moves.map((m) => ({ card_id: m.item.cardId, finish: m.item.finish, condition: m.item.condition, lang: m.item.lang,
                                   from: m.from, to: m.to, qty: m.qty })),
      p_idempotency_key: crypto.randomUUID(),
    });
    if (error) throw error;
    res = data as ApplyResult;
  }
  reflectBinders(res);
  capture("binder_copies_moved", { copies: moves.reduce((n, m) => n + m.qty, 0), from: moves[0].from ? "binder" : "unsorted",
                                   to: moves[0].to ? "binder" : "unsorted" });
  if (!demo) void syncBinders();
  return res.batch_id;
}

/** One wishlist edit. */
export async function applyWants(ops: WantOp[], event?: string, props: Record<string, string | number | boolean> = {}) {
  if (!ops.length) return;
  const demo = demoBackend();
  let rows: WantRow[];
  if (demo) rows = demo.applyWants(ops);
  else {
    const { data, error } = await supabase.rpc("wants_apply", { p_ops: ops, p_idempotency_key: crypto.randomUUID() });
    if (error) throw error;
    rows = (data as { wants: WantRow[] }).wants ?? [];
  }
  reflectBinders({ wants: rows });
  if (event) capture(event, props);
}

/** Binders, allocations and wants for the signed-in account; starts (or switches) the store when userId changes. */
export function useBinders(userId: string | null): BindersState {
  useEffect(() => {
    if (userId) startBinders(userId);
  }, [userId]);
  const snap = useSyncExternalStore((l) => {
    listeners.add(l);
    return () => listeners.delete(l);
  }, () => state);
  return snap.userId === userId ? snap : empty;
}
