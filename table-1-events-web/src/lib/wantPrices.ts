// Want prices (contract/want-prices-2026-10-26.md): each want's price now, a week back and its 30-day average
// (wants_prices), the trend shown on Wanted rows, and the account's price alerts switch (want_alerts_set). Rules
// shared with iOS and Android in testdata/want-prices/cases.json.
import { useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";
import { isLibraryDemo } from "./libraryDemo";
import { wantKey, type Want } from "./binders";

export interface WantPrice {
  oracle_id: string;
  card_id: string | null;
  finish: string | null;
  now: number | null;
  now_card_id: string | null;
  now_finish: string | null;
  then: number | null;
  then_days: number | null;
  avg30: number | null;
}

export interface Trend { dir: "up" | "down" | "flat"; text: string }

/* ── rules ───────────────────────────────────────────────────────────── */

// Whole cents throughout, so a half percent rounds the same on every platform.
const cents = (v: number) => Math.round(v * 100);

export function money(v: number): string {
  const c = cents(v);
  return `$${Math.floor(c / 100)}.${String(c % 100).padStart(2, "0")}`;
}

const period = (days: number) => (days >= 7 ? "this week" : days === 1 ? "since yesterday" : `in ${days} days`);

/** Now against the oldest price of the last 7 days, `days` ago. Null without both prices. */
export function trend(now: number | null | undefined, then: number | null | undefined, days: number | null | undefined): Trend | null {
  if (now == null || then == null || days == null || days < 1) return null;
  const n = cents(now), t = cents(then);
  if (t <= 0) return null;
  const diff = n - t;
  const pct = Math.floor((Math.abs(diff) * 200 + t) / (2 * t));
  if (Math.abs(diff) < 5 || pct === 0) return { dir: "flat", text: `Flat ${period(days)}` };
  return diff > 0 ? { dir: "up", text: `▲ ${pct}% ${period(days)}` } : { dir: "down", text: `▼ ${pct}% ${period(days)}` };
}

/** A Wanted row's detail: which printing · Max $X · Now $Y (From for any printing). The trend has its own line. */
export function wantDetail(which: string, max: number | null, now: number | null, any: boolean): string {
  return [which || null, max != null ? `Max ${money(max)}` : null, now != null ? `${any ? "From" : "Now"} ${money(now)}` : null]
    .filter(Boolean).join(" · ");
}

/* ── store ───────────────────────────────────────────────────────────── */

let items = new Map<string, WantPrice>();
let alerts: boolean | null = null;
let error: string | null = null;
let version = 0;
let demoAlerts = true;
const subs = new Set<() => void>();
const bump = () => {
  version++;
  for (const s of subs) s();
};

export const wantPrice = (w: Want) => items.get(wantKey(w.oracleId, w.cardId, w.finish));
export const wantTrend = (w: Want) => {
  const p = wantPrice(w);
  return p ? trend(p.now, p.then, p.then_days) : null;
};

/** Loads your wants' prices. Demo: `demoPrice` (the session's price, or none) and a made-up week back. */
export async function loadWantPrices(wants: Want[], demoPrice?: (w: Want) => number | null) {
  if (isLibraryDemo()) {
    const next = new Map<string, WantPrice>();
    for (const w of wants) {
      const seed = [...(w.cardId ?? w.oracleId)].reduce((n, ch) => n + ch.charCodeAt(0), 0);
      const now = demoPrice?.(w) ?? (25 + (seed * 37) % 4000) / 100;
      const h = (seed % 41) - 20;
      next.set(wantKey(w.oracleId, w.cardId, w.finish), {
        oracle_id: w.oracleId, card_id: w.cardId, finish: w.finish, now, now_card_id: w.cardId, now_finish: w.finish ?? "nonfoil",
        then: Math.round((now * 100) / (100 + h) * 100) / 100, then_days: 7, avg30: now,
      });
    }
    items = next;
    alerts = demoAlerts;
    bump();
    return;
  }
  const { data, error: e } = await supabase.rpc("wants_prices");
  if (e) {
    error = e.message;
    bump();
    return;
  }
  const a = data as { alerts: boolean; items: WantPrice[] };
  items = new Map(a.items.map((p) => [wantKey(p.oracle_id, p.card_id, p.finish), p]));
  alerts = a.alerts;
  error = null;
  const trends = a.items.map((p) => trend(p.now, p.then, p.then_days)).filter((t): t is Trend => t != null);
  capture("want_prices_loaded", { wants: a.items.length, with_trend: trends.length,
                                  down: trends.filter((t) => t.dir === "down").length, up: trends.filter((t) => t.dir === "up").length });
  bump();
}

/** Price alerts on or off for the account. */
export async function setWantAlerts(on: boolean) {
  const was = alerts;
  alerts = on;
  bump();
  if (isLibraryDemo()) {
    demoAlerts = on;
    capture("want_alerts_changed", { on });
    return;
  }
  const { data, error: e } = await supabase.rpc("want_alerts_set", { p_on: on });
  if (e) {
    alerts = was;
    error = e.message;
  } else {
    alerts = (data as { alerts: boolean }).alerts;
    capture("want_alerts_changed", { on: alerts });
  }
  bump();
}

/** Re-renders when prices or the switch change. */
export function useWantPrices(): { version: number; alerts: boolean | null; error: string | null } {
  const v = useSyncExternalStore((cb) => {
    subs.add(cb);
    return () => subs.delete(cb);
  }, () => version);
  return { version: v, alerts, error };
}

/* ── Buy on TCGplayer (contract/tcgplayer-cart-2026-10-26.md) ─────────── */

export interface CartItem { oracle_id?: string | null; card_id?: string | null; qty: number }
/** A want for a printing, as a link to its TCGplayer product page (§ Printings). */
export interface CartProduct { card_id?: string; name: string; set: string; number: string; qty: number; url: string }
export interface CartAnswer { enabled: boolean; lines: number; unknown: number; urls: string[]; products?: CartProduct[] }
export interface CartEntry { title: string; detail: string; url: string }

/** Parts as menu labels: "Part 1 of 3". */
export const partTitle = (i: number, n: number) => `Part ${i + 1} of ${n}`;

/** What a tap opens straight away: the only link there is (testdata/tcgplayer-cart/cases.json). */
export function cartDirect(a: Pick<CartAnswer, "urls" | "products">): string | null {
  const products = a.products ?? [];
  return a.urls.length + products.length === 1 ? (a.urls[0] ?? products[0].url) : null;
}

/** The Buy on TCGplayer menu when there's more than one link: Mass Entry first, then each product page. */
export function cartMenu(a: Pick<CartAnswer, "urls" | "products">): CartEntry[] {
  if (cartDirect(a)) return [];
  const products = a.products ?? [];
  const n = a.urls.length;
  const parts = a.urls.map((url, i) =>
    !products.length ? { title: partTitle(i, n), detail: "Adds to the same cart", url }
      : n === 1 ? { title: "Any printing", detail: "Into one cart, then Optimize", url }
      : { title: `Any printing · part ${i + 1} of ${n}`, detail: "Adds to the same cart", url });
  return [...parts, ...products.map((p) => ({
    title: p.name, detail: `${p.set} ${p.number} · ${p.qty} ${p.qty === 1 ? "copy" : "copies"} · its own page`, url: p.url,
  }))];
}

/** The server writes the links (names, parts, product pages, affiliate wrapper). The demo has no account. */
/** `from` tags the affiliate link with the screen (wants / missing / deck / cube / card); the server adds the platform.
 *  `products` sends printings to their product pages; off, every card goes into Mass Entry by name. */
export async function tcgplayerCart(items: CartItem[], from?: string, products = true): Promise<CartAnswer> {
  if (isLibraryDemo()) throw new Error("Sign in to build a TCGplayer cart");
  const { data, error: e } = await supabase.rpc("tcgplayer_cart", { p_items: items, p_products: products, ...(from ? { p_from: from } : {}) });
  if (e) throw new Error(e.message);
  return data as CartAnswer;
}

/** Whether the Buy on TCGplayer rows show: the server's switch (an empty cart answers it). */
export async function tcgplayerEnabled(): Promise<boolean> {
  if (isLibraryDemo()) return true;
  try {
    return (await tcgplayerCart([])).enabled;
  } catch {
    return false;
  }
}
