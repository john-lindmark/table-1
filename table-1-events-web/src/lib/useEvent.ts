import { useCallback, useEffect, useRef, useState } from "react";
import { fetchBundle, subscribeToEvent, type EventBundle } from "./api";
import type { SyncStatus } from "./types";

/**
 * Loads an event, keeps it live, and applies mutations optimistically.
 *
 * The sequence number matters: at a table several people tap at once, and
 * without it an earlier server response can land after a later one and stomp
 * the newer state. A failed call reverts to the snapshot taken before it.
 */
export function useEvent(eventId: string | null) {
  const [bundle, setBundle] = useState<EventBundle | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [sync, setSync] = useState<SyncStatus>("saved");

  const bundleRef = useRef<EventBundle | null>(null);
  bundleRef.current = bundle;
  const seq = useRef(0);

  const refetch = useCallback(async () => {
    if (!eventId) return;
    try {
      const next = await fetchBundle(eventId);
      // Ignore a refetch that lands while a mutation is still in flight.
      if (seq.current === 0) {
        setBundle(next);
        setError(null);
      } else {
        setBundle(next);
      }
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      if (!bundleRef.current) setError(message);
      setSync("error");
    }
  }, [eventId]);

  useEffect(() => {
    setBundle(null);
    setError(null);
    refetch();
  }, [refetch]);

  useEffect(() => {
    if (!eventId) return;
    const unsubscribe = subscribeToEvent(eventId, refetch);
    const poll = window.setInterval(refetch, 20000);
    return () => {
      unsubscribe();
      window.clearInterval(poll);
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

  return { bundle, error, sync, refetch, mutate, setError };
}
