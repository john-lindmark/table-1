// Trades (contract/trades-2026-10-16.md): this account's record of a swap. Drafts save as they're built;
// confirming applies both sides to the collection in one batch.
import { useEffect, useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";
import { applyOps, demoBackend, sync, type Condition, type Finish } from "./collection";
import { isLibraryDemo } from "./libraryDemo";
import { capture } from "./telemetry";

export interface TradeLine {
  card_id: string;
  finish: Finish;
  condition: Condition;
  lang: string;
  qty: number;
}

export interface Trade {
  id: string;
  partner: string | null;
  note: string | null;
  status: "draft" | "confirmed";
  gives: TradeLine[];
  gets: TradeLine[];
  batch_id: string | null;
  created_at: string;
  updated_at: string;
  confirmed_at: string | null;
}

export const lineKey = (l: TradeLine) => `${l.card_id}|${l.finish}|${l.condition}|${l.lang}`;

let state: { trades: Trade[]; loaded: boolean; error: string | null } = { trades: [], loaded: false, error: null };
const subs = new Set<() => void>();
const set = (next: Partial<typeof state>) => {
  state = { ...state, ...next };
  for (const s of subs) s();
};
const put = (t: Trade) => {
  const i = state.trades.findIndex((x) => x.id === t.id);
  set({ trades: i >= 0 ? state.trades.map((x) => (x.id === t.id ? t : x)) : [t, ...state.trades] });
};

export async function loadTrades() {
  if (isLibraryDemo()) return set({ loaded: true });
  const { data, error } = await supabase.rpc("trades_list", { p_limit: 200 });
  if (error) return set({ error: error.message });
  set({ trades: data as Trade[], loaded: true, error: null });
}

export function useTrades() {
  const s = useSyncExternalStore((cb) => {
    subs.add(cb);
    return () => subs.delete(cb);
  }, () => state);
  useEffect(() => {
    void loadTrades();
  }, []);
  return s;
}

export async function saveTrade(t: Trade | null, partner: string | null, gives: TradeLine[], gets: TradeLine[]): Promise<Trade> {
  if (demoBackend()) {
    const now = new Date().toISOString();
    const saved: Trade = {
      id: t?.id ?? crypto.randomUUID(), partner, note: null, status: "draft", gives, gets, batch_id: null,
      created_at: t?.created_at ?? now, updated_at: now, confirmed_at: null,
    };
    put(saved);
    return saved;
  }
  const { data, error } = await supabase.rpc("trade_save", {
    p_trade_id: t?.id ?? null, p_partner: partner, p_note: null, p_gives: gives, p_gets: gets,
  });
  if (error) throw error;
  put(data as Trade);
  return data as Trade;
}

/** Applies the trade to the collection; returns the collection batch id (for Undo). */
export async function confirmTrade(t: Trade): Promise<string | null> {
  if (demoBackend()) {
    const res = await applyOps([
      ...t.gives.map((l) => ({ ...l, delta: -l.qty, qty: undefined })),
      ...t.gets.map((l) => ({ ...l, delta: l.qty, qty: undefined })),
    ], "trade");
    put({ ...t, status: "confirmed", batch_id: res.batch_id, confirmed_at: new Date().toISOString() });
    return res.batch_id;
  }
  const { data, error } = await supabase.rpc("trade_confirm", { p_trade_id: t.id, p_idempotency_key: crypto.randomUUID() });
  if (error) throw error;
  const res = data as { batch_id?: string; trade: Trade };
  put(res.trade);
  await sync();
  return res.batch_id ?? null;
}

export async function deleteTrade(t: Trade) {
  set({ trades: state.trades.filter((x) => x.id !== t.id) });
  if (demoBackend()) return;
  const { error } = await supabase.rpc("trade_delete", { p_trade_id: t.id });
  if (error) set({ error: error.message });
  else capture("trade_deleted", { status: t.status });
}
