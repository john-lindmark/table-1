import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  SampleHand, StatsRng, asfan, asfanLabels, averageMV, colorBalance, curve, curveByColor, deckOf, drawsByTurn, expand,
  hypergeometric, legality, librarySize, pipTotals, pips, price, sources, statCard, typeCounts, type AsfanBy, type StatCard,
} from "./deckStats";

/* Deck and cube stats (contract/lists-2026-10-15.md, "Stats"). Every number comes from testdata/deck-stats/cases.json,
   written by the Python reference there; apps/ios/Table1Tests/DeckStatsTests.swift and Android's DeckStatsTest read
   the same file, so all three clients give the same answers. */

type Card = Omit<StatCard, "typeBits">;
interface Issue { name: string; reason: string }
interface Deck {
  format: string;
  cards: Card[];
  expected: {
    curve: { creatures: number[]; other: number[] }; types: number[]; averageWithLands: number; averageWithoutLands: number;
    pips: number[]; sources: { colors: number[]; unread: number }; price: { total: number; unpriced: number };
    legality: Issue[]; librarySize: number;
  };
  legalityIn?: Record<string, Issue[]>;
}
interface Cases {
  prng: { seed: number; first: number[] };
  bounded: { seed: number; bound: number; first: number[] };
  shuffles: { seed: number; n: number; order: number[] }[];
  pips: { cost: string; pips: number[] }[];
  hypergeometric: { N: number; K: number; n: number; k: number; p: number }[];
  drawsByTurn: { turn: number; onPlay: boolean; draws: number }[];
  deck: Deck;
  commander: Deck;
  mulligan: { size: number; seed: number; script: { do: string; index?: number; expect: { hand: number[]; library: number; toBottom: number; mulligans: number } }[] };
  cube: {
    cards: Card[];
    expected: {
      size: number; colorBalance: number[]; curveByColor: number[][]; types: number[]; asfan: Record<AsfanBy, number[]>;
      pack: { seed: number; size: number; cards: number[] };
    };
  };
}

export const cases = JSON.parse(readFileSync(new URL("../../../testdata/deck-stats/cases.json", import.meta.url), "utf8")) as Cases;

describe("deck stats: shared cases", () => {
  it("random numbers match every platform", () => {
    const r = new StatsRng(cases.prng.seed);
    expect(cases.prng.first.map(() => r.next())).toEqual(cases.prng.first);
    const b = new StatsRng(cases.bounded.seed);
    expect(cases.bounded.first.map(() => b.int(cases.bounded.bound))).toEqual(cases.bounded.first);
    for (const s of cases.shuffles) expect(new StatsRng(s.seed).shuffle(s.n)).toEqual(s.order);
  });

  it("counts pips", () => {
    for (const p of cases.pips) expect(pips(p.cost), p.cost).toEqual(p.pips);
  });

  it("hypergeometric odds", () => {
    for (const h of cases.hypergeometric) expect(hypergeometric(h.N, h.K, h.n, h.k)).toBeCloseTo(h.p, 9);
    for (const t of cases.drawsByTurn) expect(drawsByTurn(t.turn, t.onPlay)).toBe(t.draws);
  });

  for (const which of ["deck", "commander"] as const) {
    it(`${which} stats`, () => {
      const d = cases[which];
      const cards = d.cards.map(statCard);
      const e = d.expected;
      expect(curve(cards)).toEqual(e.curve);
      expect(typeCounts(deckOf(cards))).toEqual(e.types);
      expect(averageMV(cards, true)).toBeCloseTo(e.averageWithLands, 9);
      expect(averageMV(cards, false)).toBeCloseTo(e.averageWithoutLands, 9);
      expect(pipTotals(cards)).toEqual(e.pips);
      expect(sources(cards)).toEqual(e.sources);
      const p = price(cards);
      expect(Math.abs(p.total - e.price.total)).toBeLessThan(0.006);
      expect(p.unpriced).toBe(e.price.unpriced);
      expect(legality(cards, d.format)).toEqual(e.legality);
      expect(librarySize(cards)).toBe(e.librarySize);
      for (const [format, want] of Object.entries(d.legalityIn ?? {})) expect(legality(cards, format), format).toEqual(want);
    });
  }

  it("London mulligan", () => {
    let hand = SampleHand.deal(cases.mulligan.size, cases.mulligan.seed);
    for (const step of cases.mulligan.script) {
      if (step.do === "mulligan") hand = hand.mulligan();
      else if (step.do === "bottom") hand = hand.bottom(step.index!);
      else if (step.do === "draw") hand = hand.draw();
      expect({ hand: hand.hand, library: hand.library.length, toBottom: hand.toBottom, mulligans: hand.mulligans }, step.do).toEqual(step.expect);
    }
    // The library and hand always hold every card once.
    expect([...hand.hand, ...hand.library].sort((a, b) => a - b)).toEqual(Array.from({ length: cases.mulligan.size }, (_, i) => i));
  });

  it("mulligan rules", () => {
    let hand = SampleHand.deal(60, 1);
    expect(hand.canMulligan).toBe(true);
    hand = hand.mulligan();
    expect(hand.canDraw).toBe(false); // bottom a card before drawing
    expect(hand.draw().hand.length).toBe(7);
    hand = hand.bottom(0);
    expect(hand.canDraw).toBe(true);
    for (let i = 0; i < 10; i++) hand = hand.mulligan();
    expect(hand.mulligans).toBe(6); // down to one card at most
    const small = SampleHand.deal(5, 3);
    expect(small.hand.length).toBe(5);
    expect(small.canDraw).toBe(false);
  });

  it("cube stats", () => {
    const e = cases.cube.expected;
    const cards = cases.cube.cards.filter((c) => c.board === "main").map(statCard);
    expect(cards.reduce((n, c) => n + c.qty, 0)).toBe(e.size);
    expect(colorBalance(cards)).toEqual(e.colorBalance);
    expect(curveByColor(cards)).toEqual(e.curveByColor);
    expect(typeCounts(cards)).toEqual(e.types);
    for (const by of ["color", "type", "mv"] as AsfanBy[]) {
      const got = asfan(cards, 15, by);
      expect(got.length).toBe(e.asfan[by].length);
      expect(got.length).toBe(asfanLabels(by).length);
      got.forEach((g, i) => expect(g).toBeCloseTo(e.asfan[by][i], 9));
    }
    expect(new StatsRng(e.pack.seed).shuffle(expand(cards).length).slice(0, e.pack.size)).toEqual(e.pack.cards);
  });
});
