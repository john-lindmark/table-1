/* The life tracker's Options: Roll dice and the chooser (iOS TrackerTools.swift; contract
   life-tracker-options-2026-10-20.md). Pure, so tests can pass a seeded random(). */

export type Random = () => number; // [0, 1), like Math.random

export const DICE_SIDES = [4, 6, 8, 10, 12, 20] as const;
export const MAX_DICE = 10;

const randomInt = (max: number, random: Random) => 1 + Math.floor(random() * max);

/** `count` dice of `sides` faces, each 1…sides. Count is clamped to 1…MAX_DICE. */
export function rollDice(sides: number, count: number, random: Random = Math.random): number[] {
  const n = Math.min(Math.max(Math.round(count), 1), MAX_DICE);
  const faces = Math.max(sides, 2);
  return Array.from({ length: n }, () => randomInt(faces, random));
}

/** "3 + 5 + 1"; nothing for a single die (the total says it). */
export const diceBreakdown = (rolls: number[]): string | null => (rolls.length > 1 ? rolls.join(" + ") : null);

/* Chooser: everyone puts a finger on the screen; once the fingers on it have stayed the same for
   CHOOSER_SETTLE_MS (two or more of them), one is picked at random. It stays picked until every finger
   lifts; fingers that land after the pick are ignored until then. */

export const CHOOSER_SETTLE_MS = 2000;
export const CHOOSER_MIN_FINGERS = 2;

export interface Finger {
  id: number;
  x: number;
  y: number;
}

export interface ChooserState {
  fingers: Finger[];
  /** When the set of fingers last changed (landed or lifted); moving one doesn't count. */
  changedAt: number | null;
  winner: number | null;
  /** After the pick every circle stays drawn until the last finger lifts; these are the ones still down. */
  pressed: number[];
}

export const emptyChooser = (): ChooserState => ({ fingers: [], changedAt: null, winner: null, pressed: [] });

export function chooserDown(s: ChooserState, id: number, x: number, y: number, now: number): ChooserState {
  if (s.winner != null || s.fingers.some((f) => f.id === id)) return s;
  return { ...s, fingers: [...s.fingers, { id, x, y }], pressed: [...s.pressed, id], changedAt: now };
}

export function chooserMove(s: ChooserState, id: number, x: number, y: number): ChooserState {
  if (!s.fingers.some((f) => f.id === id)) return s;
  return { ...s, fingers: s.fingers.map((f) => (f.id === id ? { id, x, y } : f)) };
}

export function chooserUp(s: ChooserState, id: number, now: number): ChooserState {
  if (!s.pressed.includes(id)) return s;
  const pressed = s.pressed.filter((p) => p !== id);
  if (s.winner != null) return pressed.length ? { ...s, pressed } : emptyChooser();
  const fingers = s.fingers.filter((f) => f.id !== id);
  return { ...s, fingers, pressed, changedAt: fingers.length ? now : null };
}

/** Share of the settle time gone (0…1) while waiting to pick; null when there aren't enough fingers. */
export function chooserProgress(s: ChooserState, now: number): number | null {
  if (s.winner != null || s.fingers.length < CHOOSER_MIN_FINGERS || s.changedAt == null) return null;
  return Math.min(1, Math.max(0, (now - s.changedAt) / CHOOSER_SETTLE_MS));
}

/** Picks once the fingers have settled; the same state back when it's not time yet. */
export function chooserTick(s: ChooserState, now: number, random: Random = Math.random): ChooserState {
  const p = chooserProgress(s, now);
  if (p == null || p < 1) return s;
  const pick = s.fingers[Math.min(s.fingers.length - 1, Math.floor(random() * s.fingers.length))];
  return { ...s, winner: pick.id };
}
