import { useCallback, useEffect, useRef, useState } from "react";
import { fetchBundle, savedBundle, subscribeToEvent, type EventBundle } from "./api";
import { ageOf, isNetworkError, offlineNotice } from "./offline";
import { capture } from "./telemetry";
import type { SyncStatus } from "./types";

/**
 * Loads an event, keeps it live, and applies mutations optimistically.
 *
 * The sequence number matters: at a table several people tap at once, and
 * without it an earlier server response can land after a later one and stomp
 * the newer state. A failed call reverts to the snapshot taken before it.
 *
 * The event as this device last saw it shows at once and stays when the server can't be reached, with `stale`
 * saying how old it is (contract/offline-2026-10-31.md § 1); the tab coming back or the browser going online refetches.
 */
export function useEvent(eventId: string | null) {
  const [bundle, setBundle] = useState<EventBundle | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [sync, setSync] = useState<SyncStatus>("saved");
  const [stale, setStale] = useState<string | null>(null);

  const bundleRef = useRef<EventBundle | null>(null);
  bundleRef.current = bundle;
  const seq = useRef(0);
  /** When the bundle on screen was fetched (ms): this visit's, or the device's saved copy. */
  const savedAt = useRef<number | null>(null);

  const refetch = useCallback(async () => {
    if (!eventId) return;
    try {
      const next = await fetchBundle(eventId);
      savedAt.current = Date.now();
      setStale(null);
      // Ignore a refetch that lands while a mutation is still in flight.
      if (seq.current === 0) {
        setBundle(next);
        setError(null);
      } else {
        setBundle(next);
      }
    } catch (e) {
      const message = e instanceof Error ? e.message : String((e as { message?: string })?.message ?? e);
      const age = bundleRef.current ? ageOf(savedAt.current) : null;
      const n = offlineNotice(true, age, message);
      if (n && !n.isError) {
        setStale(n.text);
        if (isNetworkError(e)) capture("offline_shown", { screen: "event", age_s: age ?? 0 });
      } else if (!bundleRef.current) {
        setError(n?.text ?? message);
      }
      setSync("error");
    }
  }, [eventId]);

  useEffect(() => {
    setBundle(null);
    setError(null);
    setStale(null);
    savedAt.current = null;
    let gone = false;
    // What this device last saw first; the server's answer replaces it.
    if (eventId) {
      void savedBundle(eventId).then((s) => {
        if (gone || !s || bundleRef.current) return;
        savedAt.current = s.at;
        bundleRef.current = s.value;
        setBundle(s.value);
      }).finally(() => { if (!gone) void refetch(); });
    }
    return () => { gone = true; };
  }, [eventId, refetch]);

  useEffect(() => {
    if (!eventId) return;
    const unsubscribe = subscribeToEvent(eventId, refetch);
    const poll = window.setInterval(refetch, 20000);
    const back = () => { if (document.visibilityState === "visible") void refetch(); };
    document.addEventListener("visibilitychange", back);
    window.addEventListener("online", back);
    return () => {
      unsubscribe();
      window.clearInterval(poll);
      document.removeEventListener("visibilitychange", back);
      window.removeEventListener("online", back);
    };
  }, [eventId, refetch]);

  const mutate = useCallback(
    async (
      optimistic: (prev: EventBundle) => EventBundle,
      call: () => Promise<unknown>,
    ) => {
      const snapshot = bundleRef.current;
      if (!snapshot) return;
      const next = optimistic(snapshot);
      bundleRef.current = next;
      setBundle(next);
      setSync("saving");
      const mine = ++seq.current;
      try {
        await call();
        if (mine === seq.current) {
          seq.current = 0;
          setSync("saved");
          await refetch();
        }
      } catch (e) {
        if (mine === seq.current) {
          seq.current = 0;
          bundleRef.current = snapshot;
          setBundle(snapshot);
          setSync("error");
          setError(e instanceof Error ? e.message : String(e));
        }
      }
    },
    [refetch],
  );

  return { bundle, error, sync, stale, refetch, mutate, setError };
}
