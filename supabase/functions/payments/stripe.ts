// What the payments function says to Stripe, as pure functions (no network, no secrets) so they can be tested.
// Facts and sources: table-1-context/docs/stripe-connect-notes-2026-11-13.md (read from docs.stripe.com 2026-11-13).

export const STRIPE_VERSION = "2026-10-28.endive";

/** v1 endpoints take form-encoded bodies with bracket notation: {a: {b: 1}, c: [{d: 2}]} → a[b]=1&c[0][d]=2. */
export function formEncode(value: Record<string, unknown>): string {
  const out: string[] = [];
  const walk = (key: string, v: unknown) => {
    if (v === undefined || v === null) return;
    if (Array.isArray(v)) v.forEach((item, i) => walk(`${key}[${i}]`, item));
    else if (typeof v === "object") for (const [k, inner] of Object.entries(v as Record<string, unknown>)) walk(`${key}[${k}]`, inner);
    else out.push(`${encodeURIComponent(key)}=${encodeURIComponent(String(v))}`);
  };
  for (const [k, v] of Object.entries(value)) walk(k, v);
  return out.join("&");
}

const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * Stripe-Signature: `t=<unix>,v1=<hex>[,v1=…][,v0=…][,anything=…]`. The signed text is `t + "." + the raw body`, the
 * key the whole `whsec_…` secret, HMAC-SHA256 in hex. Any matching v1 passes (there are two while a secret is rolled);
 * unknown entries are ignored; a timestamp more than `toleranceSeconds` from now is refused.
 */
export async function verifySignature(
  header: string | null, rawBody: string, secret: string, nowSeconds = Date.now() / 1000, toleranceSeconds = 300,
): Promise<boolean> {
  if (!header || !secret) return false;
  let t = "";
  const v1: string[] = [];
  for (const part of header.split(",")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    const key = part.slice(0, eq).trim(), val = part.slice(eq + 1).trim();
    if (key === "t") t = val;
    else if (key === "v1") v1.push(val);
  }
  if (!/^\d+$/.test(t) || v1.length === 0) return false;
  if (Math.abs(nowSeconds - Number(t)) > toleranceSeconds) return false;
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const want = hex(await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${rawBody}`)));
  return v1.some((got) => sameText(got.toLowerCase(), want));
}

export interface CheckoutInput {
  amountCents: number; currency: string; eventName: string; eventId: string; paymentId: string; participantId: string;
  /** Table 1's own fee on this charge, in cents (0 = none: Stripe refuses a zero application fee, so it is left out). */
  feeCents: number;
  site: string; origin: "ios" | "android" | "web"; email?: string | null;
  /** Unix seconds: Stripe takes 30 minutes to 24 hours from creation. */
  expiresAt: number;
}

/** A one-off Checkout Session for an entry fee, created on the host's account (direct charge). */
export function checkoutParams(i: CheckoutInput): Record<string, unknown> {
  const meta = { payment_id: i.paymentId, event_id: i.eventId, participant_id: i.participantId, source: "table1" };
  const fee = Math.min(Math.max(0, Math.floor(i.feeCents)), i.amountCents - 1);
  return {
    mode: "payment",
    line_items: [{
      quantity: 1,
      price_data: { currency: i.currency, unit_amount: i.amountCents, product_data: { name: `Entry: ${i.eventName}`.slice(0, 120) } },
    }],
    success_url: `${i.site}/pay/done?e=${i.eventId}&s={CHECKOUT_SESSION_ID}`,
    cancel_url: `${i.site}/pay/done?e=${i.eventId}&cancelled=1`,
    client_reference_id: i.paymentId,
    ...(i.email ? { customer_email: i.email } : {}),
    expires_at: i.expiresAt,
    metadata: meta,
    payment_intent_data: { metadata: meta, ...(fee > 0 ? { application_fee_amount: fee } : {}) },
    ...(i.origin === "web" ? {} : { origin_context: "mobile_app" }),
  };
}

/**
 * A new host account: the host's own full Stripe dashboard, Stripe collects its fees from the host and carries
 * losses. Checked in the sandbox 2026-11-14: Stripe refuses the Express dashboard with either fee setting on this
 * platform (`account_controller_unsupported_configuration`), and the platform as losses collector.
 */
export function newAccountBody(email: string | null, name: string): Record<string, unknown> {
  return {
    ...(email ? { contact_email: email } : {}),
    display_name: name.slice(0, 100) || "Table 1 host",
    dashboard: "full",
    identity: { country: "us", entity_type: "individual" },
    configuration: { merchant: { capabilities: { card_payments: { requested: true } } } },
    defaults: { currency: "usd", responsibilities: { fees_collector: "stripe", losses_collector: "stripe" } },
    include: ["configuration.merchant", "requirements", "defaults"],
  };
}

export function accountLinkBody(account: string, site: string): Record<string, unknown> {
  return {
    account,
    use_case: {
      type: "account_onboarding",
      account_onboarding: {
        refresh_url: `${site}/pay/connect`,
        return_url: `${site}/pay/connected`,
        collection_options: { fields: "eventually_due" },
      },
    },
  };
}

/** What we keep from a v1 Account object (a v2 account id reads through v1 too). */
// deno-lint-ignore no-explicit-any
export function accountFlags(a: any): Record<string, unknown> {
  return {
    charges_enabled: a?.charges_enabled === true,
    payouts_enabled: a?.payouts_enabled === true,
    details_submitted: a?.details_submitted === true,
    disabled_reason: typeof a?.requirements?.disabled_reason === "string" ? a.requirements.disabled_reason : null,
    ...(typeof a?.livemode === "boolean" ? { livemode: a.livemode } : {}),
  };
}

/** What a webhook event asks us to do, or null to ignore it. */
// deno-lint-ignore no-explicit-any
export function eventAction(ev: any):
  | { do: "settle"; session: string; intent: string | null; status: "paid" | "failed" | "expired" }
  | { do: "refunded"; intent: string; refund: string | null }
  | { do: "account"; account: string; flags: Record<string, unknown> }
  | { do: "gone"; account: string }
  | null {
  const o = ev?.data?.object;
  const intent = typeof o?.payment_intent === "string" ? o.payment_intent : o?.payment_intent?.id ?? null;
  switch (ev?.type) {
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded":
      // A delayed payment method completes the session unpaid first; it's paid when the async event says so.
      if (o?.payment_status === "unpaid") return null;
      return { do: "settle", session: String(o.id), intent, status: "paid" };
    case "checkout.session.async_payment_failed":
      return { do: "settle", session: String(o.id), intent, status: "failed" };
    case "checkout.session.expired":
      return { do: "settle", session: String(o.id), intent, status: "expired" };
    case "charge.refunded":
      // Only a full refund frees the entry; a partial one is the host's own arrangement.
      if (o?.refunded !== true || !intent) return null;
      return { do: "refunded", intent, refund: o?.refunds?.data?.[0]?.id ?? null };
    case "account.updated":
      return typeof o?.id === "string" ? { do: "account", account: o.id, flags: accountFlags(o) } : null;
    case "account.application.deauthorized":
      return typeof ev?.account === "string" ? { do: "gone", account: ev.account } : null;
    default:
      return null;
  }
}
