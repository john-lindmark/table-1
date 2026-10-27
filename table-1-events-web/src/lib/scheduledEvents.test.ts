import { describe, expect, it } from "vitest";
import cases from "../../../testdata/scheduled-events/cases.json";
import {
  autoLabel, countsText, deckFormat, decklistCounts, decklistsLine, nextStep, pageButton, roundName, roundsLine,
  signUpLine, swissRounds, type Stage,
} from "./scheduledEvents";
import { toBundle, toPublicEvent } from "./api";
import bundle from "../../../testdata/event-bundle/bundle.json";
import pub from "../../../testdata/event-bundle/public.json";

describe("scheduled events (shared cases)", () => {
  it("rounds, next step, names", () => {
    for (const c of cases.rounds) expect(swissRounds(c.players), `${c.players}`).toBe(c.want);
    for (const c of cases.next) {
      expect(nextStep({ stages: c.stages as Stage[], waiting: c.waiting, numberOfRounds: c.number_of_rounds,
        topCut: c.top_cut, activePlayers: c.active_players }), JSON.stringify(c)).toBe(c.want);
    }
    for (const c of cases.round_name) expect(roundName(c.stage, c.number, c.of)).toBe(c.want);
    for (const c of cases.auto_label) expect(autoLabel(c.players)).toBe(c.want);
    for (const c of cases.rounds_line) expect(roundsLine(c.auto, c.rounds, c.top_cut, c.open)).toBe(c.want);
  });

  it("sign-up page", () => {
    for (const c of cases.sign_up) expect(signUpLine(c.players, c.capacity, c.waitlist)).toBe(c.want);
    for (const c of cases.button) expect(pageButton(c.signed_in, c.sign_up, c.me), JSON.stringify(c)).toBe(c.want);
  });

  it("decklists", () => {
    for (const c of cases.decklist) expect(decklistCounts(c.body), c.body).toEqual(c.want);
    for (const c of cases.deck_format) expect(deckFormat(c.event)).toBe(c.want);
    for (const c of cases.decklists_line) expect(decklistsLine(c.sent, c.players)).toBe(c.want);
    expect(countsText(60, 15)).toBe("60 main · 15 sideboard");
  });

  it("reads the new bundle and page fields from the real RPCs", () => {
    const b = toBundle(bundle);
    expect(b.event.topCut).toBe(8);
    expect(b.event.capacity).toBe(8);
    expect(b.event.decklists).toBe("optional");
    expect(b.waitlist.map((w) => w.displayName)).toEqual(["Dot Waiting"]);
    expect(b.decklists.map((d) => d.mainCount)).toEqual([60]);
    expect(b.rounds.map((r) => r.stage)).toEqual(["swiss", "swiss"]);
    const p = toPublicEvent(pub);
    expect(p.signUp).toBe("closed");
    expect(signUpLine(p.players, p.capacity, p.waitlist)).toBe("3/8 players · 1 on the waitlist");
    expect(roundsLine(p.autoRounds, p.numberOfRounds, p.topCut, p.signUp !== "closed")).toBe("3 rounds · Top 8");
    // The public link's Matchups: every round, newest first, by name.
    expect(p.rounds.map((r) => r.number)).toEqual([2, 1]);
    expect(p.rounds[1].matches[0].sides.map((x) => x.displayName)).toEqual(["Ana Organizer", "Guest Cara"]);
  });
});
