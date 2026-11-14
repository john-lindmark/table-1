import { describe, expect, it } from "vitest";
import { keepEnabled, paymentsEnabled, type StripeAccount } from "./money";
import { paymentsAccount as demoAccount, payments as demoPayments } from "./phasesDemo";

// contract/entry-fees-2026-11-13.md § 1 "Hidden for now": nothing an organizer could act on shows (Account →
// Payments, Entry fee, Cut per entry, Dues) unless payments_account said `enabled: true`.
const base: StripeAccount = { connected: true, ready: true, payouts: true, details_submitted: true, disabled_reason: null };

describe("payments hidden for now", () => {
  it("is off by default: a failed call, or an answer without `enabled`", () => {
    expect(paymentsEnabled(null)).toBe(false);
    expect(paymentsEnabled(undefined)).toBe(false);
    expect(paymentsEnabled(base)).toBe(false);                       // an older server: no `enabled`
    expect(paymentsEnabled({ ...base, enabled: false })).toBe(false);
    // Only a true boolean opens it, never something truthy off the wire.
    expect(paymentsEnabled({ enabled: "true" as unknown as boolean })).toBe(false);
    expect(paymentsEnabled({ enabled: 1 as unknown as boolean })).toBe(false);
  });

  it("is on only when the server says enabled, whatever the Stripe state", () => {
    expect(paymentsEnabled({ ...base, enabled: true })).toBe(true);
    const fresh: StripeAccount = { ...base, connected: false, ready: false, enabled: true };
    expect(paymentsEnabled(fresh)).toBe(true);
  });

  it("an answer from Stripe's status call keeps what payments_account said", () => {
    expect(paymentsEnabled(keepEnabled(base, { enabled: true }))).toBe(true);
    expect(paymentsEnabled(keepEnabled(base, { enabled: false }))).toBe(false);
    expect(paymentsEnabled(keepEnabled(base, null))).toBe(false);
    expect(paymentsEnabled(keepEnabled({ ...base, enabled: false }, { enabled: true }))).toBe(false);
  });

  it("the ?demo stand-in account has payments open", () => {
    expect(paymentsEnabled(demoAccount())).toBe(true);
    expect(paymentsEnabled(demoPayments({ action: "connect_status" }) as StripeAccount)).toBe(true);
  });
});
