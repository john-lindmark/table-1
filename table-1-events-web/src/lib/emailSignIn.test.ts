import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { pendingAfterSend, restorePending, sendOutcome, sendOutcomeOf } from "./emailSignIn";

/* A refused email send and the kept code step (contract/email-sign-in-2026-10-15.md § Already sent) against
   testdata/email-sign-in/cases.json (also iOS EmailSignInTests and Android EmailSignInTest). */

interface Cases {
  send: { name: string; status: number; code: string; message: string; outcome: string; wait: number }[];
  restore: { name: string; email: string; sent_at: number; resend_at: number; now: number; restored: boolean; resend_at_out: number }[];
}

const cases: Cases = JSON.parse(readFileSync(new URL("../../../testdata/email-sign-in/cases.json", import.meta.url), "utf8"));

describe("email sign-in", () => {
  it.each(cases.send)("send: $name", (c) => {
    const out = sendOutcome(c.status, c.code, c.message);
    expect(out.kind).toBe(c.outcome);
    if (out.kind === "already_sent") expect(out.wait).toBe(c.wait);
  });

  it.each(cases.restore)("restore: $name", (c) => {
    const out = restorePending({ email: c.email, sentAt: c.sent_at * 1000, resendAt: c.resend_at * 1000 }, c.now * 1000);
    expect(out !== null).toBe(c.restored);
    if (out) expect(out.resendAt).toBe(c.resend_at_out * 1000);
  });

  it("reads supabase-js's AuthApiError", () => {
    const err = Object.assign(new Error("For security purposes, you can only request this after 19 seconds."), {
      status: 429,
      code: "over_email_send_rate_limit",
    });
    expect(sendOutcomeOf(err)).toEqual({ kind: "already_sent", wait: 19 });
    expect(sendOutcomeOf(new TypeError("Failed to fetch"))).toEqual({ kind: "failed" });
  });

  it("an already-sent restores with the countdown it was given", () => {
    const p = pendingAfterSend("a@b.co", 5_000_000, 19);
    expect(p.resendAt).toBe(5_019_000);
    expect(restorePending(p, 5_005_000)?.resendAt).toBe(p.resendAt);
  });
});
