import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { screenName } from "./analytics";
import { navKeyFor } from "./desktop";
import { afterWindow, archetypeName, bansTitle, canHide, changeWords, colorsName, exampleFinish, formatParts, FORMATS, isBan, matchup, place, sourcesCredit, visibleKeys, type BanStudy, type ConstructedPack, type LimitedPack } from "./insights";

/* Insights packs (contract/insights-2026-10-24.md § Packs) as the server builds them: testdata/insights holds
   constructed packs built from real MTGO pages and a Limited pack from 17Lands data (tools/insights/). */
const read = (f: string) => JSON.parse(readFileSync(new URL(`../../../testdata/insights/${f}`, import.meta.url), "utf8"));

describe("insights packs", () => {
  it.each(["standard", "pioneer", "modern", "pauper"])("%s has both tiers, every window and named shares", (f) => {
    const p = read(`constructed-${f}.json`) as ConstructedPack;
    expect(p.format).toBe(f);
    expect(p.archetypes[0]).toMatchObject({ id: 0, name: "Other" });
    for (const t of ["big", "all"] as const) {
      expect(Object.keys(p.tiers[t].windows).sort()).toEqual(["14", "30", "7", "90"]);
      expect(p.tiers[t].series.lines.every((l) => l.v.length === p.tiers[t].series.days)).toBe(true);
      for (const s of p.tiers[t].windows["30"].share) expect(p.archetypes.some((a) => a.id === s.a)).toBe(true);
    }
  });

  it("names archetypes; unknown ids are Other", () => {
    const p = read("constructed-modern.json") as ConstructedPack;
    expect(archetypeName(p, 0)).toBe("Other");
    expect(archetypeName(p, -9)).toBe("Other");
    expect(archetypeName(undefined, 3)).toBe("Other");
  });

  it("limited pack: credit, rated cards with draft picks, pairs", () => {
    const p = read("limited-FRA.json") as LimitedPack;
    expect(p.credit.name).toBe("17Lands");
    const v = p.events.PremierDraft.groups.all!;
    expect(v.games).toBeGreaterThan(100_000);
    expect(v.cards.some((c) => c.gih != null && c.c != null)).toBe(true);
    expect(v.cards.some((c) => c.ata != null)).toBe(true);
    expect(v.pairs.some((x) => x.p === "3C")).toBe(true);
    expect(v.colors!.some((c) => c.s !== "")).toBe(true);
    expect(v.colors!.every((c) => c.share >= 0.005)).toBe(true);
  });
});

describe("insights helpers", () => {
  it("words points changes and heads a points format's studies Points changes", () => {
    const pts = { id: 9, on: "2026-10-26", kind: "points", cards: ["Mana Crypt"], set_code: null, note: "Mana Crypt 3 → 4, Gush 0 → 1", url: null };
    expect(changeWords(pts)).toBe("Points: Mana Crypt 3 → 4, Gush 0 → 1");
    expect(isBan(pts)).toBe(true);
    expect(bansTitle(["points", "points"])).toBe("Points changes");
    expect(bansTitle(["ban", "unban"])).toBe("Bans and unbans");
  });
  it("picks the example list: biggest event, best finish, newest, whole lists only", () => {
    const main60: [string, number][] = [["Lightning Bolt", 4], ["Mountain", 56]];
    const f = (tier: string, rank: number | null, on: string, main = main60) => ({ event: "E", on, players: 64, tier, rank, url: null, main, side: [] as [string, number][] });
    expect(exampleFinish([f("regular", 1, "2026-10-20"), f("large", 5, "2026-10-01"), f("large", 2, "2026-09-20")])).toBe(2);
    expect(exampleFinish([f("major", 3, "2026-10-01"), f("major", 3, "2026-10-10")])).toBe(1);
    expect(exampleFinish([f("major", 1, "2026-10-01", [["Lightning Bolt", 4]]), f("small", null, "2026-10-02")])).toBe(1);
    expect(exampleFinish([])).toBe(-1);
    expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 101].map(place)).toEqual(["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "101st"]);
  });
  it("hides formats and sets from the pickers, never the last one", () => {
    const all = ["standard", "pioneer", "modern", "pauper", "canlander"];
    expect(visibleKeys(all, ["pioneer", "canlander"])).toEqual(["standard", "modern", "pauper"]);
    expect(visibleKeys(all, all)).toEqual(all);
    expect(canHide(all, ["pioneer"], "modern")).toBe(true);
    expect(canHide(["modern", "pauper"], ["pauper"], "modern")).toBe(false);
    expect(canHide(["modern"], [], "modern")).toBe(false);
  });
  it("credits each pack's own sources, TopDeck.gg alone for Canadian Highlander", () => {
    expect(sourcesCredit(["mtgo"]).label).toBe("Results from Magic Online");
    expect(sourcesCredit(["mtgo", "topdeck"])).toEqual({ label: "Results from Magic Online and TopDeck.gg", url: "https://topdeck.gg" });
    expect(sourcesCredit(["topdeck"])).toEqual({ label: "Results from TopDeck.gg", url: "https://topdeck.gg" });
    expect(sourcesCredit(["melee", "topdeck", "mtgo"])).toEqual({ label: "Results from Magic Online, TopDeck.gg and Melee", url: "https://topdeck.gg" });
    expect(sourcesCredit(["mtgo", "melee"])).toEqual({ label: "Results from Magic Online and Melee", url: "https://www.mtgo.com/decklists" });
    expect(sourcesCredit(["melee"])).toEqual({ label: "Results from Melee", url: "https://melee.gg" });
    expect(sourcesCredit([]).label).toBe("Results from Magic Online");
    expect(FORMATS.map((f) => f.key)).toEqual(["standard", "pioneer", "modern", "pauper", "canlander"]);
  });
  it("matchup cells read from either side", () => {
    const m = { archetypes: [1, 2], cells: [[1, 2, 31, 22, 1]] as [number, number, number, number, number][] };
    expect(matchup(m, 1, 2)).toEqual({ wins: 31, losses: 22, draws: 1 });
    expect(matchup(m, 2, 1)).toEqual({ wins: 22, losses: 31, draws: 1 });
    expect(matchup(m, 1, 3)).toBeNull();
  });

  it("a ban study uses its longest ended window", () => {
    const s = [{ a: 1, share: 0.2 }];
    const b = { change: 1, on: "2026-05-18", before: s, after: { "14": s, "30": s }, losers: [], gainers: [], replacements: [], settled_days: null, brief: null } as BanStudy;
    expect(afterWindow(b)?.days).toBe(30);
    expect(afterWindow({ ...b, after: {} })).toBeNull();
  });

  it("deck colour names", () => {
    expect(colorsName("UB", "")).toBe("Dimir UB");
    expect(colorsName("UB", "R")).toBe("Dimir UB + r");
    expect(colorsName("WUB", "")).toBe("Esper WUB");
    expect(colorsName("WRG", "U")).toBe("Naya WRG + u");
    expect(colorsName("WUBR", "")).toBe("Four-colour WUBR");
    expect(colorsName("R", "")).toBe("Mono-Red R");
  });

  it("change words", () => {
    expect(changeWords({ id: 1, on: "2026-05-18", kind: "unban", cards: ["A", "B", "C", "D"], set_code: null, note: null, url: null })).toBe("Unbanned: A, B, C and others");
    expect(changeWords({ id: 2, on: "2026-10-02", kind: "set_release", cards: [], set_code: "fra", note: "Reality Fracture", url: null })).toBe("Released: Reality Fracture");
  });

  it("screen names and sidebar items for every Insights page", () => {
    const cases: [string, string, string][] = [
      ["/insights", "insights_constructed", "constructed"],
      ["/insights/limited", "insights_limited", "limited"],
      ["/insights/review", "insights_review", "constructed"],
      ["/insights/modern/archetype/12", "insights_archetype", "constructed"],
      ["/insights/modern/archetype/12/finish/0", "insights_finish", "constructed"],
      ["/insights/modern/card/abc", "insights_card", "constructed"],
      ["/insights/modern/ban/3", "insights_ban", "constructed"],
      ["/insights/modern/matchups", "insights_matchups", "constructed"],
      ["/insights/modern/part/cards", "insights_part", "constructed"],
      ["/insights/limited/FRA/PremierDraft/all/pair/UB", "insights_pair", "limited"],
      ["/insights/limited/FRA/PremierDraft/top/card/Lightning%20Bolt", "insights_limited_card", "limited"],
    ];
    for (const [p, name, nav] of cases) {
      expect(screenName(p)).toBe(name);
      expect(navKeyFor(p)).toBe(nav);
    }
  });

  it("sums up the format page's parts, one row each (testdata/insights/parts.json)", () => {
    const { cases } = read("parts.json") as { cases: { format: string; tier: "big" | "all"; days: number; parts: unknown[] }[] };
    for (const k of cases) expect(formatParts(read(`constructed-${k.format}.json`) as ConstructedPack, k.tier, k.days)).toEqual(k.parts);
  });
});
