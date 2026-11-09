import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { followedDetail, matchScore, roundTitle } from "./eventFollows";

/* testdata/event-links/cases.json, the file iOS EventLinksTests and Android EventLinksTest read. The page's own
   results/title rules live in PublicStandings (covered by its test). */
const sc = JSON.parse(readFileSync(new URL("../../../testdata/event-links/cases.json", import.meta.url), "utf8"));

describe("event links and follows (shared cases)", () => {
  for (const c of sc.round_title) it(`round title ${c.want}`, () => expect(roundTitle(c.number, c.stage, c.status)).toBe(c.want));
  for (const c of sc.score) {
    it(`score ${c.want}`, () => expect(matchScore(c.status, c.sides.map(([side, gameWins]: number[]) => ({ side, gameWins })), c.game_draws)).toBe(c.want));
  }
  for (const c of sc.followed) it(`following ${c.want}`, () => expect(followedDetail(c)).toBe(c.want));
});
