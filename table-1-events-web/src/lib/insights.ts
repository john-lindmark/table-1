import { useEffect, useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";
import { delta, pct, shortDay } from "./insightCharts";

/**
 * Insights (contract/insights-2026-10-24.md): the published pack index, the packs (fetched once per version) and
 * what the viewer picked, kept in this browser. Archetype and card pages come from their RPCs.
 */

export type Tier = "big" | "all";
export const WINDOWS = [7, 14, 30, 90] as const;
export const FORMATS = [
  { key: "standard", label: "Standard" }, { key: "pioneer", label: "Pioneer" },
  { key: "modern", label: "Modern" }, { key: "pauper", label: "Pauper" },
  { key: "canlander", label: "Canlander" },
] as const;

/** "A", "A and B", "A, B and C". */
export const andList = (xs: string[]) => (xs.length < 2 ? xs.join("") : `${xs.slice(0, -1).join(", ")} and ${xs[xs.length - 1]}`);

const SOURCE_NAMES: [string, string, string][] = [
  ["mtgo", "Magic Online", "https://www.mtgo.com/decklists"], ["topdeck", "TopDeck.gg", "https://topdeck.gg"], ["melee", "Melee", "https://melee.gg"],
];

/** The credit under a constructed brief, from the pack's sources in a fixed order: TopDeck.gg asks for a visible
 *  credit and link whenever its data is shown, so the link is TopDeck's when it's a source; Canadian Highlander comes
 *  from TopDeck alone. Melee results come through the MTG_decklistcache. */
export function sourcesCredit(sources: string[]): { label: string; url: string } {
  const named = SOURCE_NAMES.filter(([k]) => sources.includes(k));
  if (!named.length) return { label: "Results from Magic Online", url: SOURCE_NAMES[0][2] };
  const link = named.find(([k]) => k === "topdeck") ?? named[0];
  return { label: `Results from ${andList(named.map(([, n]) => n))}`, url: link[2] };
}

export interface IndexEntry { kind: "constructed" | "limited"; key: string; name: string; version: string; url: string; bytes: number; through: string | null }
export interface Archetype { id: number; name: string; family: string; colors: string }
export interface Change { id: number; on: string; kind: string; cards: string[]; set_code: string | null; note: string | null; url: string | null }
/** `wr`, `t8r`, `won` and the window's `won_of` are missing from packs built before 2026-10-28. */
export interface ShareRow { a: number; share: number; prev: number | null; decks: number; top8: number; conv: number | null; wr?: number | null; t8r?: number | null; won?: number }
export interface CardRow { c: string; n: string; rate: number; prev: number | null; copies: number | null }
export interface Window {
  decks: number; weighted: number; events: number; thin: boolean; brief: string | null; won_of?: number;
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
  /** Other (archetype 0) only: its decks by colours, each with its most-played cards and its example list in `finishes`. */
  groups?: { colors: string; decks: number; share: number; cards: string[]; example: number | null }[];
  brief: string | null;
}
export type Finish = ArchetypePage["finishes"][number];
const TIER_ORDER = ["major", "large", "regular", "small"];
/** The deck page's example list: from the biggest event (major, large, regular, small), the best finish there, then
 *  the newest; only whole lists (40+ main deck cards). -1 when there's none. */
export function exampleFinish(finishes: Finish[]): number {
  let best = -1;
  const tier = (f: Finish) => { const i = TIER_ORDER.indexOf(f.tier); return i < 0 ? TIER_ORDER.length : i; };
  const rank = (f: Finish) => f.rank ?? Number.MAX_SAFE_INTEGER;
  finishes.forEach((f, i) => {
    if (f.main.reduce((n, [, q]) => n + q, 0) < 40) return;
    const b = finishes[best];
    if (!b || tier(f) < tier(b) || (tier(f) === tier(b) && (rank(f) < rank(b) || (rank(f) === rank(b) && f.on > b.on)))) best = i;
  });
  return best;
}
/** "1st", "2nd", "3rd", "4th"…: a finish's place. */
export const place = (rank: number) => {
  const t = rank % 100, u = rank % 10;
  return `${rank}${t >= 11 && t <= 13 ? "th" : u === 1 ? "st" : u === 2 ? "nd" : u === 3 ? "rd" : "th"}`;
};

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
    case "points": return `Points: ${c.note ?? cards}`;
    default: return `Released: ${c.note ?? c.set_code?.toUpperCase() ?? "a new set"}`;
  }
};
/** Changes with a before/after study: bans and their kin, and Canadian Highlander's points changes. */
export const isBan = (c: Change) => ["ban", "unban", "restrict", "unrestrict", "points"].includes(c.kind);
/** The studies' heading: a points format's changes are points changes, not bans. */
export const bansTitle = (kinds: string[]) => (kinds.length > 0 && kinds.every((k) => k === "points") ? "Points changes" : "Bans and unbans");
/** The format page's parts behind a row each (contract/insights-2026-10-24.md § Format page): key, title and a one-line
 *  summary for the picked tier and window; parts with nothing to show are left out. Shared cases in
 *  testdata/insights/parts.json. */
export type PartKey = "meta" | "cards" | "new_set" | "changes" | "events";
export interface Part { key: PartKey; title: string; detail: string }
export function formatParts(p: ConstructedPack, tier: Tier, days: number): Part[] {
  const view = p.tiers[tier];
  const w = view?.windows[String(days)];
  const out: Part[] = [];
  if (w && w.share.length) {
    const named = w.share.filter((s) => s.a !== 0);
    const lead = named[0];
    out.push({ key: "meta", title: "Meta now", detail: [lead ? `${archetypeName(p, lead.a)} ${pct(lead.share)}` : null, `${named.length} archetypes`].filter(Boolean).join(" · ") });
  }
  if (w) {
    const up = w.cards.main.up[0];
    out.push({ key: "cards", title: "Cards rising and falling",
               detail: up ? `Rising most: ${up.n} ▲ ${delta(up.rate - (up.prev ?? 0)).slice(1)}` : "No card moved much in this window" });
  }
  const ns = view?.new_set;
  if (ns && ns.cards.length) out.push({ key: "new_set", title: `New set · ${ns.name}`, detail: `${ns.cards.length} cards played · ${ns.cards[0].n} in ${pct(ns.cards[0].rate)}` });
  const studied = p.bans.map((b) => p.changes.find((c) => c.id === b.change)).filter((c): c is Change => !!c);
  if (studied.length) {
    const latest = studied.reduce((a, c) => (c.on > a.on ? c : a));
    out.push({ key: "changes", title: bansTitle(studied.map((c) => c.kind)),
               detail: `${changeWords(latest)} · ${shortDay(latest.on)}${studied.length > 1 ? ` · ${studied.length - 1} more` : ""}` });
  }
  const events = p.events.filter((e) => tier === "all" || e.tier === "major" || e.tier === "large");
  if (events.length) {
    const latest = events.reduce((a, e) => (e.on > a.on ? e : a));
    out.push({ key: "events", title: tier === "big" ? "Big events" : "Events", detail: `${events.length} ${events.length === 1 ? "event" : "events"} · latest ${latest.name}` });
  }
  return out;
}
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

/* ── picks, kept on the account with a copy in this browser ───────────── */

export interface Picks {
  format: string; tier: Tier | null; days: number; set: string | null; event: string; group: "all" | "top";
  /** Formats and sets kept out of the pickers on this device (Edit). */
  hiddenFormats: string[]; hiddenSets: string[];
}
const PICKS_KEY = "t1.insights.picks";
function readPicks(): Picks {
  const d: Picks = { format: "modern", tier: null, days: 30, set: null, event: "PremierDraft", group: "all", hiddenFormats: [], hiddenSets: [] };
  try { return { ...d, ...JSON.parse(localStorage.getItem(PICKS_KEY) ?? "{}") }; } catch { return d; }
}

/**
 * The picks as user_settings.insights holds them (contract/insights-2026-10-24.md § What the viewer picked): snake
 * case, every key optional. `section` is the apps' (the web keeps it in the address), kept as the account has it.
 */
export type WirePicks = Record<string, unknown>;
const str = (v: unknown) => (typeof v === "string" ? v : undefined);
const strs = (v: unknown) => (Array.isArray(v) && v.every((x) => typeof x === "string") ? (v as string[]) : undefined);

/** What a device takes from the stored object; wrong types and unknown keys are ignored. */
export function readWirePicks(o: WirePicks): WirePicks {
  const out: WirePicks = {};
  for (const k of ["section", "format", "tier", "set", "event", "group"]) { const v = str(o[k]); if (v !== undefined) out[k] = v; }
  if (typeof o.days === "number" && Number.isInteger(o.days)) out.days = o.days;
  for (const k of ["hidden_formats", "hidden_sets"]) { const v = strs(o[k]); if (v !== undefined) out[k] = v; }
  return out;
}

/** The object to store: these picks over what the account holds (keys from newer clients stay). */
export function writeWirePicks(picks: WirePicks, held: WirePicks | null): WirePicks {
  const mine = Object.fromEntries(Object.entries(readWirePicks(picks)).filter(([, v]) => v !== null));
  return { ...(held ?? {}), ...mine };
}

const toWire = (p: Picks): WirePicks => ({ format: p.format, tier: p.tier, days: p.days, set: p.set, event: p.event, group: p.group,
  hidden_formats: p.hiddenFormats, hidden_sets: p.hiddenSets });

function fromWire(o: WirePicks): Partial<Picks> {
  const w = readWirePicks(o);
  const out: Partial<Picks> = {};
  if (w.format) out.format = w.format as string;
  if (w.tier === "big" || w.tier === "all") out.tier = w.tier;
  if (typeof w.days === "number" && [7, 14, 30, 90].includes(w.days)) out.days = w.days;
  if (w.set) out.set = w.set as string;
  if (w.event) out.event = w.event as string;
  if (w.group === "all" || w.group === "top") out.group = w.group;
  if (w.hidden_formats) out.hiddenFormats = w.hidden_formats as string[];
  if (w.hidden_sets) out.hiddenSets = w.hidden_sets as string[];
  return out;
}

let heldPicks: WirePicks | null = null;
let pushTimer: ReturnType<typeof setTimeout> | null = null;

/** Written a moment after the last change, when signed in. */
function pushPicks() {
  if (state.demo) return;
  if (pushTimer) clearTimeout(pushTimer);
  pushTimer = setTimeout(async () => {
    const { data } = await supabase.auth.getSession();
    const uid = data.session?.user.id;
    if (!uid) return;
    const next = writeWirePicks(toWire(state.picks), heldPicks);
    const { error } = await supabase.from("user_settings")
      .upsert({ user_id: uid, insights: next, updated_at: new Date().toISOString() }, { onConflict: "user_id" });
    if (!error) heldPicks = next;
  }, 800);
}

/** The account's picks over this browser's; an account with none yet takes this browser's. */
async function pullPicks() {
  const { data } = await supabase.auth.getSession();
  const uid = data.session?.user.id;
  if (!uid) return;
  const { data: row, error } = await supabase.from("user_settings").select("insights").eq("user_id", uid).maybeSingle();
  if (error) return;
  heldPicks = (row?.insights as WirePicks | undefined) ?? {};
  if (!Object.keys(heldPicks).length) { pushPicks(); return; }
  const picks = { ...state.picks, ...fromWire(heldPicks) };
  try { localStorage.setItem(PICKS_KEY, JSON.stringify(picks)); } catch { /* private window */ }
  set({ picks });
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

/** The options a picker shows: every one not hidden, in order (all of them if every one is hidden). */
export function visibleKeys(all: string[], hidden: string[]): string[] {
  const shown = all.filter((k) => !hidden.includes(k));
  return shown.length ? shown : all;
}
/** Whether an option may be hidden: at least one other has to stay shown. */
export const canHide = (all: string[], hidden: string[], key: string) => all.some((k) => k !== key && !hidden.includes(k));
/** Shows or hides one option of a picker (Insights → Edit). */
export function setHidden(which: "hiddenFormats" | "hiddenSets", key: string, hide: boolean) {
  const now = state.picks[which].filter((k) => k !== key).concat(hide ? [key] : []);
  pick({ [which]: now } as Partial<Picks>);
  capture("insights_picker_edited", { picker: which === "hiddenFormats" ? "formats" : "sets", hidden: now.length });
}

export function pick(patch: Partial<Picks>) {
  const picks = { ...state.picks, ...patch };
  try { localStorage.setItem(PICKS_KEY, JSON.stringify(picks)); } catch { /* private window */ }
  set({ picks });
  pushPicks();
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
    await pullPicks().catch(() => { /* keep this browser's picks */ });
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
