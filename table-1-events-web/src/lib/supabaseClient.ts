import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!url || !anonKey) {
  throw new Error(
    "Missing VITE_SUPABASE_URL or VITE_SUPABASE_ANON_KEY — copy .env.example to .env and fill them in.",
  );
}

/** Every request fails after 25 s without an answer (uploads, which carry a Blob or FormData, after 120 s), so a
 *  dead connection shows the saved screen or the error instead of "Loading…" for good (contract/offline-2026-10-31.md § 2). */
function fetchWithTimeout(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
  const upload = init?.body instanceof Blob || init?.body instanceof FormData;
  const limit = AbortSignal.timeout(upload ? 120_000 : 25_000);
  const signal = init?.signal && "any" in AbortSignal ? AbortSignal.any([init.signal, limit]) : init?.signal ?? limit;
  return fetch(input, { ...init, signal });
}

export const supabase = createClient(url, anonKey, {
  auth: { persistSession: true, autoRefreshToken: true },
  global: { fetch: fetchWithTimeout },
});
