import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { roleFits, zoneCanPair, zoneFilling, zoneInDeck, zoneMovingIn, zonePairs, zonePartnerHint, zoneRoleName, zoneSlots, type ZoneRole } from "./commandZone";

/* Command zone rules (contract/command-zone-2026-10-27.md) against testdata/command-zone/cases.json. */

const cases = JSON.parse(readFileSync(new URL("../../../testdata/command-zone/cases.json", import.meta.url), "utf8")) as {
  fits: { type: string; roles: ZoneRole[] }[];
  slots: { name: string; format: string; lines: [string, string, (string | null)?][]; slots: [ZoneRole, string | null][] }[];
  filling: { name: string; lines: string[]; slot: string | null; card: string; result: string[] }[];
  role: { format: string; type: string; role: string }[];
  in_deck: { name: string; role: ZoneRole; lines: [string, string, string][]; result: string[] }[];
  move_in: { name: string; slot: string | null; card: [string, string, number]; ops: (string | number)[][] }[];
  can_pair: { type: string; pair: string | null; ok: boolean }[];
  pairs: { name: string; commander: [string, string | null, string]; candidate: [string, string | null, string]; ok: boolean }[];
  partner_hint: { type: string; pair: string | null; hint: string }[];
};
const ALL: ZoneRole[] = ["commander", "partner", "oathbreaker", "signature"];

describe("command zone", () => {
  it.each(cases.fits)("fits $type", (f) => {
    expect(ALL.filter((r) => roleFits(r, f.type))).toEqual(f.roles);
  });
  it.each(cases.slots)("slots: $name", (s) => {
    expect(zoneSlots(s.format, s.lines.map(([cardId, typeLine, pair]) => ({ cardId, typeLine, pair }))).map((x) => [x.role, x.cardId])).toEqual(s.slots);
  });
  it.each(cases.filling)("filling: $name", (f) => {
    const lines = f.lines.map((cardId) => ({ cardId, typeLine: "" }));
    expect(zoneFilling(lines, f.slot, { cardId: f.card, typeLine: "" }).map((l) => l.cardId)).toEqual(f.result);
  });
  it.each(cases.role)("role $format $type", (r) => {
    expect(zoneRoleName(r.format, r.type)).toBe(r.role);
  });
  it.each(cases.in_deck)("in deck: $name", (d) => {
    expect(zoneInDeck(d.role, d.lines.map(([cardId, board, typeLine]) => ({ cardId, board, typeLine }))).map((l) => l.cardId)).toEqual(d.result);
  });
  it.each(cases.can_pair)("can pair: $type $pair", (p) => {
    expect(zoneCanPair(p.type, p.pair)).toBe(p.ok);
  });
  it.each(cases.pairs)("pairs: $name", (p) => {
    const mate = ([typeLine, pair, name]: [string, string | null, string]) => ({ typeLine, pair, name });
    expect(zonePairs(mate(p.commander), mate(p.candidate))).toBe(p.ok);
  });
  it.each(cases.partner_hint)("partner hint: $pair", (h) => {
    expect(zonePartnerHint({ typeLine: h.type, pair: h.pair, name: "" })).toBe(h.hint);
  });
  it.each(cases.move_in)("move in: $name", (m) => {
    const [cardId, board, qty] = m.card;
    const ops = zoneMovingIn({ cardId, board, typeLine: "", qty }, { role: "commander", cardId: m.slot, finish: "nonfoil", lang: "en" });
    expect(ops.map((o) => (o.kind === "move" ? ["move", o.cardId, o.from, o.to] : ["delta", o.cardId, o.board, o.by]))).toEqual(m.ops);
  });
});
