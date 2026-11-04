import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  COMMANDER_FROM,
  COMMANDER_LOSS,
  commanderFrom,
  counterLabel,
  counterShort,
  groupOps,
  hasLost,
  matchScore,
  pickerCounters,
  settledWinner,
  totals,
  type Counter,
  type TrackerOp,
} from "./tracker";
import {
  LIFE_CHOICES,
  PLAYER_CHOICES,
  opensPicker,
  tableLayout,
  tableNames,
  tableScore,
  toward,
  tracksCommander,
} from "./trackerTable";

/* The life tracker's table setup, seats and commander damage (contract/life-tracker-commander-2026-11-03.md)
   against testdata/tracker-table/cases.json (also iOS TrackerTableTests, Android TrackerTableTest). */

type Op = { at?: number; side: number; counter: Counter; delta: number };
interface Cases {
  setup: { players: number[]; lives: number[]; commanderFrom: number; commanderLoss: number };
  names: { players: number; names: string[] }[];
  layouts: { players: number; rows: unknown[] }[];
  picker: { players: number; life: number; side: number; rows: string[] }[];
  labels: { players: number; counter: Counter; label: string; short: string }[];
  totals: { players: number; life: number; ops: Op[]; lifeTotals: number[]; counters: { side: number; counter: Counter; value: number }[] }[];
  losing: { players: number; life: number; ops: Op[]; lost: number[]; winner: number | null }[];
  groups: { players: number; life: number; ops: Op[]; groups: { side: number; counter: string; delta: number; after: number }[]; lifeTotals: number[] }[];
  score: { players: number; winners: number[]; text: string }[];
}
const c: Cases = JSON.parse(readFileSync(new URL("../../../testdata/tracker-table/cases.json", import.meta.url), "utf8"));

const t0 = Date.UTC(2026, 10, 3);
const ops = (list: Op[]): TrackerOp[] =>
  list.map((o, i) => ({
    client_op_id: `op-${i}`,
    game_no: 1,
    side: o.side,
    counter: o.counter,
    delta: o.delta,
    tapped_at: new Date(t0 + (o.at ?? i)).toISOString(),
  }));

describe("tracker table", () => {
  it("offers the setup choices", () => {
    expect(PLAYER_CHOICES).toEqual(c.setup.players);
    expect(LIFE_CHOICES).toEqual(c.setup.lives);
    expect(COMMANDER_FROM).toBe(c.setup.commanderFrom);
    expect(COMMANDER_LOSS).toBe(c.setup.commanderLoss);
  });

  it("names and seats the players", () => {
    for (const n of c.names) expect(tableNames(n.players)).toEqual(n.names);
    for (const l of c.layouts) expect(tableLayout(l.players)).toEqual(l.rows);
  });

  it("reads commander damage keys", () => {
    expect(commanderFrom("cmd:3")).toBe(3);
    expect(commanderFrom("life")).toBeNull();
    expect(commanderFrom("cmd:" as Counter)).toBeNull();
    expect(commanderFrom("cmd:-1" as Counter)).toBeNull();
  });

  it("lists commander damage from each opponent first at 30+ life", () => {
    for (const p of c.picker) {
      expect(pickerCounters(p.side, p.players, tracksCommander(false, p.life))).toEqual(p.rows);
    }
    expect(tracksCommander(true, 40)).toBe(false);
  });

  it("labels counters", () => {
    for (const l of c.labels) {
      const names = tableNames(l.players);
      expect(counterLabel(l.counter, names)).toBe(l.label);
      expect(counterShort(l.counter, names)).toBe(l.short);
    }
  });

  it("takes commander damage off life", () => {
    for (const x of c.totals) {
      const t = totals(ops(x.ops), 1, x.life, x.players);
      expect(t.map((v) => v.life)).toEqual(x.lifeTotals);
      for (const v of x.counters) expect(t[v.side][v.counter]).toBe(v.value);
    }
  });

  it("knows who has lost and who is left", () => {
    for (const x of c.losing) {
      const t = totals(ops(x.ops), 1, x.life, x.players);
      const commander = tracksCommander(false, x.life);
      expect(t.map((_, side) => side).filter((side) => hasLost(t, side, commander))).toEqual(x.lost);
      expect(settledWinner(t, commander)).toBe(x.winner);
    }
  });

  it("counts commander damage in a later life group's result", () => {
    for (const x of c.groups) {
      const groups = groupOps(ops(x.ops), 1, x.life).filter((g) => g.delta !== 0);
      expect(groups.map((g) => ({ side: g.side, counter: g.counter, delta: g.delta, after: g.after }))).toEqual(x.groups);
      expect(totals(ops(x.ops), 1, x.life, x.players).map((v) => v.life)).toEqual(x.lifeTotals);
    }
  });

  it("writes the score", () => {
    for (const x of c.score) {
      const games = x.winners.map((w, i) => ({ game_no: i + 1, winner_side: w, is_draw: false, recorded_at: "" }));
      const s = matchScore(games, x.players);
      expect(tableScore(s.wins, tableNames(x.players), 0, 1, s.draws)).toBe(x.text);
    }
  });

  it("measures a swipe toward each seat's player", () => {
    expect(toward("bottom", 0, 30).down).toBe(30);
    expect(toward("top", 0, 30).down).toBe(-30);
    expect(toward("left", -30, 0).down).toBe(30);
    expect(toward("right", 30, 0).down).toBe(30);
  });

  it("opens the counter picker on a swipe toward the player, and never closes it on a swipe away", () => {
    expect(opensPicker("bottom", 0, 30)).toBe(true);
    expect(opensPicker("top", 0, -30)).toBe(true);
    expect(opensPicker("left", -30, 0)).toBe(true);
    expect(opensPicker("right", 30, 0)).toBe(true);
    // Swiping up (scrolling the picker's rows) is not a close.
    expect(opensPicker("bottom", 0, -60)).toBe(false);
    expect(opensPicker("top", 0, 60)).toBe(false);
    expect(opensPicker("bottom", 0, 20)).toBe(false);
    expect(opensPicker("bottom", 30, 30)).toBe(false);
  });
});
