// Every network call in a tick ends before the tick's deadline, so the edge's 150 s wall clock never cuts one off
// (bug #16: a page fetch started near the end, or TopDeck's 429 backoff, ran on past it). Pure; deadline.test.ts.

/** How long a call may run: its own cap, cut to what is left before the deadline. Too little left: don't start one. */
export function callTimeout(deadline: number, cap: number, now = Date.now(), min = 1_000): number {
  const left = deadline - now;
  if (left < min) throw new Error("out of time");
  return Math.min(cap, left);
}

interface RetryOpts {
  deadline: number;
  cap: number;
  /** Wait before each try (0 for the first); TopDeck rate-limits bursts with 429s. */
  waits: number[];
  jitter?: number;
  min?: number;
  fetchFn?: (url: string, init: RequestInit) => Promise<Response>;
  sleepFn?: (ms: number) => Promise<unknown>;
}

/** fetch, trying again after a 429 while the wait and another call still fit before the deadline. Returns the last answer. */
export async function fetchRetrying(url: string, init: RequestInit, o: RetryOpts): Promise<Response> {
  const fetchFn = o.fetchFn ?? fetch;
  const sleepFn = o.sleepFn ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));
  const min = o.min ?? 1_000;
  let res: Response | null = null;
  for (const wait of o.waits) {
    if (wait) {
      const w = wait + Math.random() * (o.jitter ?? 2_000);
      if (res && Date.now() + w + min * 5 > o.deadline) break;
      await sleepFn(w);
    }
    res = await fetchFn(url, { ...init, signal: AbortSignal.timeout(callTimeout(o.deadline, o.cap, Date.now(), min)) });
    if (res.status !== 429) return res;
    await res.body?.cancel();
  }
  return res!;
}
