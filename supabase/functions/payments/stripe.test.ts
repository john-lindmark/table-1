// The payments function's Stripe wire format (contract/entry-fees-2026-11-13.md; Stripe facts in
// table-1-context/docs/stripe-connect-notes-2026-11-13.md).
import { test } from "node:test";
import assert from "node:assert/strict";
import { accountFlags, accountLinkBody, checkoutParams, eventAction, formEncode, newAccountBody, verifySignature } from "./stripe.ts";

test("form encoding uses bracket notation for nested values and skips nulls", () => {
  assert.equal(formEncode({ mode: "payment", a: { b: 1, c: null }, items: [{ q: 1, d: { n: "x y" } }], gone: undefined }),
    "mode=payment&a%5Bb%5D=1&items%5B0%5D%5Bq%5D=1&items%5B0%5D%5Bd%5D%5Bn%5D=x%20y");
});

// HMAC-SHA256("whsec_test", '1700000000.{"id":"evt_1"}'), worked out with Python's hmac module.
const BODY = '{"id":"evt_1"}';
const SIG = "c89214b5b5da833daed6f0b8c5bb6bd58cea9022bd80ccc78230f3942d632925";

test("a webhook signature", async () => {
  const now = 1700000100;
  assert.equal(await verifySignature(`t=1700000000,v1=${SIG}`, BODY, "whsec_test", now), true);
  assert.equal(await verifySignature(`t=1700000000,v1=${"0".repeat(64)},v1=${SIG}`, BODY, "whsec_test", now), true, "any v1 may match while a secret is rolled");
  assert.equal(await verifySignature(`v0=abc,t=1700000000,destination=whk_1,v1=${SIG},payload=x`, BODY, "whsec_test", now), true, "unknown entries, any order");
  assert.equal(await verifySignature(`t=1700000000,v1=${SIG}`, BODY + " ", "whsec_test", now), false, "a changed body");
  assert.equal(await verifySignature(`t=1700000000,v1=${SIG}`, BODY, "whsec_other", now), false, "another secret");
  assert.equal(await verifySignature(`t=1700000001,v1=${SIG}`, BODY, "whsec_test", now), false, "a changed timestamp");
  assert.equal(await verifySignature(`t=1700000000,v1=${SIG}`, BODY, "whsec_test", 1700000000 + 301), false, "older than five minutes");
  assert.equal(await verifySignature(`t=1700000000,v1=${SIG}`, BODY, "whsec_test", 1700000000 - 301), false, "from the future");
  assert.equal(await verifySignature(`t=1700000000,v0=${SIG}`, BODY, "whsec_test", now), false, "v0 alone never passes");
  assert.equal(await verifySignature(null, BODY, "whsec_test", now), false);
  assert.equal(await verifySignature(`t=1700000000,v1=${SIG}`, BODY, "", now), false, "no secret set");
});

const input = {
  amountCents: 2500, currency: "usd", eventName: "Modern Open", eventId: "ev1", paymentId: "pay1", participantId: "p1",
  feeCents: 0, site: "https://table-1.site", origin: "ios" as const, email: "bea@example.com", expiresAt: 1700001800,
};

test("checkout: a direct charge for the entry, no application fee at 0", () => {
  const p = checkoutParams(input) as Record<string, any>;
  assert.equal(p.mode, "payment");
  assert.deepEqual(p.line_items, [{ quantity: 1, price_data: { currency: "usd", unit_amount: 2500, product_data: { name: "Entry: Modern Open" } } }]);
  assert.equal(p.success_url, "https://table-1.site/pay/done?e=ev1&s={CHECKOUT_SESSION_ID}");
  assert.equal(p.cancel_url, "https://table-1.site/pay/done?e=ev1&cancelled=1");
  assert.equal(p.client_reference_id, "pay1");
  assert.deepEqual(p.metadata, p.payment_intent_data.metadata);
  assert.equal(p.metadata.payment_id, "pay1");
  assert.equal("application_fee_amount" in p.payment_intent_data, false);
  assert.equal(p.origin_context, "mobile_app");
  assert.equal(p.expires_at, 1700001800);
  assert.match(formEncode(p), /line_items%5B0%5D%5Bprice_data%5D%5Bunit_amount%5D=2500/);
});

test("checkout: Table 1's fee when there is one, never the whole charge; the web sends no origin", () => {
  assert.equal((checkoutParams({ ...input, feeCents: 75 }) as any).payment_intent_data.application_fee_amount, 75);
  assert.equal((checkoutParams({ ...input, amountCents: 50, feeCents: 75 }) as any).payment_intent_data.application_fee_amount, 49);
  const web = checkoutParams({ ...input, origin: "web", email: null }) as any;
  assert.equal("origin_context" in web, false);
  assert.equal("customer_email" in web, false);
});

test("a new host account and its onboarding link", () => {
  const a = newAccountBody("ana@example.com", "Ana Org") as any;
  assert.equal(a.dashboard, "full");
  assert.deepEqual(a.defaults.responsibilities, { fees_collector: "stripe", losses_collector: "stripe" });
  assert.equal(a.configuration.merchant.capabilities.card_payments.requested, true);
  assert.equal("contact_email" in newAccountBody(null, ""), false);
  const l = accountLinkBody("acct_1", "https://table-1.site") as any;
  assert.equal(l.use_case.account_onboarding.return_url, "https://table-1.site/pay/connected");
  assert.equal("configurations" in l.use_case.account_onboarding, false, "Stripe refuses it as an unknown field");
  assert.equal(l.use_case.type, "account_onboarding");
});

test("account flags", () => {
  assert.deepEqual(accountFlags({ charges_enabled: true, payouts_enabled: false, details_submitted: true, livemode: false,
                                  requirements: { disabled_reason: "requirements.past_due" } }),
    { charges_enabled: true, payouts_enabled: false, details_submitted: true, disabled_reason: "requirements.past_due", livemode: false });
  assert.deepEqual(accountFlags({}), { charges_enabled: false, payouts_enabled: false, details_submitted: false, disabled_reason: null });
});

test("what each webhook event asks for", () => {
  const session = { id: "cs_1", payment_intent: "pi_1", payment_status: "paid" };
  assert.deepEqual(eventAction({ type: "checkout.session.completed", data: { object: session } }), { do: "settle", session: "cs_1", intent: "pi_1", status: "paid" });
  assert.equal(eventAction({ type: "checkout.session.completed", data: { object: { ...session, payment_status: "unpaid" } } }), null);
  assert.deepEqual(eventAction({ type: "checkout.session.async_payment_succeeded", data: { object: session } })?.do, "settle");
  assert.deepEqual(eventAction({ type: "checkout.session.expired", data: { object: { id: "cs_2", payment_intent: null } } }), { do: "settle", session: "cs_2", intent: null, status: "expired" });
  assert.deepEqual(eventAction({ type: "checkout.session.async_payment_failed", data: { object: session } }), { do: "settle", session: "cs_1", intent: "pi_1", status: "failed" });
  assert.deepEqual(eventAction({ type: "charge.refunded", data: { object: { payment_intent: "pi_1", refunded: true, refunds: { data: [{ id: "re_1" }] } } } }), { do: "refunded", intent: "pi_1", refund: "re_1" });
  assert.equal(eventAction({ type: "charge.refunded", data: { object: { payment_intent: "pi_1", refunded: false } } }), null, "a partial refund frees nothing");
  assert.deepEqual(eventAction({ type: "account.updated", data: { object: { id: "acct_1", charges_enabled: true } } }),
    { do: "account", account: "acct_1", flags: { charges_enabled: true, payouts_enabled: false, details_submitted: false, disabled_reason: null } });
  assert.deepEqual(eventAction({ type: "account.application.deauthorized", account: "acct_1", data: { object: {} } }), { do: "gone", account: "acct_1" });
  assert.equal(eventAction({ type: "payment_intent.created", data: { object: {} } }), null);
});
