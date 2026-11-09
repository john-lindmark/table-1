import { describe, expect, it } from "vitest";
import cases from "../../../testdata/repair-round/cases.json";
import { repairConfirm, repairLabel, repairPrompt, type RepairRound } from "./repairRound";

const toRound = (r: any): RepairRound => ({
  number: r.number,
  status: r.status,
  pairingsPublishedAt: r.pairings_published_at,
  matches: r.matches.map((m: any) => ({
    isBye: m.is_bye, status: m.status, resultSource: m.result_source, updatedAt: m.updated_at,
  })),
});

describe("re-pair a round (testdata/repair-round)", () => {
  for (const c of cases.prompt) {
    it(`prompt: ${c.name}`, () => {
      expect(repairPrompt(c.rounds.map(toRound))).toEqual(c.want);
    });
  }
  for (const c of cases.confirm) {
    it(`confirm: ${c.name}`, () => {
      expect(repairConfirm(c.label, c.matches.map((m) => ({ isBye: m.is_bye, status: m.status })))).toEqual(c.want);
    });
  }
  for (const c of cases.labels) {
    it(`label: ${c.stage}`, () => expect(repairLabel(c.stage, c.number)).toBe(c.want));
  }
});
