// Bug #16: ticks ran past the edge's 150 s wall clock (a page or TopDeck call started late, or 429 backoff, ran on).
import { assert, assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { callTimeout, fetchRetrying } from "./deadline.ts";

Deno.test("a call's timeout is its cap, cut to what is left before the deadline", () => {
  assertEquals(callTimeout(100_000, 60_000, 0), 60_000);
  assertEquals(callTimeout(100_000, 60_000, 70_000), 30_000);
  assertThrows(() => callTimeout(100_000, 60_000, 99_500), Error, "out of time");
});

Deno.test("429 backoff stops when the next wait wouldn't fit before the deadline", async () => {
  let tries = 0, slept = 0;
  const res = await fetchRetrying("https://x", {}, {
    deadline: Date.now() + 18_000, cap: 60_000, waits: [0, 5_000, 15_000, 30_000], jitter: 0,
    fetchFn: () => { tries++; return Promise.resolve(new Response("", { status: 429 })); },
    sleepFn: (ms) => { slept += ms; return Promise.resolve(); },
  });
  assertEquals(res.status, 429);
  assertEquals(tries, 2); // the 15 s wait would end too close to the deadline (the clock doesn't move with fake sleeps)
  assertEquals(slept, 5_000);
});

Deno.test("a call that hangs is cut off at the deadline", async () => {
  const t0 = Date.now();
  await assertRejects(() => fetchRetrying("https://x", {}, {
    deadline: t0 + 300, cap: 60_000, waits: [0], min: 100,
    fetchFn: (_u, init) => new Promise((_, rej) => init.signal!.addEventListener("abort", () => rej(init.signal!.reason))),
  }));
  assert(Date.now() - t0 < 1_000);
});

Deno.test("no time left: no call at all", async () => {
  let tries = 0;
  await assertRejects(() => fetchRetrying("https://x", {}, {
    deadline: Date.now() + 500, cap: 60_000, waits: [0],
    fetchFn: () => { tries++; return Promise.resolve(new Response("ok")); },
  }), Error, "out of time");
  assertEquals(tries, 0);
});
