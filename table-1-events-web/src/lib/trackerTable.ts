// The table a local life tracker is set up for (contract/life-tracker-commander-2026-11-03.md): 2–5 players,
// their starting life, and where each sits around the phone. Same rules as iOS TrackerTable.swift and Android
// TrackerTable.kt, checked against testdata/tracker-table/cases.json.

import { COMMANDER_FROM, type Side } from "./tracker";

export const PLAYER_CHOICES = [2, 3, 4, 5];
export const LIFE_CHOICES = [20, 30, 40];

/** Each seat faces its own edge: bottom reads normally, top is turned 180°, left 90° clockwise, right 90° back. */
export type Seat = "bottom" | "top" | "left" | "right";
export interface Place {
  side: Side;
  seat: Seat;
}
/** Rows top to bottom on screen; "strip" is the info strip. */
export type TableRow = Place[] | "strip";

export const SEAT_DEGREES: Record<Seat, number> = { bottom: 0, top: 180, left: 90, right: -90 };

export const sideways = (seat: Seat) => seat === "left" || seat === "right";

/** Seats go clockwise from the bottom. */
export function tableLayout(players: number): TableRow[] {
  switch (players) {
    case 3:
      return [[{ side: 1, seat: "left" }, { side: 2, seat: "right" }], "strip", [{ side: 0, seat: "bottom" }]];
    case 4:
      return [[{ side: 1, seat: "left" }, { side: 2, seat: "right" }], "strip", [{ side: 0, seat: "left" }, { side: 3, seat: "right" }]];
    case 5:
      return [
        [{ side: 2, seat: "left" }, { side: 3, seat: "right" }],
        [{ side: 1, seat: "left" }, { side: 4, seat: "right" }],
        "strip",
        [{ side: 0, seat: "bottom" }],
      ];
    default:
      return [[{ side: 1, seat: "top" }], "strip", [{ side: 0, seat: "bottom" }]];
  }
}

export function tableNames(players: number): string[] {
  return players <= 2 ? ["You", "Opponent"] : Array.from({ length: players }, (_, i) => `P${i + 1}`);
}

/** Local tables starting at 30 or more life track commander damage. */
export const tracksCommander = (synced: boolean, startingLife: number) => !synced && startingLife >= COMMANDER_FROM;

/** A drag in screen pixels, measured toward the player (their "down") and across. */
export function toward(seat: Seat, dx: number, dy: number): { down: number; across: number } {
  switch (seat) {
    case "top":
      return { down: -dy, across: dx };
    case "left":
      return { down: -dx, across: dy };
    case "right":
      return { down: dx, across: dy };
    default:
      return { down: dy, across: dx };
  }
}

/**
 * A swipe toward the player opens their counter picker. No swipe closes it, only Done: swiping away is also how
 * the picker's rows scroll (commander damage made the list long).
 */
export function opensPicker(seat: Seat, dx: number, dy: number, min = 24): boolean {
  const { down, across } = toward(seat, dx, dy);
  return down >= min && down > Math.abs(across) * 1.5;
}

const SETUP_KEY = "table1.lifeTracker.setup";

/** The last setup used on this device (2 players, 20 life by default). */
export function lastSetup(): { players: number; life: number } {
  try {
    const s = JSON.parse(localStorage.getItem(SETUP_KEY) ?? "null") as { players?: unknown; life?: unknown } | null;
    const players = PLAYER_CHOICES.includes(Number(s?.players)) ? Number(s?.players) : 2;
    const life = LIFE_CHOICES.includes(Number(s?.life)) ? Number(s?.life) : 20;
    return { players, life };
  } catch {
    return { players: 2, life: 20 };
  }
}

export function saveSetup(players: number, life: number) {
  try {
    localStorage.setItem(SETUP_KEY, JSON.stringify({ players, life }));
  } catch {
    /* storage unavailable: Setup starts on the defaults */
  }
}

/** "2–1" (my wins first, draws last) with two players; "P1 1 · P2 0 · P3 2" at a bigger table. */
export function tableScore(wins: number[], names: string[], bottom: Side = 0, top: Side = 1, draws = 0): string {
  if (names.length <= 2) {
    const base = `${wins[bottom] ?? 0}–${wins[top] ?? 0}`;
    return draws > 0 ? `${base}–${draws}` : base;
  }
  return names.map((n, i) => `${n} ${wins[i] ?? 0}`).join(" · ");
}
