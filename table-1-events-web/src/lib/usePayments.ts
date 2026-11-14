// Whether payments are open to the signed-in account (contract/entry-fees-2026-11-13.md § 1 "Hidden for now").
// `payments_account` is read once per signed-in session and shared by every gate (Account → Payments, Setup →
// Details → Entry fee, the season editor's Cut per entry, the league's Dues tool); Account asks again when it opens.
// Until the answer is in, and when it's false, missing or the call failed, the gates stay shut.
import { useCallback, useEffect, useState } from "react";
import { isLibraryDemo } from "./libraryDemo";
import { paymentsAccount, paymentsEnabled, type StripeAccount } from "./money";
import { supabase } from "./supabaseClient";

/** One session's answer: `key` is the account id ("demo" on stand-in data), `value` undefined until it's in. */
interface Held { key: string; value?: StripeAccount | null; pending?: Promise<void> }
let held: Held | null = null;
const listeners = new Set<() => void>();
const tell = () => listeners.forEach((f) => f());

async function sessionKey(): Promise<string | null> {
  if (import.meta.env.DEV && isLibraryDemo()) return "demo";
  try {
    return (await supabase.auth.getSession()).data.session?.user.id ?? null;
  } catch {
    return null;
  }
}

/** Reads the account for the current session unless it's already held (or `again`). Signed out holds nothing. */
async function load(again: boolean): Promise<void> {
  const key = await sessionKey();
  if (!key) {
    if (held) { held = null; tell(); }
    return;
  }
  if (held?.key === key && !again && (held.value !== undefined || held.pending)) return held.pending;
  const mine: Held = { key, value: held?.key === key ? held.value : undefined };
  mine.pending = paymentsAccount().then((a) => {
    if (held !== mine) return;
    mine.value = a;
    mine.pending = undefined;
    tell();
  });
  held = mine;
  if (mine.value === undefined) tell();
  return mine.pending;
}

/** The session's Stripe account as `payments_account` last said (null: not in yet, signed out, or a failed read),
 *  and `set` for a newer answer (the Payments screen after asking Stripe). `refetch` asks again on mount. */
export function usePaymentsAccount(refetch = false): { account: StripeAccount | null; set: (a: StripeAccount) => void } {
  const [, bump] = useState(0);
  useEffect(() => {
    const on = () => bump((n) => n + 1);
    listeners.add(on);
    void load(refetch);
    // Another account signed in, or signed out: the answer belongs to the session.
    const { data: sub } = supabase.auth.onAuthStateChange(() => void load(false));
    return () => {
      listeners.delete(on);
      sub.subscription.unsubscribe();
    };
  }, [refetch]);
  const set = useCallback((a: StripeAccount) => {
    if (!held) return;
    held.value = a;
    tell();
  }, []);
  return { account: held?.value ?? null, set };
}

/** The gate: true only once `payments_account` said `enabled: true` for this session. */
export const usePaymentsEnabled = (): boolean => paymentsEnabled(usePaymentsAccount().account);
