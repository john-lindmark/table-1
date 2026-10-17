// One roto draft on screen (contract/roto-2026-10-16.md): the state from the server, the pool (fetched once),
// picks (by delta), your list. Picks render at once and are replaced by the server's answer; a conflict merges the
// newer state. Mirrors apps/ios/Table1/Roto/RotoStore.swift; the Draft screens read it through useRoto().
import { useEffect, useSyncExternalStore } from "react";
import { loadCatalog, type Catalog } from "./catalog";
import { syncLists } from "./lists";
import { supabase } from "./supabaseClient";
import { capture, reportError, span } from "./telemetry";
import {
  mergePicks, picksUntil, rotoCard, roundOf, seatFor, toState, totalPicks, unknownCard,
  type RotoCard, type RotoClockRange, type RotoCubeResult, type RotoDraftInfo, type RotoMe, type RotoOnClock,
  type RotoPhase, type RotoPick, type RotoPickResult, type RotoPoolCard, type RotoQueueResult, type RotoSeat, type RotoState,
} from "./rotoMath";

/** A realtime `roto_changed` message: started | pick | timeout | undo | clock (or resubscribed). */
export interface RotoChange {
  kind: string;
  picksMade: number | null;
}

/** Everything a roto draft asks of the server. The /dev/roto demo swaps in a local draft. */
export interface RotoBackend {
  state(eventId: string, after: number, pool: boolean): Promise<RotoState>;
  pick(eventId: string, slot: number, pickNo: number): Promise<RotoPickResult>;
  undo(eventId: string): Promise<RotoState>;
  queue(eventId: string, slots: number[], autoPick: boolean | null): Promise<RotoQueueResult>;
  /** `clock` null keeps the schedule; `[]` clears it. `paused` null keeps the pause state. */
  setClock(eventId: string, clock: RotoClockRange[] | null, paused: boolean | null): Promise<RotoState>;
  expire(eventId: string): Promise<{ picksMade: number; overdue: boolean }>;
  /** Calls `onChange` per message until the returned function is called. */
  listen(eventId: string, onChange: (c: RotoChange) => void): () => void;
}

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

/* eslint-disable @typescript-eslint/no-explicit-any */
export const liveBackend: RotoBackend = {
  async state(eventId, after, pool) {
    return toState(await rpc("roto_state", { p_event_id: eventId, p_after_pick: after, p_pool: pool }));
  },
  async pick(eventId, slot, pickNo) {
    const r = await rpc<any>("roto_pick", { p_event_id: eventId, p_slot: slot, p_pick_no: pickNo });
    return { ok: !!r.ok, conflict: !!r.conflict, state: toState(r.state) };
  },
  async undo(eventId) {
    return toState(await rpc("roto_undo", { p_event_id: eventId }));
  },
  async queue(eventId, slots, autoPick) {
    const r = await rpc<any>("roto_queue_set", { p_event_id: eventId, p_slots: slots, p_auto_pick: autoPick });
    return { queue: r.queue ?? [], autoPick: r.auto_pick ?? true, picksMade: r.picks_made ?? 0 };
  },
  async setClock(eventId, clock, paused) {
    const wire = clock ? clock.map((r) => ({ from_round: r.fromRound, seconds: r.seconds })) : null;
    return toState(await rpc("roto_set_clock", { p_event_id: eventId, p_clock: wire, p_paused: paused }));
  },
  async expire(eventId) {
    const r = await rpc<any>("roto_expire", { p_event_id: eventId });
    return { picksMade: r.picks_made ?? 0, overdue: !!r.overdue };
  },
  listen(eventId, onChange) {
    // Broadcast topic roto:<event_id>. Each (re)join after the first also refreshes: anything sent while the
    // channel was away is only in roto_state.
    const channel = supabase.channel(`roto:${eventId}`);
    let joined = false;
    channel.on("broadcast", { event: "roto_changed" }, (msg: any) => {
      const p = msg?.payload ?? {};
      onChange({ kind: p.kind ?? "pick", picksMade: typeof p.picks_made === "number" ? p.picks_made : null });
    });
    channel.subscribe((status) => {
      if (status !== "SUBSCRIBED") return;
      if (joined) onChange({ kind: "resubscribed", picksMade: null });
      joined = true;
    });
    return () => void supabase.removeChannel(channel);
  },
};
/* eslint-enable @typescript-eslint/no-explicit-any */

/** One of your Library cubes becomes the draft's pool (its Main board). `from`: library / cube_cobra. */
export async function rotoSetCube(eventId: string, listId: string, from: "library" | "cube_cobra"): Promise<RotoCubeResult> {
  const r = await rpc<Record<string, unknown>>("roto_set_cube", { p_event_id: eventId, p_list_id: listId });
  const out: RotoCubeResult = {
    eventId: String(r.event_id), sourceListId: (r.source_list_id as string) ?? null, cubeName: (r.cube_name as string) ?? null,
    poolCount: Number(r.pool_count) || 0, players: Number(r.players) || 0, maxPicksPerPlayer: Number(r.max_picks_per_player) || 0,
  };
  capture("roto_cube_set", { pool: out.poolCount, from });
  return out;
}

/** Seats everyone at random (unless already seated), snapshots the cube and starts the draft. */
export async function rotoStart(eventId: string, picksPerPlayer: number, order: "snake" | "fixed", clockRanges: number): Promise<RotoState> {
  const s = toState(await rpc("roto_start", { p_event_id: eventId, p_picks_per_player: picksPerPlayer, p_order: order }));
  capture("roto_started", {
    players: s.draft.players, picks_per_player: s.draft.picksPerPlayer, pool: s.draft.poolCount, order: s.draft.pickOrder,
    clock: clockRanges > 0, clock_ranges: clockRanges,
  });
  return s;
}

/* ── the store ────────────────────────────────────────────────────── */

export type PickSource = "cube" | "grid" | "list" | "detail";

const DEBOUNCE_MS = 600;
const msg = (e: unknown) => (e instanceof Error ? e.message : e && typeof e === "object" && "message" in e ? String((e as { message: unknown }).message) : String(e));

const emptyDraft: RotoDraftInfo = {
  picksPerPlayer: 45, pickOrder: "snake", players: 0, poolCount: 0, picksMade: 0, totalPicks: null, sourceListId: null,
  clock: null, clockPaused: false, startedAt: null, finishedAt: null,
};

export class RotoStore {
  readonly eventId: string;
  readonly backend: RotoBackend;

  loaded = false;
  phase: RotoPhase = "setup";
  draft: RotoDraftInfo = emptyDraft;
  onClock: RotoOnClock | null = null;
  seats: RotoSeat[] = [];
  me: RotoMe | null = null;
  /** Slot → copy, from the first load only. */
  pool = new Map<number, RotoPoolCard>();
  /** Slots in a stable display order (by card name once the catalog answers). */
  poolOrder: number[] = [];
  picks: RotoPick[] = [];
  /** Slot → the pick that took it. */
  pickBySlot = new Map<number, RotoPick>();
  /** Your pick, shown before the server answers. */
  pending: RotoPick | null = null;
  cards = new Map<string, RotoCard>();
  catalog: Catalog | null = null;
  /** Your private list (slots, best first) and the auto-pick switch, as shown (saves are debounced). */
  queue: number[] = [];
  autoPick = true;
  /** "Taken by ANNA (#41)": cards that left your list since you last looked; shown once. */
  takenFromList: { slot: number; pick: RotoPick }[] = [];
  error: string | null = null;
  notice: string | null = null;
  busy = false;
  /** Setup: what Start draft will send (roto_start takes them; nothing is saved before). */
  planPicks = 45;
  planOrder: "snake" | "fixed" = "snake";
  gridTraced = false;

  /** Bumped on every change; React reads it through useSyncExternalStore. */
  version = 0;
  private listeners = new Set<() => void>();
  private refreshing: Promise<void> | null = null;
  private refreshAgain = false;
  private refreshFullAgain = false;
  private queueTimer: ReturnType<typeof setTimeout> | null = null;
  private queueDirty = false;
  private autoDirty = false;
  private expiring = false;
  private lastExpireFor = 0;
  private listening = 0;
  private stopListening: (() => void) | null = null;

  constructor(eventId: string, backend: RotoBackend = liveBackend) {
    this.eventId = eventId;
    this.backend = backend;
  }

  subscribe = (l: () => void) => {
    this.listeners.add(l);
    return () => void this.listeners.delete(l);
  };
  getVersion = () => this.version;
  private changed() {
    this.version++;
    this.listeners.forEach((l) => l());
  }

  /* ── derived ── */

  get picksMade() { return Math.max(this.draft.picksMade, this.picks[this.picks.length - 1]?.pickNo ?? 0) + (this.pending ? 1 : 0); }
  get total() { return totalPicks(this.draft); }
  get players() { return Math.max(this.draft.players, this.seats.length); }
  get snake() { return this.draft.pickOrder !== "fixed"; }
  get mySeat() { return this.me?.seat ?? null; }
  get isMyTurn() {
    return this.phase === "drafting" && !this.pending && !!this.onClock && this.onClock.participantId === this.me?.participantId;
  }
  get orderedSeats() { return [...this.seats].sort((a, b) => (a.seat ?? 1e9) - (b.seat ?? 1e9)); }
  seat(n: number) { return this.seats.find((s) => s.seat === n) ?? null; }
  name(seat: number) { return this.seat(seat)?.displayName ?? `Seat ${seat}`; }
  card(slot: number): RotoCard | null {
    const c = this.pool.get(slot);
    return c ? this.cards.get(c.cardId) ?? unknownCard(c.cardId) : null;
  }
  /** The pick at a number, including your pending one. */
  pick(no: number): RotoPick | null {
    if (this.pending?.pickNo === no) return this.pending;
    const p = this.picks[no - 1];
    return p?.pickNo === no ? p : this.picks.find((x) => x.pickNo === no) ?? null;
  }
  takenBy(slot: number): RotoPick | null {
    if (this.pending?.slot === slot) return this.pending;
    return this.pickBySlot.get(slot) ?? null;
  }
  picksOf(seat: number): RotoPick[] {
    const out = this.picks.filter((p) => p.seat === seat);
    if (this.pending?.seat === seat) out.push(this.pending);
    return out;
  }
  inList(slot: number): number | null {
    const i = this.queue.indexOf(slot);
    return i < 0 ? null : i + 1;
  }
  /** Picks before yours (0 = your pick); null when you're not drafting or have no picks left. */
  get picksUntilMine(): number | null {
    if (this.phase !== "drafting" || this.mySeat == null) return null;
    return picksUntil(this.mySeat, this.picksMade, this.players, this.total, this.snake);
  }
  /** Seconds left on the current turn at `now` (ms); null without a clock (or between turns). */
  secondsLeft(now: number): number | null {
    const c = this.onClock;
    if (!c || this.pending) return null;
    if (this.draft.clockPaused) return c.remainingSeconds;
    if (c.deadline == null) return null;
    return Math.max(0, Math.ceil(c.deadline - now / 1000));
  }

  /* ── loading ── */

  /** First load: everything, pool included. Later calls fetch picks by delta. */
  async load(): Promise<void> {
    if (this.loaded) return this.refresh();
    const sp = span("roto.state", "load");
    try {
      const s = await this.backend.state(this.eventId, 0, true);
      this.applyFull(s);
      this.loaded = true;
      this.error = null;
      sp.finish();
      this.changed();
      void this.resolveCards();
    } catch (e) {
      sp.finish(false);
      this.error = msg(e);
      this.changed();
    }
  }

  /** Delta: picks after the last one held. A burst of calls runs at most one more time after the current one. */
  refresh(full = false): Promise<void> {
    if (!this.loaded) return this.load();
    if (this.refreshing) {
      this.refreshAgain = true;
      this.refreshFullAgain ||= full;
      return this.refreshing;
    }
    this.refreshing = (async () => {
      // The pool exists only once the draft starts: a store loaded in Setup fetches it then, once.
      let wantFull = full || this.pool.size === 0;
      do {
        this.refreshAgain = false;
        wantFull ||= this.refreshFullAgain;
        this.refreshFullAgain = false;
        const after = wantFull ? 0 : this.picks[this.picks.length - 1]?.pickNo ?? 0;
        const sp = span("roto.state", wantFull ? "full" : "delta");
        try {
          const wantPool = this.pool.size === 0;
          const s = await this.backend.state(this.eventId, after, wantPool);
          sp.finish();
          if (wantFull) {
            this.applyFull(s);
            if (wantPool && this.pool.size > 0) void this.resolveCards();
          } else {
            const merged = mergePicks(this.picks, s.picks, s.draft.picksMade);
            if (merged.needsFull) {
              wantFull = true;
              this.refreshAgain = true;
              continue;
            }
            this.apply(s, merged.picks);
          }
          wantFull = false;
          this.error = null;
        } catch (e) {
          sp.finish(false);
          this.error = msg(e);
        }
        this.changed();
      } while (this.refreshAgain);
    })().finally(() => {
      this.refreshing = null;
    });
    return this.refreshing;
  }

  /** A state that carries every pick (first load, full refresh). */
  private applyFull(s: RotoState) {
    if (s.pool && s.pool.length > 0) {
      this.pool = new Map(s.pool.map((c) => [c.slot, c]));
      this.poolOrder = s.pool.map((c) => c.slot).sort((a, b) => a - b);
      this.sortPool();
    }
    this.apply(s, [...s.picks].sort((a, b) => a.pickNo - b.pickNo));
  }

  private apply(s: RotoState, merged: RotoPick[]) {
    const wasList = new Set(this.queue);
    this.phase = s.phase;
    this.draft = s.draft;
    this.onClock = s.onClock;
    if (s.seats.length) this.seats = s.seats;
    if (s.me) {
      this.me = s.me;
      // Your list as the server kept it (taken cards dropped), unless an edit is still waiting to be sent.
      if (!this.queueDirty) {
        this.queue = s.me.queue;
        this.autoPick = s.me.autoPick;
      }
    }
    this.setPicks(merged);
    this.pending = null;
    // Cards on your list someone else took since the last look.
    const mine = this.me?.seat;
    const gone: { slot: number; pick: RotoPick }[] = [];
    for (const slot of wasList) {
      const p = this.pickBySlot.get(slot);
      if (p && p.seat !== mine) gone.push({ slot, pick: p });
    }
    if (gone.length) {
      this.takenFromList = [...this.takenFromList, ...gone];
      this.queue = this.queue.filter((x) => !this.pickBySlot.has(x));
    }
  }

  private setPicks(p: RotoPick[]) {
    this.picks = p;
    this.pickBySlot = new Map(p.map((x) => [x.slot, x]));
  }

  private sortPool() {
    const name = (slot: number) => {
      const c = this.pool.get(slot);
      return (c && this.cards.get(c.cardId)?.name) || "";
    };
    this.poolOrder = [...this.pool.keys()].sort((a, b) => name(a).localeCompare(name(b)) || a - b);
  }

  /** Card names and colours for the whole pool, read once from the local catalog. */
  async resolveCards(catalog?: Catalog): Promise<void> {
    try {
      const c = catalog ?? (await loadCatalog());
      this.catalog = c;
      for (const { cardId } of this.pool.values()) {
        if (this.cards.has(cardId)) continue;
        const p = c.printingIndex.get(cardId);
        if (p === undefined) continue;
        const oi = c.pOracle[p];
        this.cards.set(cardId, rotoCard(cardId, c.oName[oi], c.oType[oi], c.oCost[oi], p));
      }
      this.sortPool();
      this.changed();
    } catch (e) {
      if (!(e instanceof TypeError)) reportError(e, "roto_cards");
    }
  }

  /** Setup: picks per player and order for Start draft. */
  setPlan(p: { picks?: number; order?: "snake" | "fixed" }) {
    if (p.picks != null) this.planPicks = p.picks;
    if (p.order) this.planOrder = p.order;
    this.changed();
  }

  dismissTaken() {
    if (!this.takenFromList.length) return;
    this.takenFromList = [];
    this.changed();
  }

  /* ── picking ── */

  /**
   * Picks `slot` for whoever is on the clock: you on your turn, or (organizer) Pick for. Renders at once; the
   * server's answer replaces it. Resolves true when the server took the pick.
   */
  async pickSlot(slot: number, from: PickSource): Promise<boolean> {
    const clock = this.onClock;
    if (this.phase !== "drafting" || !clock || this.pending || this.takenBy(slot)) return false;
    const pickNo = this.draft.picksMade + 1;
    const seat = clock.seat > 0 ? clock.seat : seatFor(this.players, pickNo, this.snake);
    const mine = clock.participantId === this.me?.participantId;
    const how = mine ? "player" : "organizer";
    this.pending = { pickNo, seat, slot, how, at: Date.now() / 1000 };
    this.queue = this.queue.filter((x) => x !== slot);
    this.error = null;
    this.notice = null;
    this.changed();
    const sp = span("roto.pick", "tap_to_answer");
    const secondsOnClock = clock.turnStartedAt ? Math.max(0, Math.round(Date.now() / 1000 - clock.turnStartedAt)) : 0;
    try {
      const r = await this.backend.pick(this.eventId, slot, pickNo);
      sp.finish();
      const merged = mergePicks(this.picks, r.state.picks, r.state.draft.picksMade);
      this.apply(r.state, merged.picks);
      if (!r.ok) this.notice = "Someone picked first. Have another look.";
      this.changed();
      if (merged.needsFull) await this.refresh(true);
      if (r.ok) {
        capture("roto_picked", {
          how, from, round: clock.round || roundOf(this.players, pickNo), seconds_on_clock: secondsOnClock,
          auto_followed: Math.max(0, r.state.draft.picksMade - pickNo),
        });
      }
      return r.ok;
    } catch (e) {
      sp.finish(false);
      this.pending = null;
      this.error = msg(e);
      this.changed();
      await this.refresh();
      return false;
    }
  }

  /** Organizer: removes the last pick a person made and the automatic picks after it. */
  async undo(): Promise<void> {
    this.busy = true;
    this.changed();
    const before = this.picksMade;
    try {
      const s = await this.backend.undo(this.eventId);
      this.apply(s, mergePicks(this.picks, s.picks, s.draft.picksMade).picks);
      capture("roto_pick_undone", { picks_removed: Math.max(0, before - s.draft.picksMade) });
      this.error = null;
      await this.refresh(true);
    } catch (e) {
      this.error = msg(e);
    } finally {
      this.busy = false;
      this.changed();
    }
  }

  /** Organizer: a new schedule (`[]` clears it), or pause / resume with `paused`. */
  async setClock(ranges: RotoClockRange[] | null, paused: boolean | null = null): Promise<boolean> {
    this.busy = true;
    this.changed();
    try {
      const s = await this.backend.setClock(this.eventId, ranges, paused);
      this.phase = s.phase;
      this.draft = s.draft;
      this.onClock = s.onClock;
      const action = paused != null ? (paused ? "pause" : "resume") : (ranges ?? []).length === 0 ? "clear" : "set";
      capture("roto_clock_changed", { action, ranges: s.draft.clock?.length ?? 0 });
      this.error = null;
      return true;
    } catch (e) {
      this.error = msg(e);
      return false;
    } finally {
      this.busy = false;
      this.changed();
    }
  }

  /** A countdown reached zero here: ask the server to apply the timeout (no-op if it's early or already done). */
  expireIfDue(now = Date.now()) {
    const c = this.onClock;
    if (this.phase !== "drafting" || this.expiring || !c || this.draft.clockPaused || c.overdue || c.deadline == null) return;
    if (now / 1000 < c.deadline || this.lastExpireFor === c.pickNo) return;
    this.expiring = true;
    this.lastExpireFor = c.pickNo;
    void this.backend
      .expire(this.eventId)
      .catch(() => undefined)
      .then(() => this.refresh())
      .finally(() => {
        this.expiring = false;
      });
  }

  /* ── your list ── */

  addToList(slot: number) { this.editList((q) => (q.includes(slot) ? q : [...q, slot])); }
  removeFromList(slot: number) { this.editList((q) => q.filter((x) => x !== slot)); }
  moveInList(from: number, to: number) {
    this.editList((q) => {
      const next = [...q];
      const [x] = next.splice(from, 1);
      next.splice(Math.max(0, Math.min(next.length, to)), 0, x);
      return next;
    });
  }
  setAutoPick(on: boolean) {
    this.autoPick = on;
    this.autoDirty = true;
    this.scheduleQueueSave();
  }

  private editList(change: (q: number[]) => number[]) {
    const q = change(this.queue);
    if (q.length === this.queue.length && q.every((x, i) => x === this.queue[i])) return;
    this.queue = q;
    this.scheduleQueueSave();
  }

  /** The whole list, ~600 ms after the last change (one save per pause, not per drag). */
  private scheduleQueueSave() {
    this.queueDirty = true;
    this.changed();
    if (this.queueTimer) clearTimeout(this.queueTimer);
    this.queueTimer = setTimeout(() => {
      this.queueTimer = null;
      void this.saveQueue();
    }, DEBOUNCE_MS);
  }

  private async saveQueue() {
    const slots = this.queue, auto = this.autoPick, sendAuto = this.autoDirty;
    this.autoDirty = false;
    try {
      const r = await this.backend.queue(this.eventId, slots, sendAuto ? auto : null);
      if (this.queueTimer) return; // edited again while this was in flight: the next save sends it
      this.queueDirty = false;
      if (this.queue === slots) this.queue = r.queue;
      this.autoPick = r.autoPick;
      capture("roto_list_changed", { cards: r.queue.length, auto_pick: r.autoPick });
      this.changed();
      if (r.picksMade !== this.draft.picksMade) await this.refresh();
    } catch (e) {
      this.queueDirty = false;
      this.error = msg(e);
      this.changed();
    }
  }

  /* ── realtime ── */

  /** Starts (or shares) the realtime subscription; the returned function stops this caller's share. */
  listen(): () => void {
    if (this.listening++ === 0) {
      this.stopListening = this.backend.listen(this.eventId, (c) => {
        if (c.kind === "pick" && c.picksMade != null && c.picksMade === this.draft.picksMade) return;
        void this.refresh(c.kind === "undo" || c.kind === "resubscribed");
      });
    }
    let stopped = false;
    return () => {
      if (stopped) return;
      stopped = true;
      if (--this.listening === 0) {
        this.stopListening?.();
        this.stopListening = null;
      }
    };
  }

  /** The deck is created on the server when the draft starts; sync the Library first so it's there. */
  async openDeckId(): Promise<string | null> {
    const id = this.me?.deckListId ?? null;
    if (id) await syncLists().catch(() => undefined);
    return id;
  }
}

/* ── one store per event ──────────────────────────────────────────── */

const stores = new Map<string, RotoStore>();

/** One store per roto event, shared by Setup, the Draft phase and Live, so the pool is fetched once. */
export function rotoStore(eventId: string): RotoStore {
  let s = stores.get(eventId);
  if (!s) {
    s = new RotoStore(eventId);
    putRotoStore(s);
  }
  return s;
}

export function putRotoStore(s: RotoStore) {
  stores.delete(s.eventId);
  stores.set(s.eventId, s);
  while (stores.size > 4) stores.delete(stores.keys().next().value!);
}

/**
 * The store for a roto event, loaded and listening while mounted (null when `enabled` is false). Re-renders on
 * every change; also refreshes in full when the tab comes back to the foreground.
 */
export function useRoto(eventId: string | null, enabled = true): RotoStore | null {
  const store = eventId && enabled ? rotoStore(eventId) : null;
  useSyncExternalStore(store?.subscribe ?? noopSubscribe, store?.getVersion ?? zero);
  useEffect(() => {
    if (!store) return;
    void store.load();
    const stop = store.listen();
    const onVisible = () => document.visibilityState === "visible" && void store.refresh(true);
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      stop();
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [store]);
  return store;
}

const noopSubscribe = () => () => undefined;
const zero = () => 0;

/** Re-renders on every change of a store you already hold (the Draft screens). */
export function useRotoStore(store: RotoStore): RotoStore {
  useSyncExternalStore(store.subscribe, store.getVersion);
  return store;
}
