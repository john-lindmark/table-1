import { useEffect, useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";

/**
 * Insights (contract/insights-2026-10-24.md): the published pack index, the packs (fetched once per version) and
 * what the viewer picked, kept in this browser. Archetype and card pages come from their RPCs.
 */

export type Tier = "big" | "all";
export const WINDOWS = [7, 14, 30, 90] as const;
export const FORMATS = [
  { key: "standard", label: "Standard" }, { key: "pioneer", label: "Pioneer" },
  { key: "modern", label: "Modern" }, { key: "pauper", label: "Pauper" },
] as const;

export interface IndexEntry { kind: "constructed" | "limited"; key: string; name: string; version: string; url: string; bytes: number; through: string | null }
export interface Archetype { id: number; name: string; family: string; colors: string }
export interface Change { id: number; on: string; kind: string; cards: string[]; set_code: string | null; note: string | null; url: string | null }
export interface ShareRow { a: number; share: number; prev: number | null; decks: number; top8: number; conv: number | null }
export interface CardRow { c: string; n: string; rate: number; prev: number | null; copies: number | null }
export interface Window {
  decks: number; weighted: number; events: number; thin: boolean; brief: string | null;
  share: ShareRow[];
  cards: Record<"main" | "side", { up: CardRow[]; down: CardRow[] }>;
}
export interface Series { from: string; days: number; lines: { a: number; v: (number | null)[] }[]; other: (number | null)[] }
export interface NewSet { set_code: string; name: string; released: string; cards: { c: string; n: string; rate: number; copies: number | null; in: number[] | null }[] }
export interface View { windows: Record<string, Window>; series: Series; new_set: NewSet | null }
export interface BanStudy {
  change: number; on: string;
  before: { a: number; share: number }[];
  after: Record<string, { a: number; share: number }[]>;
  losers: { a: number; before: number; after: number }[];
  gainers: { a: number; before: number; after: number }[];
  replacements: { c: string; n: string; before: number; after: number; in: number }[];
  settled_days: number | null; brief: string | null;
}
export interface Matchups { archetypes: number[]; cells: [number, number, number, number, number][] }
export interface EventRow { name: string; on: string; players: number | null; tier: string; source: string; url: string | null; top8: number[] | null; winner: number | null }
export interface ConstructedPack {
  format: string; name: string; through: string; sources: string[]; default_tier: Tier;
  archetypes: Archetype[]; changes: Change[]; events: EventRow[];
  tiers: Record<Tier, View>; bans: BanStudy[]; matchups: Matchups;
}

export interface ArchetypePage {
  archetype: Archetype; decks: number;
  series: { from: string; weeks: number; v: (number | null)[] };
  record: { wins: number; losses: number; draws: number; basis: "topdeck" | "mtgo_top32" } | null;
  conv: number | null;
  core: CardRow[]; flex: CardRow[]; side: CardRow[];
  matchups: { vs: number; wins: number; losses: number; draws: number }[];
  finishes: { event: string; on: string; players: number | null; tier: string; rank: number | null; url: string | null; main: [string, number][]; side: [string, number][] }[];
  brief: string | null;
}
export interface CardPage {
  c: string; n: string | null;
  series: { from: string; weeks: number; main: (number | null)[]; side: (number | null)[] };
  copies: number | null; by_archetype: { a: number; rate: number; copies: number | null }[]; first_seen: string | null;
}

export interface LCard {
  c: string | null; n: string; r: string | null; col: string | null;
  gih: number | null; gih_n: number; oh: number | null; gd: number | null; gns: number | null; iwd: number | null;
  ata: number | null; deck: number; week_gih: (number | null)[] | null; pair_gih: Record<string, number> | null;
}
export interface LPair { p: string; games: number; wr: number; share: number; splash: number; play_wr: number | null; draw_wr: number | null; week_wr: (number | null)[]; week_share: (number | null)[] }
/** One exact colour combination: main colours (WUBRG order, as 17Lands writes them) and the splash ('' for none). */
export interface LColors { m: string; s: string; games: number; wr: number; share: number }
export interface LView {
  games: number; wr: number; weeks: number; brief?: string | null; pairs: LPair[]; cards: LCard[]; colors?: LColors[];
  facts: { play_wr: number | null; draw_wr: number | null; mull_rate: number | null; mull_wr: number | null; keep7_wr: number | null; mull_play: number | null; turns: number | null };
}
export interface LimitedPack {
  set_code: string; name: string | null; released: string | null; credit: { name: string; url: string };
  events: Record<string, { updated: string; groups: { all?: LView; top?: LView } }>;
}

export const EVENT_ORDER = ["PremierDraft", "TradDraft", "PickTwoDraft", "Sealed", "TradSealed"];
export const EVENT_LABELS: Record<string, string> = { PremierDraft: "Premier", TradDraft: "Traditional", PickTwoDraft: "Pick Two", Sealed: "Sealed", TradSealed: "Trad Sealed" };
export const PAIR_NAMES: Record<string, string> = {
  WU: "Azorius", WB: "Orzhov", WR: "Boros", WG: "Selesnya", UB: "Dimir", UR: "Izzet", UG: "Simic", BR: "Rakdos", BG: "Golgari", RG: "Gruul",
  W: "Mono-White", U: "Mono-Blue", B: "Mono-Black", R: "Mono-Red", G: "Mono-Green", "3C": "Three or more", C: "Colourless",
};

const SHARDS: Record<string, string> = { WUB: "Esper", UBR: "Grixis", BRG: "Jund", WRG: "Naya", WUG: "Bant", WBG: "Abzan", WUR: "Jeskai", UBG: "Sultai", WBR: "Mardu", URG: "Temur" };
/** "Dimir UB + r", "Esper WUB", "Four-colour WUBR": a deck's colours as 17Lands' deck colour table names them. */
export function colorsName(m: string, s: string): string {
  const base = m.length <= 2 ? (PAIR_NAMES[m] ?? m) : m.length === 3 ? (SHARDS[m] ?? "Three-colour") : m.length === 4 ? "Four-colour" : "Five-colour";
  return `${base} ${m}${s ? ` + ${s.toLowerCase()}` : ""}`;
}

export const archetypeName = (p: ConstructedPack | undefined, id: number) => p?.archetypes.find((a) => a.id === id)?.name ?? "Other";
export const changeWords = (c: Change) => {
  const cards = c.cards.length > 3 ? `${c.cards.slice(0, 3).join(", ")} and others` : c.cards.join(" and ");
  switch (c.kind) {
    case "ban": return `Banned: ${cards}`;
    case "unban": return `Unbanned: ${cards}`;
    case "restrict": return `Restricted: ${cards}`;
    case "unrestrict": return `Unrestricted: ${cards}`;
    case "rotation": return "Rotation";
    default: return `Released: ${c.note ?? c.set_code?.toUpperCase() ?? "a new set"}`;
  }
};
export const isBan = (c: Change) => ["ban", "unban", "restrict", "unrestrict"].includes(c.kind);
/** The longest "after" window of a ban study that has ended (60 → 30 → 14 days). */
export const afterWindow = (b: BanStudy) => {
  for (const d of [60, 30, 14]) if (b.after[String(d)]) return { days: d, shares: b.after[String(d)] };
  return null;
};
/** A matchup cell read from the row archetype's side. */
export function matchup(m: Matchups, a: number, b: number): { wins: number; losses: number; draws: number } | null {
  const ab = m.cells.find((c) => c[0] === a && c[1] === b);
  if (ab) return { wins: ab[2], losses: ab[3], draws: ab[4] };
  const ba = m.cells.find((c) => c[0] === b && c[1] === a);
  return ba ? { wins: ba[3], losses: ba[2], draws: ba[4] } : null;
}

/* ── picks, kept in this browser ──────────────────────────────────────── */

export interface Picks { format: string; tier: Tier | null; days: number; set: string | null; event: string; group: "all" | "top" }
const PICKS_KEY = "t1.insights.picks";
function readPicks(): Picks {
  const d: Picks = { format: "modern", tier: null, days: 30, set: null, event: "PremierDraft", group: "all" };
  try { return { ...d, ...JSON.parse(localStorage.getItem(PICKS_KEY) ?? "{}") }; } catch { return d; }
}

/* ── the store ────────────────────────────────────────────────────────── */

interface State {
  index: IndexEntry[] | null;
  constructed: Record<string, ConstructedPack>;
  limited: Record<string, LimitedPack>;
  error: string | null;
  picks: Picks;
  demo: boolean;
}
let state: State = { index: null, constructed: {}, limited: {}, error: null, picks: readPicks(), demo: false };
const listeners = new Set<() => void>();
const set = (patch: Partial<State>) => { state = { ...state, ...patch }; listeners.forEach((f) => f()); };
const subscribe = (f: () => void) => { listeners.add(f); return () => listeners.delete(f); };

export function useInsights(): State {
  return useSyncExternalStore(subscribe, () => state, () => state);
}

export function pick(patch: Partial<Picks>) {
  const picks = { ...state.picks, ...patch };
  try { localStorage.setItem(PICKS_KEY, JSON.stringify(picks)); } catch { /* private window */ }
  set({ picks });
  if (patch.format) capture("insights_format_changed", { format: patch.format });
  if (patch.tier) capture("insights_tier_changed", { tier: patch.tier });
  if (patch.days) capture("insights_window_changed", { days: patch.days });
  if (patch.set || patch.event) capture("insights_set_changed", { set: picks.set ?? "", event: picks.event });
}

let loading: Promise<void> | null = null;
let loadedAt = 0;
const fetching = new Map<string, Promise<void>>();

async function fetchPack(e: IndexEntry) {
  const key = `${e.kind}:${e.key}:${e.version}`;
  if (fetching.has(key)) return fetching.get(key);
  const p = (async () => {
    // The version in the url keeps the browser's cache honest across rebuilds.
    const res = await fetch(`${e.url}?v=${encodeURIComponent(e.version)}`);
    if (!res.ok) throw new Error(`pack ${e.key}: ${res.status}`);
    const body = await res.json();
    if (e.kind === "constructed") set({ constructed: { ...state.constructed, [e.key]: body } });
    else set({ limited: { ...state.limited, [e.key]: body } });
  })().catch((err) => set({ error: `Insights couldn't load: ${String(err?.message ?? err)}` }));
  fetching.set(key, p);
  return p;
}

/** The index, then the packs (the format on screen first). */
export function loadInsights(force = false): Promise<void> {
  if (state.demo) return Promise.resolve();
  if (!force && loading && Date.now() - loadedAt < 600_000) return loading;
  loadedAt = Date.now();
  loading = (async () => {
    const { data, error } = await supabase.rpc("insights_index");
    if (error) { set({ error: `Insights couldn't load: ${error.message}` }); return; }
    const index = (data ?? []) as IndexEntry[];
    set({ index, error: null });
    const first = index.find((e) => e.kind === "constructed" && e.key === state.picks.format);
    if (first) await fetchPack(first);
    await Promise.all(index.filter((e) => e !== first).map(fetchPack));
  })();
  return loading;
}

export function useLoadInsights() {
  useEffect(() => { void loadInsights(); }, []);
}

export async function archetypePage(format: string, id: number, tier: Tier, days: number): Promise<ArchetypePage> {
  if (state.demo) return demoPage(`arch:${format}:${id}`, "arch:any") as Promise<ArchetypePage>;
  const { data, error } = await supabase.rpc("meta_archetype", { p_format: format, p_archetype: id, p_tier: tier, p_days: days });
  if (error) throw new Error(error.message);
  return data as ArchetypePage;
}

export async function cardPage(format: string, oracleId: string, tier: Tier): Promise<CardPage> {
  if (state.demo) return demoPage(`card:${format}:${oracleId}`, "card:any") as Promise<CardPage>;
  const { data, error } = await supabase.rpc("meta_card", { p_format: format, p_oracle_id: oracleId, p_tier: tier });
  if (error) throw new Error(error.message);
  return data as CardPage;
}

/* ── demo (dev only, ?demo) ───────────────────────────────────────────── */

let pages: Record<string, unknown> = {};
async function demoPage(key: string, fallback: string) {
  const p = pages[key] ?? pages[fallback];
  if (!p) throw new Error("No demo page");
  return p;
}

/** Loads the packs in testdata/insights (built from real MTGO pages and a 17Lands slice). */
export async function loadInsightsDemo() {
  if (!import.meta.env.DEV) return;
  const files = import.meta.glob("../../../testdata/insights/*.json");
  const constructed: Record<string, ConstructedPack> = {};
  const limited: Record<string, LimitedPack> = {};
  const index: IndexEntry[] = [];
  for (const [path, load] of Object.entries(files)) {
    const name = path.split("/").pop()!.replace(/\.json$/, "");
    const body = ((await load()) as { default: unknown }).default;
    if (name.startsWith("constructed-")) {
      const k = name.slice("constructed-".length);
      constructed[k] = body as ConstructedPack;
      index.push({ kind: "constructed", key: k, name: k, version: "demo", url: "", bytes: 0, through: null });
    } else if (name.startsWith("limited-")) {
      const k = name.slice("limited-".length);
      limited[k] = body as LimitedPack;
      index.push({ kind: "limited", key: k, name: k, version: "demo", url: "", bytes: 0, through: null });
    } else if (name === "pages") pages = body as Record<string, unknown>;
  }
  set({ demo: true, index, constructed, limited, error: null });
}
