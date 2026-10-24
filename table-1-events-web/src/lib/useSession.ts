import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "./supabaseClient";
import { clearPending } from "./emailSignIn";

/** The signed-in account, kept current across tabs and token refreshes. */
export function useSession() {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => {
      setSession(s);
      // Signed in any way: the email code step kept for a return is done with.
      if (s) clearPending();
    });
    return () => sub.subscription.unsubscribe();
  }, []);
  return { session, ready, userId: session?.user.id ?? null };
}
