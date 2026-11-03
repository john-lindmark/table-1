// Following someone else's binder, deck or cube (contract/follows-2026-10-25.md). The server groups changes into
// updates (quiet 30 minutes, at most one every 6 hours); this keeps the Following list, each item's follow state and
// its Changes. Rules shared with iOS and Android in testdata/follows/cases.json.
import { useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";
import { isLibraryDemo, loadDemoLists } from "./libraryDemo";

export type FollowKind = "binder" | "deck" | "cube";

export interface FollowUpdateSummary { at: string; added: number; removed: number }

export interface FollowState { following: boolean; push: boolean; unseen: number; last_update: FollowUpdateSummary | null }

export interface Follow {
  kind: FollowKind;
  id: string;
  available: boolean;
  push: boolean;
  followed_at: string;
  unseen: number;
  name?: string;
  format?: string;
  for_trade?: boolean;
  cards?: number;
  owner?: { display_name: string; avatar_url?: string };
  /** Reaches you on their profile: open /u/<user_id>/<kind>/<id>. */
  user_id?: string;
  /** Reaches you through the link you followed with: open /l/<token>. */
  token?: string;
  /** The printing its tile shows: the owner's hero, else its first card by copies (absent when it holds nothing). */
  art?: string;
  last_update?: FollowUpdateSummary;
}

/** [card_id, board | null, delta]: delta > 0 added, < 0 taken out. */
export type FollowCardWire = [string, string | null, number];
export interface FollowUpdate { at: string; added: number; removed: number; cards: FollowCardWire[] }
export interface FollowChanges { kind: FollowKind; id: string; name?: string; updates: FollowUpdate[] }
export interface FollowRow { card_id: string; board: string | null; qty: number }

/* ── rules ───────────────────────────────────────────────────────────── */

export const MINUS = "−";

/** "just now" · "N min ago" · "N h ago" · "N d ago" (under 30 days) · "N mo ago". */
export function ago(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`;
  const d = Math.floor(s / 86400);
  return d < 30 ? `${d} d ago` : `${Math.floor(d / 30)} mo ago`;
}

/** "+12 −8", "+3", "−2". */
export const change = (added: number, removed: number) =>
  [added > 0 ? `+${added}` : null, removed > 0 ? `${MINUS}${removed}` : null].filter(Boolean).join(" ");

export const since = (u: FollowUpdateSummary, now: Date) =>
  `${change(u.added, u.removed)} · ${ago((now.getTime() - new Date(u.at).getTime()) / 1000)}`;

/** A Following row's detail line. */
export function followDetail(f: Follow, now: Date): string {
  if (!f.available) return "This isn't available";
  const line = f.last_update ? since(f.last_update, now) : "No changes yet";
  return f.push ? line : `${line} · pushes off`;
}

/** The Library home row: "3 followed · 1 updated". */
export function followHome(items: Follow[]): string {
  const updated = items.filter((f) => f.available && f.unseen > 0).length;
  return `${items.length} followed${updated ? ` · ${updated} updated` : ""}`;
}

/** An update's cards as Added and Taken out, biggest first, then by card id (qty positive in both). */
export function followSections(cards: FollowCardWire[]): { added: FollowRow[]; removed: FollowRow[] } {
  const order = (a: FollowRow, b: FollowRow) =>
    b.qty - a.qty || (a.card_id < b.card_id ? -1 : a.card_id > b.card_id ? 1 : (a.board ?? "") < (b.board ?? "") ? -1 : (a.board ?? "") > (b.board ?? "") ? 1 : 0);
  return {
    added: cards.filter((c) => c[2] > 0).map(([card_id, board, qty]) => ({ card_id, board, qty })).sort(order),
    removed: cards.filter((c) => c[2] < 0).map(([card_id, board, qty]) => ({ card_id, board, qty: -qty })).sort(order),
  };
}

export const followTitle = (f: Follow) => (f.available ? f.name ?? "Untitled" : `A ${f.kind} you followed`);
const KIND_LABEL: Record<FollowKind, string> = { binder: "Binder", deck: "Deck", cube: "Cube" };
export const followSubtitle = (f: Follow) => [KIND_LABEL[f.kind], f.owner?.display_name].filter(Boolean).join(" · ");

/** Where a followed item opens: its profile section, or the link it was followed through. */
export function followHref(f: Follow): string | null {
  if (!f.available) return null;
  if (f.token) return `/l/${f.token}`;
  return f.user_id ? `/u/${f.user_id}/${f.kind}/${f.id}` : null;
}

/* ── store ───────────────────────────────────────────────────────────── */

interface State { items: Follow[] | null; states: Record<string, FollowState>; error: string | null }
let state: State = { items: null, states: {}, error: null };
const subs = new Set<() => void>();
const set = (patch: Partial<State>) => {
  state = { ...state, ...patch };
  subs.forEach((s) => s());
};

export function useFollows() {
  return useSyncExternalStore((cb) => {
    subs.add(cb);
    return () => subs.delete(cb);
  }, () => state);
}

export function resetFollows() {
  set({ items: null, states: {}, error: null });
}

async function rpc<T>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

/** Loads follows_list; returns it (null when it failed). */
export async function loadFollows(): Promise<Follow[] | null> {
  try {
    const d = await demo();
    const items = d ? d.list() : (await rpc<{ items: Follow[] }>("follows_list")).items;
    set({ items, error: null });
    return items;
  } catch (e) {
    set({ error: (e as Error).message });
    return null;
  }
}

export async function loadFollowState(kind: FollowKind, id: string) {
  try {
    const d = await demo();
    const s = d ? d.state(id) : await rpc<FollowState>("follow_get", { p_kind: kind, p_id: id });
    set({ states: { ...state.states, [id]: s } });
  } catch (e) {
    set({ error: (e as Error).message });
  }
}

/** Follow / unfollow, or pushes on / off (`push` null keeps it). `token`: the link being looked through. */
export async function setFollow(kind: FollowKind, id: string, follow: boolean, opts: { push?: boolean; token?: string; from: string }) {
  const d = await demo();
  const s = d ? d.set(kind, id, follow, opts.push ?? null)
    : await rpc<FollowState>("follow_set", { p_kind: kind, p_id: id, p_follow: follow, p_push: opts.push ?? null, p_token: opts.token ?? null });
  set({ states: { ...state.states, [id]: s } });
  capture("follow_changed", { kind, following: s.following, push: s.push, from: opts.from });
  await loadFollows();
}

/** The updates since you followed; opening them marks them seen. */
export async function fetchFollowChanges(kind: FollowKind, id: string): Promise<FollowChanges> {
  const d = await demo();
  const c = d ? d.changes(id) : await rpc<FollowChanges>("follow_changes", { p_kind: kind, p_id: id });
  const st = state.states[id];
  set({
    states: st ? { ...state.states, [id]: { ...st, unseen: 0 } } : state.states,
    items: state.items?.map((f) => (f.id === id ? { ...f, unseen: 0 } : f)) ?? null,
  });
  capture("follow_changes_viewed", { kind, updates: c.updates.length });
  return c;
}

/* ── dev demo (`?demo`) ─────────────────────────────────────────────── */

/** Mara's deck in the friends demo (friendsDemo.ts id(9001)) and her trade binder. */
export const DEMO_FOLLOWED_DECK = "d0000000-0000-0000-0000-0000000f9001";
const DEMO_FOLLOWED_BINDER = "d0000000-0000-0000-0000-0000000fb001";
const DEMO_MARA = "d0000000-0000-0000-0000-0000000f0001";

class FollowsDemo {
  follows = new Map<string, Follow>();
  updates = new Map<string, FollowUpdate[]>();

  constructor(entries: { cardId: string; board: string; qty: number }[], format: string) {
    const at = (h: number) => new Date(Date.now() - h * 3600_000).toISOString();
    const main = entries.filter((e) => e.board === "main"), side = entries.filter((e) => e.board === "side");
    const recent: FollowCardWire[] = [
      ...main.slice(0, 2).map((e): FollowCardWire => [e.cardId, "main", 2]),
      ...side.slice(0, 1).map((e): FollowCardWire => [e.cardId, "side", 1]),
      ...main.slice(2, 4).map((e): FollowCardWire => [e.cardId, "main", -1]),
    ];
    const older = side.slice(1, 3).map((e): FollowCardWire => [e.cardId, "side", -1]);
    const update = (h: number, cards: FollowCardWire[]): FollowUpdate => ({
      at: at(h), added: cards.filter((c) => c[2] > 0).reduce((n, c) => n + c[2], 0),
      removed: cards.filter((c) => c[2] < 0).reduce((n, c) => n - c[2], 0), cards,
    });
    const ups = [update(2, recent), update(50, older)].filter((u) => u.cards.length);
    this.updates.set(DEMO_FOLLOWED_DECK, ups);
    const mara = { display_name: "Mara Quinn" };
    const last = ups[0] && { at: ups[0].at, added: ups[0].added, removed: ups[0].removed };
    this.follows.set(DEMO_FOLLOWED_DECK, {
      kind: "deck", id: DEMO_FOLLOWED_DECK, available: true, push: true, followed_at: at(200), unseen: last ? 1 : 0,
      name: "Mono-red prowess", format, cards: entries.filter((e) => e.board !== "maybe").reduce((n, e) => n + e.qty, 0),
      owner: mara, user_id: DEMO_MARA, ...(last ? { last_update: last } : {}),
      ...(main.length ? { art: main.slice().sort((x, y) => y.qty - x.qty)[0].cardId } : {}),
    });
    this.follows.set(DEMO_FOLLOWED_BINDER, {
      kind: "binder", id: DEMO_FOLLOWED_BINDER, available: true, push: false, followed_at: at(30), unseen: 0,
      name: "Trade binder", for_trade: true, cards: 12, owner: mara, user_id: DEMO_MARA,
    });
    const gone = "d0000000-0000-0000-0000-0000000fc009";
    this.follows.set(gone, { kind: "cube", id: gone, available: false, push: true, followed_at: at(400), unseen: 0 });
  }

  list(): Follow[] {
    const t = (f: Follow) => (f.last_update ? new Date(f.last_update.at).getTime() : 0);
    return [...this.follows.values()].sort((a, b) =>
      Number(b.unseen > 0) - Number(a.unseen > 0) || t(b) - t(a) || Number(!a.name) - Number(!b.name) || (a.name ?? "").localeCompare(b.name ?? ""));
  }

  state(id: string): FollowState {
    const f = this.follows.get(id);
    return f ? { following: true, push: f.push, unseen: f.unseen, last_update: f.last_update ?? null }
      : { following: false, push: true, unseen: 0, last_update: null };
  }

  set(kind: FollowKind, id: string, follow: boolean, push: boolean | null): FollowState {
    if (!follow) this.follows.delete(id);
    else {
      const f = this.follows.get(id);
      this.follows.set(id, f ? { ...f, push: push ?? f.push }
        : { kind, id, available: true, push: push ?? true, followed_at: new Date().toISOString(), unseen: 0,
            owner: { display_name: "Mara Quinn" }, user_id: DEMO_MARA });
    }
    return this.state(id);
  }

  changes(id: string): FollowChanges {
    const f = this.follows.get(id);
    if (!f?.available) throw new Error("This isn't available");
    this.follows.set(id, { ...f, unseen: 0 });
    return { kind: f.kind, id, name: f.name, updates: this.updates.get(id) ?? [] };
  }
}

let demoP: Promise<FollowsDemo> | null = null;
async function demo(): Promise<FollowsDemo | null> {
  if (!isLibraryDemo()) return null;
  demoP ??= loadDemoLists().then((lists) => {
    const deck = lists.find((l) => l.kind === "deck");
    return new FollowsDemo(deck?.versions[deck.versions.length - 1]?.entries ?? [], deck?.format ?? "modern");
  });
  return demoP;
}
