// payments: entry fees through Stripe Connect, with the host as the seller (contract/entry-fees-2026-11-13.md;
// Stripe facts in table-1-context/docs/stripe-connect-notes-2026-11-13.md). Table 1 never holds money: every charge
// is a direct charge on the host's own Stripe account, paid on Stripe's hosted checkout page.
//
//   POST { action: "connect_start" }                 -> { url }  Stripe's onboarding for the caller (makes their account once)
//   POST { action: "connect_status" }                -> the caller's account as Stripe sees it now
//   POST { action: "connect_dashboard" }             -> { url }  where they sign in to their own Stripe dashboard
//   POST { action: "checkout", event_id, origin? }   -> { url }  hosted checkout for the caller's entry to that event
//   POST { action: "refund", event_id, participant_id? }
//                                                    -> the caller's own entry inside the refund window, or any entry
//                                                       when the caller runs the event
//   POST /payments/webhook                           -> Stripe's events from connected accounts (signature checked)
//
// Deploy with --no-verify-jwt: the webhook carries no JWT, and every other action checks the caller's token itself.
// Secrets: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET; STRIPE_SECRET_KEY_TEST + STRIPE_WEBHOOK_SECRET_TEST win while set. Without them the function answers 503 and the clients show
// "Payments aren't set up yet". All state changes go through the service-only RPCs in 20261113160000_entry_fees.sql.
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  accountFlags, accountLinkBody, checkoutParams, eventAction, formEncode, newAccountBody, STRIPE_VERSION, verifySignature,
} from "./stripe.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
// While STRIPE_SECRET_KEY_TEST is set the function runs on Stripe's sandbox and never touches the live key (John,
// 2026-11-14: testing first). Going live for real money = unset STRIPE_SECRET_KEY_TEST and STRIPE_WEBHOOK_SECRET_TEST.
const TEST_KEY = Deno.env.get("STRIPE_SECRET_KEY_TEST") ?? "";
const TESTING = TEST_KEY !== "";
const STRIPE_KEY = TESTING ? TEST_KEY : Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const WEBHOOK_SECRET = TESTING ? Deno.env.get("STRIPE_WEBHOOK_SECRET_TEST") ?? "" : Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
const SITE = (Deno.env.get("PUBLIC_SITE_URL") ?? "https://table-1.site").replace(/\/$/, "");

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

class Refused extends Error {
  constructor(public status: number, message: string) { super(message); }
}

/** One call to Stripe. v1: form-encoded; v2: JSON. `account` makes it a call on that connected account. */
async function stripe(
  method: "GET" | "POST", path: string, body: Record<string, unknown> | null,
  opts: { account?: string; idempotencyKey?: string } = {},
// deno-lint-ignore no-explicit-any
): Promise<any> {
  const v2 = path.startsWith("/v2/");
  const res = await fetch(`https://api.stripe.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${STRIPE_KEY}`,
      "Stripe-Version": STRIPE_VERSION,
      ...(body ? { "Content-Type": v2 ? "application/json" : "application/x-www-form-urlencoded" } : {}),
      ...(opts.account ? { "Stripe-Account": opts.account } : {}),
      ...(opts.idempotencyKey ? { "Idempotency-Key": opts.idempotencyKey } : {}),
    },
    body: body ? (v2 ? JSON.stringify(body) : formEncode(body)) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    // Stripe's message can be shown to a host (it says what to fix); never log the request, which may hold an email.
    console.error("stripe", method, path, res.status, data?.error?.code ?? data?.error?.type ?? "");
    throw new Refused(res.status >= 500 ? 502 : 409, data?.error?.message ?? "Stripe refused that");
  }
  return data;
}

// deno-lint-ignore no-explicit-any
async function rpc(fn: string, args: Record<string, unknown>): Promise<any> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) {
    const status = error.code === "42501" ? 403 : error.code === "P0002" ? 404 : ["22023", "55000"].includes(error.code ?? "") ? 409 : 500;
    if (status === 500) console.error("rpc", fn, error.code, error.message);
    throw new Refused(status, status === 500 ? "Something went wrong" : error.message);
  }
  return data;
}

async function caller(req: Request): Promise<{ id: string; email: string | null }> {
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) throw new Refused(401, "Sign in first");
  const asCaller = createClient(url, anonKey, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data, error } = await asCaller.auth.getUser();
  if (error || !data.user) throw new Refused(401, "Sign in first");
  return { id: data.user.id, email: data.user.email ?? null };
}

async function accountOf(userId: string): Promise<string | null> {
  const a = await rpc("stripe_account_get", { p_user_id: userId });
  return a?.account_id ?? null;
}

async function refreshAccount(userId: string, accountId: string) {
  const acct = await stripe("GET", `/v1/accounts/${accountId}`, null);
  return await rpc("stripe_account_put", { p_user_id: userId, p_account_id: accountId, p_flags: accountFlags(acct) });
}

async function connectStart(user: { id: string; email: string | null }) {
  let accountId = await accountOf(user.id);
  if (!accountId) {
    const { data: profile } = await admin.from("profiles").select("display_name").eq("id", user.id).maybeSingle();
    const acct = await stripe("POST", "/v2/core/accounts", newAccountBody(user.email, profile?.display_name ?? ""),
      { idempotencyKey: `t1-account-${user.id}` });
    accountId = String(acct.id);
    await rpc("stripe_account_put", { p_user_id: user.id, p_account_id: accountId, p_flags: {} });
  }
  const link = await stripe("POST", "/v2/core/account_links", accountLinkBody(accountId, SITE));
  return json({ url: link.url });
}

async function connectStatus(user: { id: string }) {
  const accountId = await accountOf(user.id);
  if (!accountId) return json({ connected: false, ready: false, payouts: false, details_submitted: false, disabled_reason: null });
  const a = await refreshAccount(user.id, accountId);
  return json({ connected: true, ready: a.charges_enabled, payouts: a.payouts_enabled, details_submitted: a.details_submitted,
                disabled_reason: a.disabled_reason });
}

async function connectDashboard(user: { id: string }) {
  const accountId = await accountOf(user.id);
  if (!accountId) throw new Refused(409, "Connect Stripe first");
  // Hosts have their own full Stripe dashboard (login links exist only for Express accounts): they sign in at Stripe.
  return json({ url: "https://dashboard.stripe.com/" });
}

async function checkout(user: { id: string; email: string | null }, eventId: string, origin: string) {
  const p = await rpc("payment_begin", { p_event_id: eventId, p_user_id: user.id });
  if (p.reuse_url) return json({ url: p.reuse_url });
  const expiresAt = Math.floor(Date.now() / 1000) + 31 * 60;   // Stripe's minimum is 30 minutes
  const session = await stripe("POST", "/v1/checkout/sessions", checkoutParams({
    amountCents: p.amount_cents, currency: p.currency, eventName: p.event_name, eventId, paymentId: p.payment_id,
    participantId: p.participant_id, feeCents: p.fee_cents ?? 0, site: SITE,
    origin: origin === "ios" || origin === "android" ? origin : "web", email: user.email, expiresAt,
  }), { account: p.account_id, idempotencyKey: `t1-checkout-${p.payment_id}` });
  await rpc("payment_session_put", {
    p_payment_id: p.payment_id, p_session_id: session.id, p_url: session.url,
    p_expires_at: new Date((session.expires_at ?? expiresAt) * 1000).toISOString(),
  });
  return json({ url: session.url });
}

async function refundIntent(accountId: string, intent: string, key: string, withFee: boolean) {
  return await stripe("POST", "/v1/refunds",
    { payment_intent: intent, reason: "requested_by_customer", ...(withFee ? { refund_application_fee: true } : {}) },
    { account: accountId, idempotencyKey: key });
}

async function refund(user: { id: string }, eventId: string, participantId: string | null) {
  const p = await rpc("payment_refund_begin", { p_event_id: eventId, p_participant_id: participantId, p_by: user.id });
  const r = await refundIntent(p.account_id, p.payment_intent, `t1-refund-${p.payment_id}`, false);
  await rpc("payment_refunded", { p_payment_intent: p.payment_intent, p_refund_id: r.id ?? null, p_by: user.id });
  return json({ refunded: true, amount_cents: p.amount_cents });
}

async function webhook(req: Request) {
  const raw = await req.text();
  if (!(await verifySignature(req.headers.get("Stripe-Signature"), raw, WEBHOOK_SECRET))) {
    return json({ error: "Bad signature" }, 400);
  }
  // deno-lint-ignore no-explicit-any
  let ev: any;
  try { ev = JSON.parse(raw); } catch { return json({ error: "Not JSON" }, 400); }
  // A sandbox function ignores live events and the other way round, whatever endpoint they were sent to.
  if (typeof ev?.livemode === "boolean" && ev.livemode === TESTING) return json({ received: true, ignored: "mode" });
  const act = eventAction(ev);
  if (act?.do === "settle") {
    const out = await rpc("payment_settle", { p_session_id: act.session, p_payment_intent: act.intent, p_status: act.status });
    // Paid on an old checkout after a newer one took its place: give that money straight back.
    if (out?.duplicate && out.payment_intent && out.account_id) {
      await refundIntent(out.account_id, out.payment_intent, `t1-duplicate-${out.payment_intent}`, false);
    }
  } else if (act?.do === "refunded") {
    await rpc("payment_refunded", { p_payment_intent: act.intent, p_refund_id: act.refund, p_by: null });
  } else if (act?.do === "account") {
    await rpc("stripe_account_put", { p_user_id: null, p_account_id: act.account, p_flags: act.flags });
  } else if (act?.do === "gone") {
    await rpc("stripe_account_gone", { p_account_id: act.account });
  }
  // Every handler above is safe to hear twice, so this is a record, not a gate.
  if (typeof ev?.id === "string") await rpc("stripe_event_seen", { p_id: ev.id });
  return json({ received: true });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    if (new URL(req.url).pathname.endsWith("/webhook")) {
      if (!WEBHOOK_SECRET) return json({ error: "Payments aren't set up yet" }, 503);
      return await webhook(req);
    }
    const body = await req.json().catch(() => ({}));
    const user = await caller(req);
    if (!STRIPE_KEY) return json({ error: "Payments aren't set up yet" }, 503);
    const uuid = (v: unknown) => (typeof v === "string" && /^[0-9a-f-]{36}$/i.test(v) ? v : null);
    switch (body.action) {
      case "connect_start": return await connectStart(user);
      case "connect_status": return await connectStatus(user);
      case "connect_dashboard": return await connectDashboard(user);
      case "checkout": {
        const eventId = uuid(body.event_id);
        if (!eventId) return json({ error: "event_id is required" }, 400);
        return await checkout(user, eventId, String(body.origin ?? "web"));
      }
      case "refund": {
        const eventId = uuid(body.event_id);
        if (!eventId) return json({ error: "event_id is required" }, 400);
        return await refund(user, eventId, uuid(body.participant_id));
      }
      default: return json({ error: "Unknown action" }, 400);
    }
  } catch (e) {
    if (e instanceof Refused) return json({ error: e.message }, e.status);
    console.error(e);
    return json({ error: "Something went wrong" }, 500);
  }
});
