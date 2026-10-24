// What a refused email send means, and the code step kept across leaving the page
// (contract/email-sign-in-2026-10-15.md § Already sent; cases testdata/email-sign-in/cases.json).

export type SendOutcome =
  /** A code went out moments ago (Supabase's minute per address): show the code step, resend in `wait` s. */
  | { kind: "already_sent"; wait: number }
  /** The project's hourly cap or this network's request limit: no code is on its way. */
  | { kind: "too_many" }
  | { kind: "failed" };

/** A code lives an hour; Supabase sends at most one a minute per address. */
export const CODE_LIFE_MS = 3600_000;
export const RESEND_GAP_MS = 60_000;

export function sendOutcome(status: number | undefined, code: string | undefined, message: string): SendOutcome {
  const limited = code === "over_email_send_rate_limit" || code === "over_request_rate_limit" || status === 429;
  if (!limited) return { kind: "failed" };
  const m = code === "over_request_rate_limit" ? null : /after (\d+) seconds?/.exec(message);
  if (m) return { kind: "already_sent", wait: Math.min(Math.max(Number(m[1]), 1), 60) };
  return { kind: "too_many" };
}

/** supabase-js's AuthApiError carries status, code and message. */
export function sendOutcomeOf(e: unknown): SendOutcome {
  const err = e as { status?: number; code?: string; message?: string } | null;
  return sendOutcome(err?.status, err?.code, err?.message ?? "");
}

export interface Pending {
  email: string;
  sentAt: number;
  resendAt: number;
}

/** The saved code step if its code can still be used at `now`, with Resend never before send + 60 s. */
export function restorePending(saved: Pending | null, now: number): Pending | null {
  if (!saved || !saved.email) return null;
  const age = now - saved.sentAt;
  if (age < 0 || age >= CODE_LIFE_MS) return null;
  return { ...saved, resendAt: Math.max(saved.resendAt, saved.sentAt + RESEND_GAP_MS) };
}

/** After a send, or an already-sent whose code went out `60 - wait` seconds ago. */
export function pendingAfterSend(email: string, now: number, wait?: number): Pending {
  const resendAt = now + (wait ?? 60) * 1000;
  return { email, sentAt: resendAt - RESEND_GAP_MS, resendAt };
}

const KEY = "t1.signin.pending";

export function savePending(p: Pending) {
  try {
    localStorage.setItem(KEY, JSON.stringify(p));
  } catch {
    /* private mode: the code step lives as long as the page */
  }
}

export function loadPending(now = Date.now()): Pending | null {
  let saved: Pending | null = null;
  try {
    const raw = localStorage.getItem(KEY);
    saved = raw ? (JSON.parse(raw) as Pending) : null;
  } catch {
    saved = null;
  }
  const p = restorePending(saved, now);
  if (!p) clearPending();
  return p;
}

export function clearPending() {
  try {
    localStorage.removeItem(KEY);
  } catch {
    /* nothing kept */
  }
}
