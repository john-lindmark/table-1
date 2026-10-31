// Offline rules shared with iOS and Android (contract/offline-2026-10-31.md, cases testdata/offline/cases.json): how
// long ago a saved answer is, what a screen says when a call fails, which failed collection batches wait in the
// outbox, and the per-account store of the last answers (IndexedDB) the Events tab, an event and Insights open on
// when the server can't be reached.

/** "just now", "3 min ago", "2 h ago", "1 day ago". */
export function ago(seconds: number): string {
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} h ago`;
  const days = Math.floor(seconds / 86400);
  return days === 1 ? "1 day ago" : `${days} days ago`;
}

/** What a screen says after its call fails: nothing when it didn't; the saved answer's age as a plain notice when
 *  there is one; else the error itself. */
export function offlineNotice(failed: boolean, savedAgo: number | null, error: string | null | undefined): { text: string; isError: boolean } | null {
  if (!failed) return null;
  if (savedAgo != null) return { text: `Couldn't refresh · last updated ${ago(savedAgo)}`, isError: false };
  const e = (error ?? "").trim();
  return { text: e || "Couldn't load. Check your connection.", isError: true };
}

/** Seconds since `at` (ms), for `offlineNotice`. */
export const ageOf = (at: number | null | undefined, now = Date.now()) => (at ? Math.max(0, Math.floor((now - at) / 1000)) : null);

/** A failure to reach the server (offline, timed out, connection dropped), as opposed to its answer. supabase-js
 *  folds a rejected fetch into its error's message. */
export function isNetworkError(e: unknown): boolean {
  if (typeof navigator !== "undefined" && navigator.onLine === false) return true;
  const o = e as { message?: unknown; code?: unknown; name?: unknown } | null;
  const code = typeof o?.code === "string" ? o.code : "";
  if (code.startsWith("PGRST") || /^\d{5}$/.test(code)) return false; // PostgREST or Postgres answered
  const name = typeof o?.name === "string" ? o.name : "";
  if (name === "AbortError" || name === "TimeoutError") return true;
  const m = typeof o?.message === "string" ? o.message : e instanceof Error ? e.message : String(e ?? "");
  return /failed to fetch|networkerror|network request failed|load failed|timed out|timeouterror|aborterror|fetch failed|network error|err_internet|ECONNREFUSED/i.test(m);
}

/** A failed collection_apply batch waits in the outbox when the failure was the network and every op only adds. */
export function queues(ops: { delta?: number; qty?: number }[], network: boolean): boolean {
  return network && ops.length > 0 && ops.every((op) => (op.delta ?? 0) > 0 && op.qty == null);
}

/** The copies the outbox will add per item key, so a sync row shows the server's count plus them. */
export function outboxDeltas(batches: { card_id: string; finish?: string; condition?: string; lang?: string; delta?: number }[][]): Map<string, number> {
  const out = new Map<string, number>();
  for (const ops of batches) {
    for (const op of ops) {
      const k = `${op.card_id}|${op.finish ?? "nonfoil"}|${op.condition ?? "NM"}|${op.lang ?? "en"}`;
      out.set(k, (out.get(k) ?? 0) + (op.delta ?? 0));
    }
  }
  for (const [k, v] of out) if (v === 0) out.delete(k);
  return out;
}

/* ── the saved answers ──────────────────────────────────────────────── */

export interface Saved<T> { value: T; at: number }

function openOffline(userId: string): Promise<IDBDatabase | null> {
  return new Promise((resolve) => {
    try {
      const req = indexedDB.open(`table1-offline-${userId}`, 1);
      req.onupgradeneeded = () => req.result.createObjectStore("answers");
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => resolve(null);
    } catch {
      resolve(null);
    }
  });
}

/** The last answer kept under `key` for this account, with when it was fetched (ms). */
export async function loadSaved<T>(userId: string | null, key: string): Promise<Saved<T> | null> {
  if (!userId) return null;
  const db = await openOffline(userId);
  if (!db) return null;
  return new Promise((resolve) => {
    try {
      const req = db.transaction("answers").objectStore("answers").get(key);
      req.onsuccess = () => { resolve((req.result as Saved<T>) ?? null); db.close(); };
      req.onerror = () => { resolve(null); db.close(); };
    } catch {
      resolve(null);
    }
  });
}

/** Keeps an answer as it came off the wire (plain JSON) for the next time the server can't be reached. */
export async function saveAnswer<T>(userId: string | null, key: string, value: T): Promise<void> {
  if (!userId) return;
  const db = await openOffline(userId);
  if (!db) return;
  try {
    const tx = db.transaction("answers", "readwrite");
    tx.objectStore("answers").put({ value, at: Date.now() } satisfies Saved<T>, key);
    tx.oncomplete = () => db.close();
    tx.onerror = () => db.close();
  } catch { /* private window */ }
}
