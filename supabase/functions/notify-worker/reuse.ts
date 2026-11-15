// Tokens the push senders reuse (APNs provider tokens, FCM access tokens). No env reads, so tests can import it.

/**
 * One token at a time: callers that arrive while it is being made wait for that one. Sends run 32 at a
 * time, and the old cache only filled once the first mint finished, so a send to many devices minted a
 * token per worker; APNs refuses a provider token that changes that often (429 TooManyProviderTokenUpdates).
 * A failed mint isn't kept.
 */
export function reused<T>(mint: (now: number) => Promise<T>, ttlSeconds: number, clock = () => Math.floor(Date.now() / 1000)) {
  let cached: { value: Promise<T>; at: number } | null = null;
  return (): Promise<T> => {
    const now = clock();
    if (cached && now - cached.at < ttlSeconds) return cached.value;
    const entry = { value: mint(now), at: now };
    cached = entry;
    entry.value.catch(() => { if (cached === entry) cached = null; });
    return entry.value;
  };
}
