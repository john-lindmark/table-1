import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { reused } from "./reuse.ts";

// A send to many iPhones runs 32 workers at once. Each used to mint its own provider token before the
// first one landed in the cache, and APNs refused most of them (TooManyProviderTokenUpdates): the
// 14–15 Nov broadcasts lost 8–9 of 16 devices while sends to 2 devices always went through.
Deno.test("parallel callers share one token while it is being made", async () => {
  let mints = 0;
  const token = reused(async (now) => {
    mints++;
    await new Promise((r) => setTimeout(r, 5));
    return `jwt-${now}-${mints}`;
  }, 45 * 60, () => 1000);
  const got = await Promise.all(Array.from({ length: 32 }, () => token()));
  assertEquals(mints, 1);
  assertEquals(new Set(got).size, 1);
});

Deno.test("the token is made again once it is old", async () => {
  let now = 1000, mints = 0;
  const token = reused(async (t) => { mints++; return `jwt-${t}`; }, 45 * 60, () => now);
  assertEquals(await token(), "jwt-1000");
  now += 45 * 60 - 1;
  assertEquals(await token(), "jwt-1000");
  now += 1;
  assertEquals(await token(), `jwt-${1000 + 45 * 60}`);
  assertEquals(mints, 2);
});

Deno.test("a failed mint isn't kept", async () => {
  let mints = 0;
  const token = reused(async () => {
    mints++;
    if (mints === 1) throw new Error("no key");
    return "jwt";
  }, 45 * 60, () => 1000);
  await assertRejects(() => token(), Error, "no key");
  assertEquals(await token(), "jwt");
  assertEquals(mints, 2);
});
