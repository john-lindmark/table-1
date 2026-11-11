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
export function opensPicker(seat: Seat, dx: number, dy: number, min = TOUCH_SWIPE): boolean {
  const { down, across } = toward(seat, dx, dy);
  return down >= min && down > Math.abs(across) * 1.5;
}

/*
 * The touch rule (contract/life-tracker-options-2026-10-20.md § Taps and the pull band, cases
 * testdata/tracker-touch/cases.json): a tap on a +1 / −1 zone always counts, however far it drifts; only a touch
 * that starts in the pull band along the player's far edge and travels toward them opens the counter picker.
 */
/** The pull band's depth from the player's far edge (CSS px). */
export const TOUCH_BAND = 44;
/** Travel toward the player that opens the picker. */
export const TOUCH_SWIPE = 24;
/** Travel before the hold delay that makes a touch a rolled tap, not a hold (no repeat). */
export const TOUCH_HOLD_SLOP = 24;
/** The old cancel distance: telemetry counts the taps that travelled past it (they used to be lost). */
export const TOUCH_MOVED = 10;

/** How far a point in a box (screen px, origin top-left) is from the player's far edge, their "top". */
export function farFrom(seat: Seat, x: number, y: number, w: number, h: number): number {
  switch (seat) {
    case "top":
      return h - y;
    case "left":
      return w - x;
    case "right":
      return x;
    default:
      return y;
  }
}

export const inPullBand = (seat: Seat, x: number, y: number, w: number, h: number) =>
  farFrom(seat, x, y, w, h) <= TOUCH_BAND;

export const pulls = (seat: Seat, x: number, y: number, w: number, h: number, dx: number, dy: number) =>
  inPullBand(seat, x, y, w, h) && opensPicker(seat, dx, dy);

export const holds = (dx: number, dy: number) => Math.hypot(dx, dy) <= TOUCH_HOLD_SLOP;

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
