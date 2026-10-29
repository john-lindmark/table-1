// Spice (contract/spice-2026-10-28.md): how much of a deck or cube its peers rarely or never play. The server works
// it out (list_spice); this decodes the answer and words it exactly as testdata/spice/cases.json says. Same as iOS
// Spice.swift.
import { useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";
import { isLibraryDemo } from "./libraryDemo";
import { andList } from "./insights";

export interface SpiceBasis {
  kind: "archetype" | "closest" | "format" | "colors" | "cubes";
  format: string | null;
  archetype: number | null;
  name: string | null;
  lists: number;
  days: number | null;
  sources: string[];
  close: boolean | null;
  cubes: { name: string; overlap: number }[] | null;
}
export interface SpiceCard { c: string; n: string; section: "main" | "side"; copies: number; rate: number; seen: number; of: number }
export interface SpiceMissing { c: string; n: string; rate: number; seen: number; of: number }
export interface SpiceResult {
  kind: "deck" | "cube";
  score: number | null;
  word: "stock" | "tuned" | "spicy" | "brew" | null;
  reason: "empty" | "no_data" | "no_cubes" | null;
  basis: SpiceBasis | null;
  cards: SpiceCard[];
  stock_missing: SpiceMissing[];
}

export const SPICE_WORDS: Record<string, string> = { stock: "Stock", tuned: "Tuned", spicy: "Spicy", brew: "Brew" };
const FORMATS: Record<string, string> = {
  standard: "Standard", pioneer: "Pioneer", modern: "Modern", pauper: "Pauper", canlander: "Canadian Highlander", legacy: "Legacy",
};
const SOURCES: Record<string, string> = { mtgo: "MTGO", topdeck: "TopDeck.gg", melee: "Melee", cubecobra: "Cube Cobra" };
const REASONS: Record<string, string> = {
  empty: "Add cards to see how spicy this is",
  no_data: "No tournament lists for this format yet",
  no_cubes: "No cubes to compare with yet",
};

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** The end of the Stats row: "Spice 34". */
export const spiceSummary = (r: SpiceResult) => (r.score == null ? null : `Spice ${r.score}`);

/** "34 · Spicy". */
export const spiceHeadline = (r: SpiceResult) => (r.score == null || !r.word ? null : `${r.score} · ${SPICE_WORDS[r.word] ?? r.word}`);

export const spiceReason = (r: SpiceResult) => (r.score == null ? REASONS[r.reason ?? ""] ?? REASONS.no_data : null);

/** What the deck or cube was compared with. */
export function spiceBasis(r: SpiceResult): string | null {
  const b = r.basis;
  if (r.score == null || !b) return null;
  const when = b.days == null ? "" : b.days === 365 ? "last year" : `last ${b.days} days`;
  const src = andList(b.sources.map((s) => SOURCES[s] ?? s));
  const fmt = b.format ? FORMATS[b.format] ?? b.format : "";
  const name = b.name ?? "";
  switch (b.kind) {
    case "archetype": return `${plural(b.lists, `${name} list`, `${name} lists`)} · ${when} · ${src}`;
    case "closest": return `Closest archetype: ${name} · ${plural(b.lists, "list", "lists")} · ${when} · ${src}`;
    case "format": return `Nothing close in ${fmt} · ${plural(b.lists, "list", "lists")} · ${when} · ${src}`;
    case "colors": return `${fmt} lists that can play each card · ${plural(b.lists, "list", "lists")} · ${when} · ${src}`;
    default: return `${b.close ? `The ${b.lists} cubes most like yours` : "No cubes much like this one"} · ${src}`;
  }
}

/** The nearest cubes: "LSVCube · 62% alike" (whole percent from the overlap's basis points, half up). */
export const spiceCubes = (r: SpiceResult) =>
  r.score == null ? [] : (r.basis?.cubes ?? []).map((k) => `${k.name} · ${Math.floor((Math.round(k.overlap * 10000) + 50) / 100)}% alike`);

export const spiceCardTitle = (c: SpiceCard) => `${c.copies} ${c.n}`;

/** "in 2 of 412 lists", "never seen", "in 3 of 40 lists that can play it", "in 3 of 20 similar cubes". */
export function spiceCardDetail(c: SpiceCard, r: SpiceResult): string {
  const kind = r.basis?.kind;
  const noun = kind === "colors" ? "lists that can play it" : kind === "cubes" ? "similar cubes" : "lists";
  const seen = c.seen === 0 ? (kind === "cubes" ? "in no similar cube" : "never seen") : `in ${c.seen} of ${c.of} ${noun}`;
  return seen + (c.section === "side" ? " · sideboard" : "");
}

export const spiceCardLine = (c: SpiceCard, r: SpiceResult) => `${spiceCardTitle(c)} · ${spiceCardDetail(c, r)}`;

export const spiceMissingDetail = (m: SpiceMissing, r: SpiceResult) =>
  `in ${m.seen} of ${m.of} ${r.basis?.kind === "cubes" ? "similar cubes" : "lists"}`;

export const spiceMissingLine = (m: SpiceMissing, r: SpiceResult) => `${m.n} · ${spiceMissingDetail(m, r)}`;

/* ── the store ───────────────────────────────────────────────────────── */

/** A card the demo makes a result from. */
export interface SpiceDemoCard { oracleId: string; name: string; qty: number; board: string; basic: boolean }

const results = new Map<string, SpiceResult>();
const failed = new Set<string>();
const keys = new Map<string, string>();
const viewedOpens = new Set<string>();
let version = 0;
const subs = new Set<() => void>();
const bump = () => {
  version++;
  for (const s of subs) s();
};

export const spiceOf = (listId: string) => results.get(listId) ?? null;
export const spiceFailed = (listId: string) => failed.has(listId);

/** Asks the server once per `key` (the list's cards: a change asks again); `token` when opened from a link. */
export async function loadSpice(listId: string, key: string, opts: { token?: string | null; kind: "deck" | "cube"; format: string; demo?: SpiceDemoCard[]; name?: string }) {
  if (keys.get(listId) === key && results.has(listId)) return;
  keys.set(listId, key);
  if (isLibraryDemo()) {
    if (opts.demo) {
      results.set(listId, demoSpice(opts.demo, opts.kind, opts.format, opts.name));
      bump();
    }
    return;
  }
  const { data, error } = await supabase.rpc("list_spice", opts.token ? { p_list_id: listId, p_token: opts.token } : { p_list_id: listId });
  if (error) {
    keys.delete(listId);
    failed.add(listId);
  } else {
    results.set(listId, data as SpiceResult);
    failed.delete(listId);
  }
  bump();
}

/** spice_viewed, once per list per screen open (the section passes its own open id). */
export function spiceViewed(r: SpiceResult, listId: string, open: string, format: string) {
  const k = `${listId}|${open}`;
  if (viewedOpens.has(k)) return;
  viewedOpens.add(k);
  capture("spice_viewed", { kind: r.kind, format, basis: r.basis?.kind ?? r.reason ?? "none", word: r.word ?? "none" });
}

/** Re-renders when a list's spice arrives. */
export function useSpice(): number {
  return useSyncExternalStore((cb) => {
    subs.add(cb);
    return () => subs.delete(cb);
  }, () => version);
}

/** Demo: a made-up comparison from the list's own cards, so every part of the section shows. */
export function demoSpice(cards: SpiceDemoCard[], kind: "deck" | "cube", format: string, name = "Similar decks"): SpiceResult {
  const isCube = kind === "cube";
  const main = cards.filter((c) => !c.basic && (c.board === "main" || c.board === "commander"));
  const side = isCube ? [] : cards.filter((c) => !c.basic && c.board === "side");
  if (!main.length) return { kind, score: null, word: null, reason: "empty", basis: null, cards: [], stock_missing: [] };
  const n = isCube ? 20 : 412;
  const seen = (c: SpiceDemoCard) => {
    const h = [...c.oracleId].reduce((a, ch) => (a * 31 + ch.charCodeAt(0)) & 0xffff, 0);
    return h % 6 === 0 ? h % 7 : Math.floor(n / 3) + (h % (n - Math.floor(n / 3)));
  };
  let num = 0, total = 0;
  for (const c of main) { num += c.qty * Math.max(0, n - 4 * seen(c)); total += c.qty; }
  const score = Math.floor((200 * num + n * total) / (2 * n * total));
  const word = score < 10 ? "stock" : score < 25 ? "tuned" : score < 50 ? "spicy" : "brew";
  const spicy: SpiceCard[] = [...main.map((c) => [c, "main"] as const), ...side.map((c) => [c, "side"] as const)]
    .filter(([c]) => 4 * seen(c) < n)
    .sort(([a, sa], [b, sb]) => (sa === sb ? 0 : sa === "main" ? -1 : 1) || seen(a) - seen(b) || b.qty - a.qty || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
    .map(([c, section]) => ({ c: c.oracleId, n: c.name, section, copies: c.qty, rate: seen(c) / n, seen: seen(c), of: n }));
  const missing: SpiceMissing[] = isCube ? [] : ["Thoughtseize", "Fable of the Mirror-Breaker", "Consider"].map((name, i) =>
    ({ c: `demo-missing-${i}`, n: name, rate: (n - 60 * (i + 1)) / n, seen: n - 60 * (i + 1), of: n }));
  const basis: SpiceBasis = isCube
    ? { kind: "cubes", format: null, archetype: null, name: null, lists: n, days: null, sources: ["cubecobra"], close: true,
        cubes: [{ name: "MTGO Vintage Cube", overlap: 0.62 }, { name: "LSVCube", overlap: 0.58 }, { name: "AlphaFrog Vintage Cube", overlap: 0.51 }] }
    : { kind: "archetype", format, archetype: 1, name, lists: n, days: 90, sources: ["mtgo", "topdeck"], close: null, cubes: null };
  return { kind, score, word, reason: null, basis, cards: spicy, stock_missing: missing };
}
