// Hero cards (contract/library-heroes-2026-10-19.md): the few cards that stand for a deck, a cube, a binder or the whole
// collection. Picked by card (oracle id), so changing a printing keeps the hero; the art shown is the printing the
// list or binder holds. Fetched with library_heroes when the Library starts and each time the tab comes back, cached
// per account; a toggle shows at once and library_heroes_set's answer replaces it (on failure, refetch).
import { useEffect, useSyncExternalStore } from "react";
import { coverPrinting, type Catalog } from "./catalog";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";

export const HERO_LIMIT = 10;

export type HeroScope = { kind: "collection" } | { kind: "list"; id: string } | { kind: "binder"; id: string };

export const COLLECTION_SCOPE: HeroScope = { kind: "collection" };

/** Key in the store and the cache. */
export const scopeKey = (s: HeroScope) => (s.kind === "collection" ? "collection" : `${s.kind}:${s.id.toLowerCase()}`);

/** From a card detail's context: a deck/cube, a binder (not Unsorted), or the collection. */
export function scopeOf(context: { list?: string; binder?: string } | undefined, unsorted: string): HeroScope | null {
  if (context?.list) return { kind: "list", id: context.list };
  if (context?.binder) return context.binder === unsorted ? null : { kind: "binder", id: context.binder };
  return COLLECTION_SCOPE;
}

interface Row { scope: "collection" | "list" | "binder"; target_id: string | null; oracle_ids: string[] }

const rowKey = (r: Row) => (r.scope === "collection" ? "collection" : `${r.scope}:${(r.target_id ?? "").toLowerCase()}`);

interface HeroesState { userId: string | null; heroes: Record<string, string[]>; error: string | null; version: number }

const empty: HeroesState = { userId: null, heroes: {}, error: null, version: 0 };
let state = empty;
let demo = false;
const listeners = new Set<() => void>();

function set(patch: Partial<HeroesState>) {
  state = { ...state, ...patch, version: state.version + 1 };
  listeners.forEach((l) => l());
}

const cacheKey = (userId: string) => `table1.heroes.${userId}`;

function loadCache(userId: string): Record<string, string[]> {
  try {
    const raw = localStorage.getItem(cacheKey(userId));
    return raw ? (JSON.parse(raw) as Record<string, string[]>) : {};
  } catch {
    return {};
  }
}

function saveCache() {
  if (!state.userId || demo) return;
  try {
    localStorage.setItem(cacheKey(state.userId), JSON.stringify(state.heroes));
  } catch {
    /* storage blocked: the server has them */
  }
}

export function startHeroes(userId: string) {
  if (state.userId === userId) return void refreshHeroes();
  demo = false;
  state = { ...empty, userId, heroes: loadCache(userId) };
  listeners.forEach((l) => l());
  void refreshHeroes();
}

/** Dev demo: heroes live in memory, seeded once. */
export function startDemoHeroes(userId: string, seed: Record<string, string[]>) {
  if (state.userId === userId && demo) return;
  demo = true;
  state = { ...empty, userId, heroes: seed };
  listeners.forEach((l) => l());
}

export const heroesNow = () => state;

/** All of the account's heroes (a few rows, so no cursor). */
export async function refreshHeroes() {
  const user = state.userId;
  if (!user || demo) return;
  const { data, error } = await supabase.rpc("library_heroes");
  if (state.userId !== user) return;
  if (error) return set({ error: error.message });
  const heroes: Record<string, string[]> = {};
  for (const r of (data ?? []) as Row[]) if (!heroes[rowKey(r)]) heroes[rowKey(r)] = r.oracle_ids.map((x) => x.toLowerCase());
  set({ heroes, error: null });
  saveCache();
}

export const heroesOf = (s: HeroScope, h: Record<string, string[]> = state.heroes) => h[scopeKey(s)] ?? [];
export const isHero = (oracleId: string | null | undefined, s: HeroScope, h: Record<string, string[]> = state.heroes) =>
  !!oracleId && heroesOf(s, h).includes(oracleId.toLowerCase());

/** The next list after a toggle, or null when the scope already has HERO_LIMIT heroes. */
export function toggledList(ids: string[], oracleId: string): string[] | null {
  const o = oracleId.toLowerCase();
  if (ids.includes(o)) return ids.filter((x) => x !== o);
  return ids.length >= HERO_LIMIT ? null : [...ids, o];
}

/** Makes the card a hero of the scope, or stops it being one. False when the scope already has HERO_LIMIT heroes. */
export function toggleHero(oracleId: string, s: HeroScope): boolean {
  const before = heroesOf(s);
  const ids = toggledList(before, oracleId);
  if (!ids) return false;
  const key = scopeKey(s);
  const heroes = { ...state.heroes };
  if (ids.length) heroes[key] = ids;
  else delete heroes[key];
  set({ heroes });
  saveCache();
  capture(ids.length > before.length ? "hero_added" : "hero_removed", { scope: s.kind, count: ids.length });
  const user = state.userId;
  if (!user || demo) return true;
  void supabase.rpc("library_heroes_set", {
    p_scope: s.kind, p_target_id: s.kind === "collection" ? null : s.id, p_oracle_ids: ids,
  }).then(({ data, error }) => {
    if (state.userId !== user) return;
    if (error) {
      set({ error: error.message });
      void refreshHeroes();
      return;
    }
    const r = data as Row;
    const next = { ...state.heroes };
    if (r.oracle_ids.length) next[rowKey(r)] = r.oracle_ids.map((x) => x.toLowerCase());
    else delete next[rowKey(r)];
    set({ heroes: next, error: null });
    saveCache();
  });
  return true;
}

/** Starts the store for the account (refetching each time the tab comes back) and follows it. The dev demo seeds
 *  its heroes with `startDemoHeroes` instead. */
export function useHeroes(userId: string | null, isDemo = false): HeroesState {
  useEffect(() => {
    if (!userId || isDemo) return;
    startHeroes(userId);
    const onVisible = () => { if (document.visibilityState === "visible") void refreshHeroes(); };
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [userId, isDemo]);
  const snap = useSyncExternalStore((l) => {
    listeners.add(l);
    return () => listeners.delete(l);
  }, () => state);
  return snap.userId === userId ? snap : empty;
}

/** The printings to show for these heroes: the one the place holds (`held`, card ids, most copies first), else the
 *  card's cover. Hero order is kept; heroes the card data doesn't know are left out. */
export function heroPrintings(c: Catalog, heroes: string[], held: string[]): number[] {
  if (!heroes.length) return [];
  const want = new Map<number, string>();
  for (const h of heroes) {
    const oi = c.oId.indexOf(h);
    if (oi >= 0) want.set(oi, h);
  }
  const byOracle = new Map<number, number>();
  for (const id of held) {
    const p = c.printingIndex.get(id);
    if (p == null) continue;
    const oi = c.pOracle[p];
    if (want.has(oi) && !byOracle.has(oi)) byOracle.set(oi, p);
  }
  return [...want.keys()].map((oi) => byOracle.get(oi) ?? coverPrinting(c, oi));
}
