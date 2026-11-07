import { useCallback, useSyncExternalStore } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";

/* A person is a way to their profile (contract/friends-sharing-2026-10-18.md § Tapping a person). Wherever a player or
   another account is drawn with an account behind it, a tap opens /u/<id>, where Add friend is. Guests (no account)
   and signed-out visitors (the /s standings page) get nothing to tap. A row whose own tap does something else keeps it;
   there only the avatar opens the profile. */

/** Whose profile a tap opens: null for a guest or an empty id. */
export function personTarget(userId?: string | null): string | null {
  const id = userId?.trim();
  return id ? id.toLowerCase() : null;
}

/** The demos (`?demo`, `/dev/…`) are signed out and open the demo profile. */
export function profilePath(userId: string, demo = false): string {
  return `/u/${encodeURIComponent(userId)}${demo ? "?demo" : ""}`;
}

export function isDemoLocation(pathname: string, search: string): boolean {
  return pathname.startsWith("/dev/") || new URLSearchParams(search).has("demo");
}

let signedIn = false;
const listeners = new Set<() => void>();
let started = false;
function start() {
  if (started) return;
  started = true;
  const set = (v: boolean) => {
    if (v === signedIn) return;
    signedIn = v;
    listeners.forEach((l) => l());
  };
  void supabase.auth.getSession().then(({ data }) => set(!!data.session));
  supabase.auth.onAuthStateChange((_e, s) => set(!!s));
}
function subscribe(l: () => void) {
  start();
  listeners.add(l);
  return () => listeners.delete(l);
}

/** Signed in, kept current: one auth listener for every person on screen. */
export function useSignedIn(): boolean {
  return useSyncExternalStore(subscribe, () => signedIn, () => false);
}

/** `open(userId)` gives the tap that opens their profile, or undefined when there's nothing to open. */
export function useOpenProfile(from: string): (userId?: string | null) => (() => void) | undefined {
  const navigate = useNavigate();
  const { pathname, search } = useLocation();
  const demo = isDemoLocation(pathname, search);
  const on = useSignedIn() || demo;
  return useCallback(
    (userId?: string | null) => {
      const id = personTarget(userId);
      if (!id || !on) return undefined;
      return () => {
        capture("person_tapped", { from });
        navigate(profilePath(id, demo));
      };
    },
    [navigate, on, demo, from],
  );
}
