// The redraft pile for a finished set draft (contract/event-night-2026-10-16.md § 6): anyone in the event adds cards;
// the list runs most valuable first (TCGplayer market for the finish) and stays with the event. Same as iOS RedraftView
// and Android Redraft.kt; the web has no scanner, so cards are added by search.
import { supabase } from "./supabaseClient";
import type { Catalog } from "./catalog";
import type { Table1Event } from "./types";

export interface RedraftCard {
  id: string; card_id: string; finish: "nonfoil" | "foil" | "etched"; name: string; set: string; cn: string;
  usd: number | null; added_by: string; mine: boolean;
}
export interface RedraftPile { count: number; total_usd: number; cards: RedraftCard[] }

/** Set drafts (not cubes) get a redraft once the event is over. */
export const canRedraft = (e: Pick<Table1Event, "formatName" | "cubeName" | "cubeUrl" | "status">) =>
  (e.formatName === "draft" || e.formatName === "team_draft") && !e.cubeName && !e.cubeUrl && (e.status === "completed" || e.status === "archived");

/** "MKM 123 · Foil · You". */
export const redraftDetail = (c: RedraftCard) =>
  [`${c.set.toUpperCase()} ${c.cn}`, c.finish === "nonfoil" ? null : c.finish === "foil" ? "Foil" : "Etched", c.mine ? "You" : c.added_by]
    .filter(Boolean).join(" · ");

/** The printing a searched card goes in as: the drafted set's when the card is in it, else the search's own. */
export function redraftPrinting(c: Catalog, oi: number, setCode: string | null, fallback: number): number {
  if (setCode) {
    const want = setCode.toLowerCase();
    for (let p = c.pFirst[oi]; p >= 0 && p < c.pFirst[oi] + c.pCount[oi]; p++) if (c.pSet[p] === want && c.pLang[p] === "en") return p;
  }
  return fallback;
}

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

export const redraftList = (eventId: string) => rpc<RedraftPile>("redraft_list", { p_event_id: eventId });
export const redraftAdd = (eventId: string, cards: { card_id: string; finish: string }[]) =>
  rpc<RedraftPile>("redraft_add", { p_event_id: eventId, p_cards: cards.slice(0, 200) });
export const redraftRemove = (id: string) => rpc<RedraftPile>("redraft_remove", { p_id: id });
