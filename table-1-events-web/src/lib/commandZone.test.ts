import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { roleFits, zoneFilling, zoneRoleName, zoneSlots, type ZoneRole } from "./commandZone";

/* Command zone rules (contract/command-zone-2026-10-27.md) against testdata/command-zone/cases.json. */

const cases = JSON.parse(readFileSync(new URL("../../../testdata/command-zone/cases.json", import.meta.url), "utf8")) as {
  fits: { type: string; roles: ZoneRole[] }[];
  slots: { name: string; format: string; lines: [string, string][]; slots: [ZoneRole, string | null][] }[];
  filling: { name: string; lines: string[]; slot: string | null; card: string; result: string[] }[];
  role: { format: string; type: string; role: string }[];
};
const ALL: ZoneRole[] = ["commander", "partner", "oathbreaker", "signature"];

describe("command zone", () => {
  it.each(cases.fits)("fits $type", (f) => {
    expect(ALL.filter((r) => roleFits(r, f.type))).toEqual(f.roles);
  });
  it.each(cases.slots)("slots: $name", (s) => {
    expect(zoneSlots(s.format, s.lines.map(([cardId, typeLine]) => ({ cardId, typeLine }))).map((x) => [x.role, x.cardId])).toEqual(s.slots);
  });
  it.each(cases.filling)("filling: $name", (f) => {
    const lines = f.lines.map((cardId) => ({ cardId, typeLine: "" }));
    expect(zoneFilling(lines, f.slot, { cardId: f.card, typeLine: "" }).map((l) => l.cardId)).toEqual(f.result);
  });
  it.each(cases.role)("role $format $type", (r) => {
    expect(zoneRoleName(r.format, r.type)).toBe(r.role);
  });
});
