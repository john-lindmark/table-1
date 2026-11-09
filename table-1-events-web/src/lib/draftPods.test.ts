import { describe, expect, it } from "vitest";
import cases from "../../../testdata/draft-pods/cases.json";
import { draftAutoLabel, podCode, podNote, roundOneBye } from "./draftPods";
import { draftRounds } from "./playoffs";
import { podLabel, podPlan } from "./seating";
import type { SeatingPod } from "./types";

const podsOf = (sizes: number[]): SeatingPod[] => sizes.map((n, p) => ({
  pod_id: `pod${p + 1}`, name: `Pod ${p + 1}`,
  seats: Array.from({ length: n }, (_, s) => ({ seat: s + 1, participant_id: `P${p + 1}S${s + 1}`, display_name: `x`, team: null })),
}));

describe("draft pods (testdata/draft-pods)", () => {
  it("plans, rounds and labels", () => {
    for (const c of cases.plan) expect(podPlan(c.players, c.pods), JSON.stringify(c)).toEqual(c.want);
    for (const c of cases.rounds) expect(draftRounds(c.sizes, c.pod_pairing as "pod" | "cross")).toBe(c.want);
    for (const c of cases.label) expect(podLabel(c.players, c.pods)).toBe(c.want);
    for (const c of cases.auto_label) {
      expect(draftAutoLabel(c.players, c.pods, c.pod_pairing as "pod" | "cross"), JSON.stringify(c)).toBe(c.want);
    }
  });

  it("round 1 notes and the bye across every pod", () => {
    for (const c of cases.note) expect(podNote(podsOf(c.sizes), c.pod), JSON.stringify(c)).toBe(c.want);
    for (const c of cases.round1) expect(roundOneBye(podsOf(c.sizes))).toBe(c.want.bye);
  });

  it("pod codes", () => {
    expect(podCode("Pod 3", 0)).toBe("P3");
    expect(podCode("Main", 1)).toBe("P2");
    expect(podCode(null, 0)).toBe("P1");
  });
});
