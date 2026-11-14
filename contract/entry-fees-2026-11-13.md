# Entry fees and prizes (2026-11-13)

Phase 3 of `table-1-context/docs/plan-public-events-leagues-2026-11-13.md`; Stripe facts in
`table-1-context/docs/stripe-connect-notes-2026-11-13.md`. Server: migration `20261113160000_entry_fees.sql`, edge
function `payments` (`stripe.ts` + tests). Tests `supabase/tests/73e_entry_fees_test.sql`. Shared client cases in
`testdata/leagues/cases.json`.

John's picks (2026-11-13): pay in the app or at the door, the host's choice per event; in the app means Stripe's
hosted checkout page; the host is the seller on their own Stripe account and Table 1 never holds money; the app works
out prizes and the host pays them; a league's cut of each entry is a tally of what hosts owe the league.

## 1. A host's Stripe account

The `payments` function (signed in; `supabase.functions.invoke("payments", {body})`):
- `{action: "connect_start"} → {url}`: Stripe's own onboarding for you (your account is made on the first call).
  Open it in the system's in-app browser tab (iOS `ASWebAuthenticationSession` or `SFSafariViewController`, Android
  a Custom Tab, the web a new tab): never an embedded web view. It comes back to `table-1.site/pay/connected`.
- `{action: "connect_status"} → {connected, ready, payouts, details_submitted, disabled_reason}`: asks Stripe now.
- `{action: "connect_dashboard"} → {url}`: where you sign in to your own Stripe dashboard (hosts have a full Stripe
  account of their own).
- 503 `{error: "Payments aren't set up yet"}` until Table 1's own Stripe keys are in place: show that line.

`payments_account() → {connected, ready, payouts, details_submitted, disabled_reason}` reads the last known state
without asking Stripe.

Clients: **Account → Payments** (a row after Sharing): `NOT CONNECTED` / `FINISH SETTING UP` / `READY` (accent).
Connect Stripe (or Finish setting up) opens onboarding; coming back to the app or page calls `connect_status`.
Ready: Open Stripe dashboard, and one line "Entry fees go straight to your Stripe account." Telemetry
`stripe_connect_started`, `stripe_connect_status {ready}`.

## 2. An event's fee

`event_fee_set(p_event_id, p_fee jsonb | null) → {fee}` (organizers; null removes it). Keys, each optional after the
first set: `amount_cents` (50–100000, or 0 for a free event with prizes), `pay_mode` (`door` | `app` | `either`),
`refund_hours` (a player's own full refund until this many hours before the start; null = ask the organizer),
`host_keep {kind: none | flat | percent, value}`, `added_cents` (prize money from outside the entries), `payout`
(`[{through, percent}]`: each place up to `through` takes `percent` of the pool; the total can't pass 100). 55000
"Connect Stripe before taking payments in the app" for `app` / `either` without a ready account; 22023 for a bad
value, for changing the amount once entries are paid, and for removing a fee with paid entries. USD only.

`event_money(p_event_id, p_token?)` for anyone who can open the event → `{fee: null}` with no fee, else
`{fee {amount_cents, currency, pay_mode, refund_hours, host_keep {kind, value}, added_cents, payout,
league_cut_cents}, app_ready, pool {entries, gross_cents, league_cut_cents, host_keep_cents, added_cents, pool_cents},
me, prizes, organizer}`.
- `fee.league_cut_cents`: what each paid entry owes the event's league (the season's cut; 0 outside a league and
  for a season's final).
- `pool`: paid entries (door and app; comps pay nothing) less the league's cut and the host's share (flat: that
  amount; percent: of what's left after the league), plus added money.
- `me` (signed-in players): `{participant_id, status: unpaid | pending | paid | refunded, method: app | door | comp |
  null, amount_cents, can_pay, can_refund}`.
- `prizes` (once final places are in): `[{participant_id, user_id, name, place, amount_cents, custom, paid,
  paid_how}]`, amounts over 0. A team's prize is split evenly among its members.
- `organizer` (organizers): `{stripe {connected, ready}, players [{participant_id, user_id, name, status, method,
  amount_cents}], unpaid}`.

Clients:
- Setup → Details → **Entry fee** (`fee_line`: `NONE`, or `$25 · APP OR DOOR`) opens the fee: Amount; How players
  pay (At the door | In the app | Either; the app choices show Connect Stripe when you aren't ready); Refunds
  (Until 48 h before | 24 h before | Until it starts | Ask me); You keep (Nothing | an amount | a percent); Added
  prize money; Prizes (`payout_presets`: Winner takes all | Top 2 | Top 4 | Top 8 | Custom brackets, with
  `payout_words` under it); "$7 an entry goes to <league>" when in a league; Remove fee.
- The event page (everyone): the fee on the data line (`fee_line`), and a **Prize pool** row (`$162`) opening the
  breakdown: entries, to the league, to the host, added, the pool, and each place's prize at the pool as it stands.

## 3. Paying

`{action: "checkout", event_id, origin: ios | android | web} → {url}`: Stripe's hosted checkout for your entry (you
must be signed up; an open checkout is handed back, not doubled). Open the URL the same way as onboarding. Stripe
returns to `table-1.site/pay/done?e=<event>&s=<session>` (or `&cancelled=1`). **The return proves nothing**: the
payment counts when Stripe's webhook says so, so after any return, and when the app comes back to the front, re-read
`event_money` (every 2 s for up to 20 s while `me.status` is `pending`).

`{action: "refund", event_id, participant_id?} → {refunded, amount_cents}`: your own app payment while
`me.can_refund`, or any app payment when you run the event.

Clients, a player who is signed up to an event with a fee:
- `unpaid` with `can_pay`: big action **Pay $25**; pay mode `either` adds "or pay at the door". Door only:
  "$25 at the door".
- `pending`: "Finishing your payment…" with Pay again.
- `paid`: `PAID` in accent (`PAID AT THE DOOR`, `COMP`); with `can_refund`, **Refund and leave** (a confirm, then
  `refund`, then `event_leave`).
- `refunded`: `REFUNDED`, and Pay again when `can_pay`.
- Telemetry `pay_started {origin}`, `pay_returned {status}`, `refund_asked {by: player | organizer}`.

Web pages (browser only, never claimed by the apps): `/pay/done` (reads `event_money` for `e`, says Paid / Not paid
yet / Cancelled, with Back to the event; on a phone that link opens the app), `/pay/connected` and `/pay/connect`
(Stripe's return and refresh addresses: "Back to Table 1", and Connect again when signed in on the web).

## 4. The organizer's side

- `event_payment_mark(p_event_id, p_participant_id, p_state: door | comp | unpaid) → that player's payment`.
  Payments made in the app change only by a refund (22023).
- `event_prizes_set(p_event_id, p_rows [{participant_id, amount_cents}] | null) → {total_cents, pool_cents}`: an
  agreed split or any change; null goes back to the table; the total can't pass the pool (22023); needs final places.
- `event_prize_mark(p_event_id, p_participant_id, p_paid, p_how?) → {participant_id, paid}`. `p_how` is one of
  `cash`, `store credit`, `other` (shown `PAID · CASH`, `PAID · STORE CREDIT`, plain `PAID` for other).
- Every payment, fee and prize change pings `event:<id>`: re-read `event_money` wherever the event is re-read.

Clients:
- Players lists (Setup, Live): a payment tag per player (`pay_tag`: `PAID · APP`, `PAID · DOOR`, `COMP`, `UNPAID`,
  `PENDING`, `REFUNDED`), the header `4 UNPAID`, and in the row menu Paid at the door, Comp, Unpaid, Refund (app
  payments, with a confirm). Pairing round 1 with unpaid players asks first: "4 players haven't paid. Pair anyway?"
- Results → **Prizes**: the pool, then each place with its amount and `PAID · CASH` or a Mark paid menu (Cash |
  Store credit | Other); **Split** edits the amounts with the running total against the pool; Back to the table.
- Telemetry `fee_saved {pay_mode, amount}`, `payment_marked {state}`, `prizes_split`, `prize_marked {how}`.

## 5. A league's cut

A season's `entry_cut_cents` (`league_season_set` key; 0–100000) is what each paid entry of its events owes the
league (MMS: $7). Nothing moves: hosts hand it over themselves and the league marks it.

- `league_money(p_season_id) → {entry_cut_cents, pool_cents, received_cents, events}` (signed out too): everyone
  gets the cut and the pool; the league's organizers also get `received_cents` and `events [{event_id, name, entries,
  owed_cents, received_cents}]`.
- `league_due_mark(p_event_id, p_received_cents)` (the league's organizers).

Clients: the league page shows **Prize pool $1,400** under the season when the cut is over 0; the season editor has
Cut per entry; organizers get **Dues** in the tools (each event: owed, received, Mark received). Telemetry
`dues_marked`.
