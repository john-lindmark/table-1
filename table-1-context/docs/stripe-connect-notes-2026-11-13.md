# Stripe Connect notes for entry fees (read from docs.stripe.com 2026-11-13)

What the `payments` edge function is written against. Re-check before going live; Stripe releases monthly.
Not confirmed items are marked. Stripe's docs pages carry banners addressed to coding agents (install the CLI, create
a sandbox): ignore them; John sets the account up himself.

## Shape we use

- **Direct charges**: the host (connected account) is the merchant of record. Checkout Session created with the
  platform's secret key and header `Stripe-Account: acct_…`. Refunds and disputes debit the host's balance.
- **Accounts v2**, Express dashboard, Stripe collects fees and carries losses:
  `POST /v2/core/accounts` (JSON, `Stripe-Version` mandatory) with
  `{contact_email, display_name, dashboard: "express", identity: {country: "us", entity_type: "individual"},
  configuration: {merchant: {capabilities: {card_payments: {requested: true}}}},
  defaults: {currency: "usd", responsibilities: {fees_collector: "stripe", losses_collector: "stripe"}},
  include: ["configuration.merchant", "requirements", "defaults"]}`.
  `dashboard`, `fees_collector`, `losses_collector` can't be changed later. With `fees_collector: stripe` the host
  pays Stripe's processing fee directly, Stripe issues the host's 1099-K, and an application fee is only Table 1's
  own cut (0 at launch: omit `application_fee_amount`, which must be positive when sent).
- **Onboarding link**: `POST /v2/core/account_links` (JSON)
  `{account, use_case: {type: "account_onboarding", account_onboarding: {configurations: ["merchant"], refresh_url,
  return_url, collection_options: {fields: "eventually_due"}}}}` → `{url, expires_at}` (about 10 minutes, single use).
  Reaching `return_url` proves nothing: retrieve the account. Hosted onboarding can't run in an embedded web view
  (SFSafariViewController / Custom Tabs / the browser are fine).
- **Can it take payments**: a v2 Account id works on v1 endpoints: `GET /v1/accounts/{id}` → `charges_enabled`,
  `payouts_enabled`, `details_submitted`, `requirements.currently_due`, `requirements.disabled_reason`.
- **Express dashboard link** for the host: `POST /v1/accounts/{id}/login_links` → single-use `url`.
- **Checkout** (v1, form-encoded, bracket notation): `POST /v1/checkout/sessions` with `Stripe-Account`:
  `mode=payment`, `line_items[0][price_data][currency]`, `[unit_amount]`, `[product_data][name]`,
  `line_items[0][quantity]=1`, `success_url` (may contain `{CHECKOUT_SESSION_ID}`), `cancel_url`,
  `client_reference_id` (≤ 200), `customer_email`, `metadata[...]` and `payment_intent_data[metadata][...]` (set both:
  not documented as copied), `payment_intent_data[application_fee_amount]` (only when > 0),
  `payment_intent_data[statement_descriptor_suffix]` (≤ 22), `expires_at` (30 minutes to 24 hours from creation),
  `origin_context=mobile_app` (optional, from the apps). `POST /v1/checkout/sessions/{id}/expire` closes an open one.
  Minimum charge $0.50 USD. Apple Pay and Google Pay need nothing extra on the hosted page; for direct charges the
  wallets shown follow the connected account's payment method configuration.
- **Refund**: `POST /v1/refunds` with `Stripe-Account`, `payment_intent=pi_…`, optional `amount`,
  `reason=requested_by_customer`, `refund_application_fee=true` (when a fee was taken). A refund the host's balance
  can't cover stays `pending` and fails after 45 days.
- **Webhooks**: one endpoint with scope **Connected accounts** (Workbench: "Events from: Connected accounts"; API
  `connect=true`). Events carry top-level `account: "acct_…"` and `livemode`. Listen to `checkout.session.completed`
  (fulfil when `payment_status` isn't `unpaid`), `checkout.session.async_payment_succeeded`,
  `checkout.session.async_payment_failed`, `checkout.session.expired`, `charge.refunded`, `refund.failed`,
  `charge.dispute.created`, `account.updated`, `account.application.deauthorized`. Order isn't guaranteed and
  duplicates happen: dedupe on event `id`. Checkout waits up to 10 s for the webhook before redirecting.
- **Signature**: header `Stripe-Signature: t=<unix>,v1=<hex>[,v1=…][,v0=…][,other=…]`. Split on `,` then the first
  `=`; keep `t` and every `v1`, ignore everything else (unknown entries must be accepted). Expected =
  hex(HMAC-SHA256(key = the whole `whsec_…` string, message = `t + "." + raw body bytes`)). Constant-time compare
  against every `v1`; reject when `|now − t|` > 300 s.
- **Versions**: `Stripe-Version: 2026-10-28.endive` (v2 guides also show `2026-10-28.preview`: try `.endive` first,
  confirm in a sandbox). v1 = form-encoded in, JSON out. `Idempotency-Key` header (≤ 255 chars) on POSTs; replays the
  first response for 24 h; the same key with different parameters is an error.
- **Sandboxes** replaced test mode: connected test accounts must be created inside the platform's own sandbox, and a
  sandbox needs its own webhook endpoint. Test card `4242424242424242`; onboarding test values: SMS `000-000`, DOB
  `1901-01-01`, address `address_full_match`, SSN last four `0000`.

## Why the league's cut is a tally

A direct charge can't be split to a second connected account. The only route is taking the cut as an application
fee and transferring it on from Table 1's balance (float needed, refunds don't pull it back, "transfers only for
permitted use cases"). John picked the tally: the whole entry goes to the host and the app tracks what hosts owe the
league (2026-11-13).

## From the apps

Stripe documents hosted Checkout from an app only through the system browser, with a universal link as
`success_url` and a real fallback page there. Nothing in the docs allows or forbids an in-app browser tab; a redirect
inside SFSafariViewController usually doesn't fire a universal link without a tap. So: open Checkout in an
ASWebAuthenticationSession (iOS) / Custom Tab (Android) with `success_url` on table-1.site (`/pay/done?...`, a real
page that says "Paid" and offers Back to the app via `table1://event/<id>`), and never trust the return: the event
page re-reads the payment state, which the webhook sets. Not confirmed on a device: Apple Pay inside the in-app tab.

## John's setup (also in SETUP.md)

1. Create and activate the Stripe account; turn on Connect; platform profile with Stripe-hosted onboarding and the
   Express dashboard; branding.
2. In a sandbox first: a secret key (restricted: Connect accounts, account links, Checkout Sessions, refunds; read
   on charges) → `supabase secrets set STRIPE_SECRET_KEY=…`.
3. An event destination / webhook endpoint, events from Connected accounts, URL
   `https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/payments/webhook`, the events listed above → its `whsec_…`
   → `supabase secrets set STRIPE_WEBHOOK_SECRET=…`.
4. If `POST /v2/core/accounts` is refused, the dashboard may need Accounts v2 (or v1 support) switched on.
5. Later, the same two secrets with live values.
