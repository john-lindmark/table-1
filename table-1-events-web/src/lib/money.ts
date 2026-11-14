// Entry fees and prizes (contract/entry-fees-2026-11-13.md): the wire types, the wording and sums the three clients
// share (testdata/leagues/cases.json: money, fee_line, pay_tag, payout_presets, payout_words, prize_at, pool; change
// a rule in testdata/leagues/make_cases.py first), and the calls.
//
// The host is the seller on their own Stripe account and Table 1 never holds money: paying is Stripe's hosted
// checkout page, opened from the `payments` edge function's link. A return from Stripe proves nothing; the payment
// counts when event_money says so. Like the rest of leagues.ts, the server part may not be live: reads that are
// extras answer null (the part doesn't draw), `payments` answers 503 "Payments aren't set up yet" until Table 1's own
// Stripe keys exist (shown as that plain line), and nothing here is reported to Sentry.
import { ordinal, phasesDemo, rpc } from "./leagues";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";

/* ── wire ────────────────────────────────────────────────────────────── */

export type PayMode = "door" | "app" | "either";
export type KeepKind = "none" | "flat" | "percent";
export interface PayoutBracket { through: number; percent: number }
export interface Fee {
  amount_cents: number; currency?: string; pay_mode: PayMode; refund_hours: number | null;
  host_keep: { kind: KeepKind; value: number }; added_cents: number; payout: PayoutBracket[]; league_cut_cents: number;
}
export interface Pool {
  entries: number; gross_cents: number; league_cut_cents: number; host_keep_cents: number; added_cents: number; pool_cents: number;
}
export type PayStatus = "unpaid" | "pending" | "paid" | "refunded";
export type PayMethod = "app" | "door" | "comp" | null;
export interface Payment { status: PayStatus; method: PayMethod; amount_cents?: number }
export interface MyPayment extends Payment { participant_id: string; can_pay: boolean; can_refund: boolean }
export interface PlayerPayment extends Payment { participant_id: string; user_id: string | null; name: string }
export interface Prize {
  participant_id: string; user_id?: string | null; name: string; place: number; amount_cents: number; custom: boolean; paid: boolean;
  paid_how: string | null;
}
export interface EventMoney {
  fee: Fee | null;
  app_ready?: boolean;
  pool?: Pool;
  me?: MyPayment | null;
  prizes?: Prize[];
  organizer?: { stripe: { connected: boolean; ready: boolean }; players: PlayerPayment[]; unpaid: number } | null;
}
export interface StripeAccount { connected: boolean; ready: boolean; payouts: boolean; details_submitted: boolean; disabled_reason: string | null }
export interface LeagueDue { event_id: string; name: string; entries: number; owed_cents: number; received_cents: number }
export interface LeagueMoney { entry_cut_cents: number; pool_cents: number; received_cents?: number | null; events?: LeagueDue[] | null }

/* ── wording and sums ────────────────────────────────────────────────── */

/** "$25", "$7.50", "$1,400": whole dollars lose their cents. */
export function money(cents: number): string {
  const n = Math.abs(Math.trunc(cents));
  const whole = Math.floor(n / 100), part = n % 100;
  return `${cents < 0 ? "-" : ""}$${whole.toLocaleString("en-US")}${part ? `.${String(part).padStart(2, "0")}` : ""}`;
}

const PAY_MODES: Record<PayMode, string> = { door: "DOOR", app: "APP", either: "APP OR DOOR" };

/** The fee on a data line: "NONE", "FREE", "$25 · APP OR DOOR". */
export function feeLine(fee: Pick<Fee, "amount_cents" | "pay_mode"> | null | undefined): string {
  if (!fee) return "NONE";
  if (fee.amount_cents === 0) return "FREE";
  return `${money(fee.amount_cents)} · ${PAY_MODES[fee.pay_mode] ?? "DOOR"}`;
}

/** A player's payment tag: "PAID · APP", "PAID · DOOR", "COMP", "UNPAID", "PENDING", "REFUNDED". */
export function payTag(p: Pick<Payment, "status" | "method">): string {
  if (p.status === "paid") return p.method === "comp" ? "COMP" : `PAID · ${p.method === "door" ? "DOOR" : "APP"}`;
  return p.status === "pending" ? "PENDING" : p.status === "refunded" ? "REFUNDED" : "UNPAID";
}
/** What the player's own screen says once paid: "PAID", "PAID AT THE DOOR", "COMP". */
export const paidWord = (p: Pick<Payment, "method">) => (p.method === "door" ? "PAID AT THE DOOR" : p.method === "comp" ? "COMP" : "PAID");

export type PayoutPreset = "winner" | "top2" | "top4" | "top8";
export const PAYOUT_PRESETS: Record<PayoutPreset, PayoutBracket[]> = {
  winner: [{ through: 1, percent: 100 }],
  top2: [{ through: 1, percent: 65 }, { through: 2, percent: 35 }],
  top4: [{ through: 1, percent: 40 }, { through: 2, percent: 25 }, { through: 4, percent: 17.5 }],
  top8: [{ through: 1, percent: 30 }, { through: 2, percent: 20 }, { through: 4, percent: 12.5 }, { through: 8, percent: 6.25 }],
};
export const PAYOUT_LABELS: { value: PayoutPreset | "custom"; label: string }[] = [
  { value: "winner", label: "Winner takes all" }, { value: "top2", label: "Top 2" }, { value: "top4", label: "Top 4" },
  { value: "top8", label: "Top 8" }, { value: "custom", label: "Custom brackets" },
];
const samePayout = (a: PayoutBracket[], b: PayoutBracket[]) =>
  a.length === b.length && a.every((x, i) => x.through === b[i].through && x.percent === b[i].percent);
/** Which preset a payout is (for the picker and `fee_saved`); an empty table is custom. */
export const payoutPresetOf = (payout: PayoutBracket[]): PayoutPreset | "custom" =>
  (Object.keys(PAYOUT_PRESETS) as PayoutPreset[]).find((k) => samePayout(payout, PAYOUT_PRESETS[k])) ?? "custom";

/** A percent as Python's %g prints it: "40", "17.5", "6.25". */
const pct = (v: number) => `${Number(v.toPrecision(6))}%`;

/** "1st 40% · 2nd 25% · 3rd to 4th 17.5% each"; "No prizes set" for an empty table. */
export function payoutWords(payout: PayoutBracket[] | null | undefined): string {
  const parts: string[] = [];
  let last = 0;
  for (const b of payout ?? []) {
    const t = b.through;
    parts.push(`${t === last + 1 ? ordinal(t) : `${ordinal(last + 1)} to ${ordinal(t)}`} ${pct(b.percent)}${t > last + 1 ? " each" : ""}`);
    last = t;
  }
  return parts.join(" · ") || "No prizes set";
}

/** What the table hands out in all: each bracket's percent for every place in it. Can't pass 100. */
export function payoutTotal(payout: PayoutBracket[] | null | undefined): number {
  let total = 0, last = 0;
  for (const b of payout ?? []) {
    total += b.percent * (b.through - last);
    last = b.through;
  }
  return total;
}

/** A place's prize at a pool (whole cents, rounded down); a team's is split evenly among its `share` members. */
export function prizeAt(payout: PayoutBracket[] | null | undefined, poolCents: number, place: number, share = 1): number {
  for (const b of payout ?? []) if (b.through >= place) return Math.trunc((poolCents * b.percent) / 100 / share);
  return 0;
}

/** Each place with a prize at a pool, for the breakdown: [{place: 1, amount_cents}, …] down to the last bracket. */
export function prizeTable(payout: PayoutBracket[] | null | undefined, poolCents: number): { place: number; amount_cents: number }[] {
  const last = (payout ?? []).reduce((n, b) => Math.max(n, b.through), 0);
  return Array.from({ length: Math.min(last, 64) }, (_, i) => ({ place: i + 1, amount_cents: prizeAt(payout, poolCents, i + 1) }));
}

/** The pool from paid entries: less the league's cut and the host's share (flat: that amount; percent: of what's left
 *  after the league), plus added money. The editor's preview; the server's `pool` is the one that counts. */
export function poolOf(entries: number, amountCents: number, cutCents: number, keepKind: KeepKind, keepValue: number, addedCents: number):
  { gross_cents: number; league_cut_cents: number; host_keep_cents: number; pool_cents: number } {
  const gross = entries * amountCents;
  const league = entries * Math.min(cutCents, amountCents);
  const keep = keepKind === "flat" ? Math.min(keepValue, gross - league)
    : keepKind === "percent" ? Math.trunc(((gross - league) * keepValue) / 100) : 0;
  return { gross_cents: gross, league_cut_cents: league, host_keep_cents: keep, pool_cents: Math.max(0, gross - league - keep) + addedCents };
}

/** "$25.00" typed into a field → cents (null for something that isn't an amount). */
export function centsOf(text: string): number | null {
  const t = text.replace(/[$,\s]/g, "");
  if (!/^\d{0,7}(\.\d{0,2})?$/.test(t) || t === "" || t === ".") return null;
  return Math.round(Number(t) * 100);
}
/** Cents as a field shows them: "25", "7.50". */
export const centsText = (cents: number) => money(cents).slice(1).replace(/,/g, "");

export const REFUND_PICKS: { value: string; label: string; hours: number | null }[] = [
  { value: "48", label: "Until 48 h before", hours: 48 }, { value: "24", label: "24 h before", hours: 24 },
  { value: "0", label: "Until it starts", hours: 0 }, { value: "ask", label: "Ask me", hours: null },
];
/** How a prize was paid: the words go to the server as they are (`paid_how`, up to 40 characters). */
export const PRIZE_HOWS: { value: string; label: string }[] = [
  { value: "cash", label: "Cash" }, { value: "store credit", label: "Store credit" }, { value: "other", label: "Other" },
];
/** "PAID · CASH", "PAID · STORE CREDIT"; "PAID" for Other or nothing said. */
export const prizePaidTag = (how: string | null | undefined) =>
  (how && how.trim().toLowerCase() !== "other" ? `PAID · ${how.trim().toUpperCase()}` : "PAID");
/** The Players header: "4 UNPAID" (nothing at 0). */
export const unpaidHeader = (n: number) => (n > 0 ? `${n} UNPAID` : "");
/** Pairing round 1 with unpaid players asks first. */
export const unpaidConfirm = (n: number) => `${n} ${n === 1 ? "player hasn't" : "players haven't"} paid. Pair anyway?`;
/** Account → Payments: "NOT CONNECTED", "FINISH SETTING UP", "READY". */
export const stripeLine = (a: Pick<StripeAccount, "connected" | "ready"> | null | undefined) =>
  !a?.connected ? "NOT CONNECTED" : a.ready ? "READY" : "FINISH SETTING UP";
export const PAYMENTS_OFF = "Payments aren't set up yet";

/* ── calls ───────────────────────────────────────────────────────────── */

/** An event's money for whoever can open it; null when the server has none of it yet or the read fails. */
export async function eventMoney(eventId: string, token?: string | null): Promise<EventMoney | null> {
  try {
    const d = await phasesDemo();
    if (d) return d.eventMoney(eventId);
    return await rpc<EventMoney>("event_money", token ? { p_event_id: eventId, p_token: token } : { p_event_id: eventId });
  } catch {
    return null;
  }
}

export type FeePatch = Partial<Pick<Fee, "amount_cents" | "pay_mode" | "refund_hours" | "host_keep" | "added_cents" | "payout">>;
export async function eventFeeSet(eventId: string, fee: FeePatch | null): Promise<{ fee: Fee | null }> {
  const d = await phasesDemo();
  const r = d ? d.eventFeeSet(eventId, fee) : await rpc<{ fee: Fee | null }>("event_fee_set", { p_event_id: eventId, p_fee: fee });
  capture("fee_saved", { pay_mode: r.fee?.pay_mode ?? "none", amount: r.fee?.amount_cents ?? 0 });
  return r;
}

export async function eventPaymentMark(eventId: string, participantId: string, state: "door" | "comp" | "unpaid"): Promise<void> {
  const d = await phasesDemo();
  if (d) d.eventPaymentMark(eventId, participantId, state);
  else await rpc<unknown>("event_payment_mark", { p_event_id: eventId, p_participant_id: participantId, p_state: state });
  capture("payment_marked", { state });
}

export async function eventPrizesSet(eventId: string, rows: { participant_id: string; amount_cents: number }[] | null): Promise<void> {
  const d = await phasesDemo();
  if (d) d.eventPrizesSet(eventId, rows);
  else await rpc<unknown>("event_prizes_set", { p_event_id: eventId, p_rows: rows });
  capture("prizes_split", { rows: rows?.length ?? 0 });
}

export async function eventPrizeMark(eventId: string, participantId: string, paid: boolean, how: string | null = null): Promise<void> {
  const d = await phasesDemo();
  if (d) d.eventPrizeMark(eventId, participantId, paid, how);
  else await rpc<unknown>("event_prize_mark", { p_event_id: eventId, p_participant_id: participantId, p_paid: paid, p_how: how });
  capture("prize_marked", { how: paid ? how ?? "other" : "unpaid" });
}

/** A season's prize pool and, for the league's organizers, its dues; null on a server before it or a failed read. */
export async function leagueMoney(seasonId: string): Promise<LeagueMoney | null> {
  try {
    const d = await phasesDemo();
    return d ? d.leagueMoney(seasonId) : await rpc<LeagueMoney>("league_money", { p_season_id: seasonId });
  } catch {
    return null;
  }
}

export async function leagueDueMark(eventId: string, receivedCents: number): Promise<void> {
  const d = await phasesDemo();
  if (d) d.leagueDueMark(eventId, receivedCents);
  else await rpc<unknown>("league_due_mark", { p_event_id: eventId, p_received_cents: receivedCents });
  capture("dues_marked", {});
}

/** Your Stripe connection as last heard (no call to Stripe); null signed out, before the server has it, or on a failed read. */
export async function paymentsAccount(): Promise<StripeAccount | null> {
  try {
    const d = await phasesDemo();
    return d ? d.paymentsAccount() : await rpc<StripeAccount>("payments_account");
  } catch {
    return null;
  }
}

/** What the `payments` function refused with: its own words, and `off` for the 503 before Table 1's Stripe keys exist. */
export class PaymentsError extends Error {
  constructor(message: string, public status: number) {
    super(message);
  }
  get off() {
    return this.status === 503;
  }
}

/** What a failed payments call says to the person: the function's line, never supabase-js's generic one. */
export function paymentsMessage(e: unknown): string {
  if (e instanceof PaymentsError) return e.off ? PAYMENTS_OFF : e.message;
  if (e instanceof Error && e.message) return e.message;
  return "Couldn't reach payments. Check your connection.";
}

/** Calls the payments function with the caller's token. A non-2xx answer carries `{error}`; that text is the message. */
async function payments<T>(body: Record<string, unknown>): Promise<T> {
  const d = await phasesDemo();
  if (d) return d.payments(body) as T;
  const { data, error } = await supabase.functions.invoke("payments", { body });
  if (error) {
    let message = "Couldn't reach payments. Check your connection.", status = 0;
    const ctx = (error as { context?: unknown }).context as Response | undefined;
    if (ctx && typeof ctx.status === "number") {
      status = ctx.status;
      // The function isn't deployed (404): the same plain line as before its keys exist.
      if (status === 404) status = 503;
      try {
        const payload = await ctx.clone().json();
        if (payload?.error) message = String(payload.error);
      } catch { /* not JSON */ }
      if (status === 503) message = PAYMENTS_OFF;
    }
    throw new PaymentsError(message, status);
  }
  if (data && typeof data === "object" && "error" in data && (data as { error?: unknown }).error) {
    throw new PaymentsError(String((data as { error: unknown }).error), 409);
  }
  return data as T;
}

/** Stripe's own onboarding for you (your account is made on the first call). Open it in a new tab, never a frame. */
export async function connectStart(): Promise<string> {
  const r = await payments<{ url: string }>({ action: "connect_start" });
  capture("stripe_connect_started", {});
  return r.url;
}

/** Asks Stripe now. */
export async function connectStatus(): Promise<StripeAccount> {
  const r = await payments<StripeAccount>({ action: "connect_status" });
  capture("stripe_connect_status", { ready: !!r.ready });
  return r;
}

export const connectDashboard = async () => (await payments<{ url: string }>({ action: "connect_dashboard" })).url;

/** Stripe's hosted checkout for your entry; an open checkout is handed back, not doubled. */
export async function checkout(eventId: string): Promise<string> {
  const r = await payments<{ url: string }>({ action: "checkout", event_id: eventId, origin: "web" });
  capture("pay_started", { origin: "web" });
  return r.url;
}

/** Your own app payment while `me.can_refund`, or any app payment when you run the event. */
export async function refund(eventId: string, participantId: string | null, by: "player" | "organizer"): Promise<{ refunded: boolean; amount_cents: number }> {
  capture("refund_asked", { by });
  return payments<{ refunded: boolean; amount_cents: number }>(
    { action: "refund", event_id: eventId, ...(participantId ? { participant_id: participantId } : {}) });
}

/** After any return from checkout the payment may still be on its way: re-read every 2 s for up to 20 s while pending. */
export const PENDING_POLL_MS = 2000;
export const PENDING_POLL_TRIES = 10;

/** /pay/done's line from what event_money says (the return itself proves nothing). */
export function payDoneState(cancelled: boolean, m: EventMoney | null | undefined): "paid" | "pending" | "cancelled" | "unknown" {
  if (m?.me?.status === "paid") return "paid";
  if (cancelled) return "cancelled";
  return m?.me ? "pending" : "unknown";
}
export const PAY_DONE_TITLE: Record<ReturnType<typeof payDoneState>, string> = {
  paid: "Paid", pending: "Not paid yet", cancelled: "Cancelled", unknown: "Not paid yet",
};
