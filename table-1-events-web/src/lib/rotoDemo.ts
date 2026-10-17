// Dev server only: /dev/roto opens a roto draft without signing in, like iOS Debug `-T1RotoDemo`. Eight players
// draft the demo Vintage cube (apps/ios/Table1/DebugResources/library-demo.json, 360 cards) 45 picks each; 114
// picks are made and it's your pick (seat 3). The draft runs locally: after your pick the others pick every 0.7 s
// until your next turn, your list auto-picks, Undo and the pick clock work. Card names come from the live catalog.
import type { RotoBackend, RotoChange } from "./roto";
import {
  clockSeconds, isAutomatic, roundOf, seatFor, type RotoClockRange, type RotoHow, type RotoPick, type RotoPoolCard,
  type RotoState,
} from "./rotoMath";

export const DEMO_EVENT = "demo-roto";
export const DEMO_NAMES = ["Ann Ito", "Bo Lindqvist", "You", "Dee Okafor", "Eli Moreau", "Fen Zhou", "Gus Varga", "Hal Brandt"];
const MY_SEAT = 3;
const PLAYERS = 8;
const PER_PLAYER = 45;
const TOTAL = PLAYERS * PER_PLAYER;
const pid = (seat: number) => `demo-p${seat}`;

/** Deterministic shuffles (mulberry32). */
function rng(seed: number) {
  let a = seed;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export class RotoDemoBackend implements RotoBackend {
  private pool: RotoPoolCard[] = [];
  private picks: RotoPick[] = [];
  private list: number[] = [];
  private autoPick = true;
  private clock: RotoClockRange[] | null = [
    { fromRound: 1, seconds: 14400 }, { fromRound: 11, seconds: 7200 }, { fromRound: 31, seconds: 1800 },
  ];
  private paused: number | null = null;
  private turnStarted = Date.now() / 1000 - 25 * 60;
  private random = rng(7);
  private listeners = new Set<(c: RotoChange) => void>();
  private timer: ReturnType<typeof setTimeout> | null = null;

  constructor(cubeCardIds: string[]) {
    this.pool = cubeCardIds.map((cardId, i) => ({ slot: i + 1, cardId, finish: "nonfoil" }));
    // A plausible first 114 picks: each seat takes from a shuffled ranking.
    const ranking = this.pool.map((c) => c.slot);
    for (let i = ranking.length - 1; i > 0; i--) {
      const j = Math.floor(this.random() * (i + 1));
      [ranking[i], ranking[j]] = [ranking[j], ranking[i]];
    }
    const start = Date.now() / 1000 - 3 * 86400;
    for (let n = 1; n <= 114; n++) {
      const how: RotoHow = n % 11 === 0 ? "auto" : n % 37 === 0 ? "timeout" : "player";
      this.picks.push({ pickNo: n, seat: seatFor(PLAYERS, n, true), slot: ranking.shift()!, how, at: start + n * 1800 });
    }
    this.list = ranking.slice(0, 12).reverse().slice(0, 5);
  }

  private get made() { return this.picks.length; }
  private taken(slot: number) { return this.picks.some((p) => p.slot === slot); }

  private snapshot(after: number, includePool: boolean): RotoState {
    const n = this.made + 1;
    const done = this.made >= TOTAL;
    const round = roundOf(PLAYERS, n);
    const seconds = clockSeconds(this.clock, round);
    const deadline = seconds != null ? this.turnStarted + seconds : null;
    const now = Date.now() / 1000;
    return {
      eventId: DEMO_EVENT,
      phase: done ? "done" : "drafting",
      draft: {
        picksPerPlayer: PER_PLAYER, pickOrder: "snake", players: PLAYERS, poolCount: this.pool.length, picksMade: this.made,
        totalPicks: TOTAL, sourceListId: "demo-cube-vintage", clock: this.clock, clockPaused: this.paused != null,
        startedAt: this.picks[0]?.at ?? null, finishedAt: done ? now : null,
      },
      onClock: done ? null : {
        participantId: pid(seatFor(PLAYERS, n, true)), seat: seatFor(PLAYERS, n, true), pickNo: n, round,
        turnStartedAt: this.turnStarted, turnSeconds: seconds,
        remainingSeconds: this.paused != null && seconds != null ? Math.max(0, seconds - Math.round(this.paused - this.turnStarted)) : null,
        deadline: this.paused == null ? deadline : null,
        overdue: this.paused == null && deadline != null && now > deadline && this.list.length === 0,
      },
      seats: DEMO_NAMES.map((name, i) => ({ seat: i + 1, participantId: pid(i + 1), displayName: name, account: i !== 5, me: i + 1 === MY_SEAT })),
      picks: this.picks.filter((p) => p.pickNo > after),
      pool: includePool ? this.pool : null,
      me: { participantId: pid(MY_SEAT), seat: MY_SEAT, queue: [...this.list], autoPick: this.autoPick, deckListId: null },
    };
  }

  private record(slot: number, how: RotoHow) {
    this.picks.push({ pickNo: this.made + 1, seat: seatFor(PLAYERS, this.made + 1, true), slot, how, at: Date.now() / 1000 });
    this.list = this.list.filter((x) => x !== slot);
    this.turnStarted = Date.now() / 1000;
  }

  /** Your list picks for you when your turn comes (auto-pick on). */
  private runAutoPicks() {
    while (this.made < TOTAL && seatFor(PLAYERS, this.made + 1, true) === MY_SEAT && this.autoPick) {
      const next = this.list.find((s) => !this.taken(s));
      if (next == null) return;
      this.record(next, "auto");
    }
  }

  private broadcast(kind: string) {
    for (const l of this.listeners) l({ kind, picksMade: this.made });
  }

  /** The other seven pick one by one until it's your turn again. */
  private simulateOthers() {
    if (this.timer) clearTimeout(this.timer);
    const step = () => {
      this.timer = null;
      if (this.paused != null || this.made >= TOTAL || seatFor(PLAYERS, this.made + 1, true) === MY_SEAT) return;
      const free = this.pool.filter((c) => !this.taken(c.slot));
      if (!free.length) return;
      this.record(free[Math.floor(this.random() * free.length)].slot, this.made % 5 === 0 ? "auto" : "player");
      this.runAutoPicks();
      this.broadcast("pick");
      this.timer = setTimeout(step, 700);
    };
    this.timer = setTimeout(step, 700);
  }

  async state(_eventId: string, after: number, pool: boolean) {
    return this.snapshot(after, pool);
  }

  async pick(_eventId: string, slot: number, pickNo: number) {
    await new Promise((r) => setTimeout(r, 120)); // a normal round trip
    if (pickNo !== this.made + 1) return { ok: false, conflict: true, state: this.snapshot(pickNo - 1, false) };
    if (this.taken(slot)) throw new Error("That card is already picked");
    this.record(slot, seatFor(PLAYERS, pickNo, true) === MY_SEAT ? "player" : "organizer");
    this.runAutoPicks();
    this.simulateOthers();
    return { ok: true, conflict: false, state: this.snapshot(pickNo - 1, false) };
  }

  async undo() {
    if (this.timer) clearTimeout(this.timer);
    let last = -1;
    this.picks.forEach((p, i) => { if (!isAutomatic(p)) last = i; });
    if (last < 0) throw new Error("Nothing to undo");
    this.picks = this.picks.slice(0, last);
    this.turnStarted = Date.now() / 1000;
    this.broadcast("undo");
    return this.snapshot(this.made, false);
  }

  async queue(_eventId: string, slots: number[], autoPick: boolean | null) {
    const seen = new Set<number>();
    this.list = slots.filter((s) => !this.taken(s) && !seen.has(s) && !!seen.add(s));
    if (autoPick != null) this.autoPick = autoPick;
    const before = this.made;
    this.runAutoPicks();
    if (this.made !== before) {
      this.broadcast("pick");
      this.simulateOthers();
    }
    return { queue: [...this.list], autoPick: this.autoPick, picksMade: this.made };
  }

  async setClock(_eventId: string, clock: RotoClockRange[] | null, paused: boolean | null) {
    if (clock) this.clock = clock.length ? clock : null;
    if (paused === true && this.paused == null) this.paused = Date.now() / 1000;
    if (paused === false && this.paused != null) {
      this.turnStarted += Date.now() / 1000 - this.paused;
      this.paused = null;
      this.simulateOthers();
    }
    return this.snapshot(this.made, false);
  }

  async expire() {
    return { picksMade: this.made, overdue: true };
  }

  listen(_eventId: string, onChange: (c: RotoChange) => void) {
    this.listeners.add(onChange);
    return () => void this.listeners.delete(onChange);
  }
}

/** The demo cube's Main board, one slot per copy. */
export async function demoCube(): Promise<string[]> {
  const f = (await import("../../../apps/ios/Table1/DebugResources/library-demo.json")).default as unknown as {
    lists: { kind: string; versions: { entries: [string, string, number][] }[] }[];
  };
  const cube = f.lists.find((l) => l.kind === "cube");
  const entries = cube?.versions[cube.versions.length - 1]?.entries ?? [];
  return entries.filter((e) => e[1] === "main").flatMap(([id, , qty]) => Array.from({ length: Math.max(1, qty) }, () => id));
}
