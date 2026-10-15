import { useCallback, useEffect, useState } from "react";
import { fetchTrackerMode, saveTrackerMode, errorMessage } from "./api";
import type { TrackerMode } from "./types";
import { useSession } from "./useSession";

// "Track games": where a player keeps score during a match. Stored in user_settings (own row),
// mirrored in memory and localStorage so screens render the right primary action immediately.

const KEY = "table1.trackerMode";
const listeners = new Set<(m: TrackerMode) => void>();
let cached: TrackerMode | null = readLocal();

function readLocal(): TrackerMode | null {
  try {
    const v = localStorage.getItem(KEY);
    return v === "tracker" || v === "elsewhere" ? v : null;
  } catch {
    return null;
  }
}

function publish(mode: TrackerMode) {
  cached = mode;
  try {
    localStorage.setItem(KEY, mode);
  } catch {
    /* storage unavailable */
  }
  listeners.forEach((l) => l(mode));
}

export function useTrackerMode(): {
  mode: TrackerMode;
  setMode: (m: TrackerMode) => Promise<void>;
  error: string | null;
} {
  const { userId } = useSession();
  const [mode, setLocal] = useState<TrackerMode>(cached ?? "elsewhere");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    listeners.add(setLocal);
    return () => {
      listeners.delete(setLocal);
    };
  }, []);

  useEffect(() => {
    if (!userId) return;
    let live = true;
    fetchTrackerMode(userId)
      .then((m) => live && publish(m))
      .catch(() => {
        /* keep the cached value */
      });
    return () => {
      live = false;
    };
  }, [userId]);

  const setMode = useCallback(
    async (next: TrackerMode) => {
      const prev = cached ?? "elsewhere";
      publish(next);
      setError(null);
      if (!userId) return;
      try {
        await saveTrackerMode(userId, next);
      } catch (e) {
        publish(prev);
        setError(errorMessage(e));
      }
    },
    [userId],
  );

  return { mode, setMode, error };
}

/** Auto-open the tracker at most once per match per browser session. */
export function claimAutoOpen(matchId: string): boolean {
  const key = `table1.autoOpened.${matchId}`;
  try {
    if (sessionStorage.getItem(key)) return false;
    sessionStorage.setItem(key, "1");
    return true;
  } catch {
    if (memoryClaims.has(key)) return false;
    memoryClaims.add(key);
    return true;
  }
}
const memoryClaims = new Set<string>();
