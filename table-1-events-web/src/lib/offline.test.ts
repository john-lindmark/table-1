import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { ago, isNetworkError, offlineNotice, outboxDeltas, queues } from "./offline";

/* Offline rules (contract/offline-2026-10-31.md), shared with iOS OfflineTests and Android OfflineTest. */
const cases = JSON.parse(readFileSync(new URL("../../../testdata/offline/cases.json", import.meta.url), "utf8")) as {
  ago: { seconds: number; label: string }[];
  notice: { name: string; failed: boolean; savedAgo: number | null; error: string | null; text: string | null; isError: boolean }[];
  queues: { name: string; ops: { card_id: string; delta?: number; qty?: number }[]; network: boolean; queued: boolean }[];
  deltas: { name: string; batches: { card_id: string; finish?: string; condition?: string; lang?: string; delta?: number }[][]; deltas: Record<string, number> }[];
  shown: { name: string; key: string; serverQty: number; deltas: Record<string, number>; qty: number }[];
};

describe("offline", () => {
  it("says how long ago", () => {
    for (const c of cases.ago) expect(ago(c.seconds), `${c.seconds}`).toBe(c.label);
  });
  it("says what a screen shows after a failed call", () => {
    for (const c of cases.notice) {
      const n = offlineNotice(c.failed, c.savedAgo, c.error);
      expect(n?.text ?? null, c.name).toBe(c.text);
      expect(n?.isError ?? false, c.name).toBe(c.isError);
    }
  });
  it("queues batches of adds that failed on the network", () => {
    for (const c of cases.queues) expect(queues(c.ops, c.network), c.name).toBe(c.queued);
  });
  it("sums queued adds per item and shows them on top of sync rows", () => {
    for (const c of cases.deltas) expect(Object.fromEntries(outboxDeltas(c.batches)), c.name).toEqual(c.deltas);
    for (const c of cases.shown) expect(c.serverQty + (c.deltas[c.key] ?? 0), c.name).toBe(c.qty);
  });
  it("tells network failures from answers", () => {
    expect(isNetworkError({ message: "TypeError: Failed to fetch", code: "" })).toBe(true);
    expect(isNetworkError({ message: "TimeoutError: signal timed out" })).toBe(true);
    expect(isNetworkError(new DOMException("x", "AbortError"))).toBe(true);
    expect(isNetworkError({ message: "That event isn't available", code: "P0001" })).toBe(false);
    expect(isNetworkError({ message: "permission denied", code: "42501" })).toBe(false);
    expect(isNetworkError({ message: "Could not find the function", code: "PGRST202" })).toBe(false);
  });
});
