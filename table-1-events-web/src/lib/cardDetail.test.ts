import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  editOps, freshVersion, mainVersion, orderedVersions, repoint, shared, showsFinish, stepOp, versionId,
  type CardAttribute, type CardVersion, type PrintingFacts,
} from "./cardDetail";
import type { Condition, Finish } from "./collection";
import type { Board } from "./lists";

/* Card detail's rules against testdata/card-detail/cases.json (also iOS CardDetailTests and Android CardDetailTest). */

interface V { card_id: string; finish: Finish; condition?: Condition; lang?: string; board?: Board; qty?: number }
interface Cases {
  printings: { card_id: string; set: string; lang: string; finishes: string; released_at: string; original: boolean }[];
  repoint: { name: string; from: V; attribute: CardAttribute; value: string; to: V }[];
  ops: { name: string; item: V; places: { place: string; qty: number }[]; from?: string; to: V; qty: number;
         ops: { card_id: string; finish: string; condition: string; lang: string; delta: number; binder_id: string | null }[] | null }[];
  views: { name: string; versions: V[]; shared: Record<string, string | null>; main: string; shows_finish: boolean; order: string[] }[];
  fresh: { condition: Condition; lang: string; version: V };
}
const c: Cases = JSON.parse(readFileSync(new URL("../../../testdata/card-detail/cases.json", import.meta.url), "utf8"));

const version = (v: V): CardVersion => ({ cardId: v.card_id, finish: v.finish, condition: v.condition ?? "NM", lang: v.lang ?? "en",
                                          qty: v.qty ?? 0, ...(v.board ? { board: v.board } : {}) });
const printings: PrintingFacts[] = c.printings.map((p, i) => ({
  cardId: p.card_id, lang: p.lang, finishes: p.finishes, released: p.released_at, ord: c.printings.length - i, original: p.original,
}));
const byId = new Map(printings.map((p) => [p.cardId, p]));

describe("card detail rules", () => {
  for (const r of c.repoint) {
    it(`repoint: ${r.name}`, () => {
      expect(repoint(version(r.from), r.attribute, r.value, byId.get(r.value))).toEqual(version(r.to));
    });
  }
  for (const o of c.ops) {
    it(`ops: ${o.name}`, () => {
      const v = version(o.item);
      const got = editOps({ cardId: v.cardId, finish: v.finish, condition: v.condition, lang: v.lang, qty: v.qty }, o.places, version(o.to), o.qty, o.from);
      expect(got).toEqual(o.ops?.map(({ binder_id, ...rest }) => (binder_id ? { ...rest, binder_id } : rest)) ?? null);
    });
  }
  for (const v of c.views) {
    it(`view: ${v.name}`, () => {
      const versions = orderedVersions(v.versions.map(version), printings);
      expect(versions.map(versionId)).toEqual(v.order);
      expect(mainVersion(versions) && versionId(mainVersion(versions)!)).toBe(v.main);
      expect(showsFinish(versions, byId)).toBe(v.shows_finish);
      expect(shared(versions, (x) => x.cardId)).toBe(v.shared.set ?? null);
      expect(shared(versions, (x) => x.lang)).toBe(v.shared.language ?? null);
      expect(shared(versions, (x) => x.condition)).toBe(v.shared.condition ?? null);
      expect(shared(versions, (x) => x.finish)).toBe(v.shared.finish ?? null);
    });
  }
  it("fresh: the original printing in the add condition and language", () => {
    expect(freshVersion(printings, c.fresh.condition, c.fresh.lang)).toEqual(version(c.fresh.version));
  });
  it("step into Unsorted names no binder", () => {
    const v = version({ card_id: "lea", finish: "nonfoil" });
    expect(stepOp(v, 1, "unsorted").binder_id).toBeUndefined();
    expect(stepOp(v, -1, "b1").binder_id).toBe("b1");
  });
});
