import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { packBody, type PartCall } from "./pack.ts";

// A catalog of 23 oracles: an O and two P lines per card, N lines only for even ones (so some windows have none),
// each window joined in idx order like catalog_pack_part.
const ORACLES = 23;
const lines = (kind: number, from: number, to: number) => {
  const out: string[] = [];
  for (let i = from; i < Math.min(to, ORACLES); i++) {
    if (kind === 0) out.push(`O\t${i}`);
    else if (kind === 1) out.push(`P\ta${i}`, `P\tb${i}`);
    else if (i % 2 === 0) out.push(`N\t${i}`);
  }
  return out.length ? out.join("\n") : null;
};
const whole = [0, 1, 2].map((k) => lines(k, 0, ORACLES)).join("\n");
const timeout = () => Promise.reject(new Error("catalog_pack_part: canceling statement due to statement timeout"));

Deno.test("packBody joins the windows' parts in order", async () => {
  assertEquals(await packBody((k, f, t) => Promise.resolve(lines(k, f, t)), 5), whole);
});

// Bug #21 (2026-10-28): the night every oracle was rewritten, a cold P-line part ran past the 8s statement timeout
// and the run failed without a pack. A part that times out is now built in halves.
Deno.test("packBody splits a window that times out and builds the same body", async () => {
  const calls: string[] = [];
  const call: PartCall = (k, f, t) => {
    if (k === 1) calls.push(`${f}-${t}`);
    return k === 1 && f === 20 && t - f > 5 ? timeout() : Promise.resolve(lines(k, f, t));
  };
  assertEquals(await packBody(call, 10, 1), whole);
  assertEquals(calls, ["0-10", "10-20", "20-30", "20-25", "25-30"]);
});

Deno.test("packBody splits an N-line window whose halves may be empty", async () => {
  const call: PartCall = (k, f, t) => (k === 2 && t - f > 1 ? timeout() : Promise.resolve(lines(k, f, t)));
  assertEquals(await packBody(call, 10, 1), whole);
});

Deno.test("packBody gives up at the smallest window and passes other errors through", async () => {
  const slow: PartCall = (k, f, t) => (k === 1 ? timeout() : Promise.resolve(lines(k, f, t)));
  await assertRejects(() => packBody(slow, 10, 3), Error, "statement timeout");
  let p = 0;
  const broken: PartCall = (k, f, t) => {
    if (k !== 1) return Promise.resolve(lines(k, f, t));
    p++;
    return Promise.reject(new Error("catalog_pack_part: permission denied"));
  };
  await assertRejects(() => packBody(broken, 10, 1), Error, "permission denied");
  assertEquals(p, 1); // not split
});
