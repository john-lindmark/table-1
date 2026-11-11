// Shared life tracker for one match.
//
//   open      rpc tracker_open → full state, plus any ops this device queued but never sent.
//   push      local ops go into a persisted queue and are sent in batches (300 ms after the last tap,
//             and when the page is hidden) with rpc tracker_push; failures retry with backoff.
//             The server is idempotent by client_op_id and ignores ops for games already recorded.
//   live      postgres_changes INSERT on tracker_ops and tracker_games (session_id=eq.<id>); incoming
//             ops are merged by client_op_id. Every (re)subscribe re-fetches tracker_state.
//   clock     postgres_changes UPDATE on rounds (id=eq.<clock.round_id>); the row's timer_* columns
//             replace meta.clock.
//   record    flushes the queue first, then rpc tracker_record_game → full state.

import type { RealtimeChannel } from "@supabase/supabase-js";
import { supabase } from "./supabaseClient";
import { trackerOpen, trackerPush, trackerRecordGame, trackerState, type TrackerState } from "./api";
import { currentGameNo, mergeOps, type Side, type TrackerClock, type TrackerGame, type TrackerOp } from "./tracker";

export type SyncStatus = "connecting" | "live" | "offline";

export interface TrackerSnapshot {
  meta: Omit<TrackerState, "ops" | "games">;
  ops: TrackerOp[];
  games: TrackerGame[];
  status: SyncStatus;
  unsent: number;
  error: string | null;
}

const BATCH_DELAY_MS = 300;
const MAX_BATCH = 200;
const MAX_BACKOFF_MS = 30_000;
const queueKey = (sessionId: string) => `table1.trackerQueue.${sessionId}`;

function loadQueue(sessionId: string): TrackerOp[] {
  try {
    const raw = localStorage.getItem(queueKey(sessionId));
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? (parsed as TrackerOp[]) : [];
  } catch {
    return [];
  }
}

function saveQueue(sessionId: string, queue: TrackerOp[]) {
  try {
    if (queue.length) localStorage.setItem(queueKey(sessionId), JSON.stringify(queue));
    else localStorage.removeItem(queueKey(sessionId));
  } catch {
    /* storage unavailable: the in-memory queue still retries */
  }
}

const errorText = (e: unknown) => (e instanceof Error ? e.message : typeof e === "object" && e && "message" in e ? String((e as { message: unknown }).message) : String(e));
const errorCode = (e: unknown) => (typeof e === "object" && e && "code" in e ? String((e as { code: unknown }).code) : "");

export class TrackerSync {
  private meta: TrackerSnapshot["meta"] | null = null;
  private ops: TrackerOp[] = [];
  private games: TrackerGame[] = [];
  private queue: TrackerOp[] = [];
  private status: SyncStatus = "connecting";
  private error: string | null = null;
  private channel: RealtimeChannel | null = null;
  private flushTimer: number | null = null;
  private retryTimer: number | null = null;
  private backoff = 1000;
  private inflight: Promise<void> | null = null;
  private closed = false;

  constructor(
    private readonly matchId: string,
    private readonly currentUserId: () => string | null,
    private readonly onChange: (snap: TrackerSnapshot) => void,
  ) {}

  get sessionId(): string | null {
    return this.meta?.session_id ?? null;
  }

  async open(startingLife = 20): Promise<void> {
    const state = await trackerOpen(this.matchId, startingLife);
    if (this.closed) return;
    this.queue = loadQueue(state.session_id);
    this.apply(state);
    this.subscribe();
    window.addEventListener("online", this.onOnline);
    document.addEventListener("visibilitychange", this.onVisibility);
    window.addEventListener("pagehide", this.onHide);
    if (this.queue.length) this.schedule(0);
  }

  /** Local taps: shown at once, sent shortly after. */
  add(ops: TrackerOp[]) {
    if (!ops.length || !this.meta || this.meta.my_side == null) return;
    const stamped = ops.map((o) => ({ ...o, mine: true }));
    this.ops = mergeOps(this.ops, stamped);
    this.queue = mergeOps(this.queue, stamped);
    saveQueue(this.meta.session_id, this.queue);
    this.emit();
    this.schedule(BATCH_DELAY_MS);
  }

  async recordGame(gameNo: number, winnerSide: Side | null, draw: boolean): Promise<void> {
    if (!this.meta) throw new Error("The tracker isn't open yet");
    await this.flushAll();
    if (this.queue.some((o) => o.game_no === gameNo)) {
      throw new Error("Life changes are still waiting to send. Check your connection and try again.");
    }
    let state: TrackerState;
    try {
      state = await trackerRecordGame(this.meta.session_id, gameNo, winnerSide, draw);
    } catch (e) {
      // Refused because the result came in meanwhile (the other phone or the event screen): read the state so
      // Record turns off, then say why.
      await this.resync();
      throw e;
    }
    if (!this.closed) this.apply(state);
  }

  /** This device just reported the match: Record turns off without waiting for a read. */
  markResultIn() {
    if (!this.meta || this.meta.result_in) return;
    this.meta = { ...this.meta, result_in: true };
    this.emit();
  }

  close() {
    if (this.closed) return;
    // Last chance to send (fire and forget); the persisted queue covers anything that doesn't make it.
    if (this.queue.length) void this.flush();
    this.closed = true;
    if (this.flushTimer) window.clearTimeout(this.flushTimer);
    if (this.retryTimer) window.clearTimeout(this.retryTimer);
    if (this.channel) supabase.removeChannel(this.channel);
    this.channel = null;
    window.removeEventListener("online", this.onOnline);
    document.removeEventListener("visibilitychange", this.onVisibility);
    window.removeEventListener("pagehide", this.onHide);
  }

  /* ── internals ─────────────────────────────────────────────────────── */

  private apply(state: TrackerState) {
    const { ops, games, ...meta } = state;
    this.meta = meta;
    this.games = [...(games ?? [])].sort((a, b) => a.game_no - b.game_no);
    // Queued ops for a game that's since been recorded will never be accepted; let them go.
    const current = currentGameNo(this.games);
    this.queue = this.queue.filter((o) => o.game_no >= current);
    saveQueue(meta.session_id, this.queue);
    this.ops = mergeOps(ops ?? [], this.queue);
    this.emit();
  }

  private emit() {
    if (this.closed || !this.meta) return;
    this.onChange({
      meta: this.meta,
      ops: this.ops,
      games: this.games,
      status: this.status,
      unsent: this.queue.length,
      error: this.error,
    });
  }

  private setStatus(status: SyncStatus, error: string | null = this.error) {
    this.status = status;
    this.error = error;
    this.emit();
  }

  private subscribe() {
    const sid = this.meta!.session_id;
    const filter = `session_id=eq.${sid}`;
    const channel = supabase
      .channel(`tracker:${sid}`)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "tracker_ops", filter }, (payload) => {
        const r = payload.new as Record<string, unknown>;
        const op: TrackerOp = {
          client_op_id: String(r.client_op_id),
          game_no: Number(r.game_no),
          side: Number(r.side) as Side,
          counter: r.counter as TrackerOp["counter"],
          delta: Number(r.delta),
          tapped_at: String(r.tapped_at),
          mine: r.actor != null && r.actor === this.currentUserId(),
        };
        this.ops = mergeOps(this.ops, [op]);
        this.emit();
      })
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "tracker_games", filter }, (payload) => {
        const r = payload.new as Record<string, unknown>;
        const game: TrackerGame = {
          game_no: Number(r.game_no),
          winner_side: r.winner_side == null ? null : (Number(r.winner_side) as Side),
          is_draw: !!r.is_draw,
          recorded_at: String(r.recorded_at ?? new Date().toISOString()),
        };
        this.games = [...this.games.filter((g) => g.game_no !== game.game_no), game].sort((a, b) => a.game_no - b.game_no);
        this.emit();
      });
    const roundId = this.meta!.clock?.round_id;
    if (roundId) {
      channel.on("postgres_changes", { event: "UPDATE", schema: "public", table: "rounds", filter: `id=eq.${roundId}` }, (payload) => {
        const r = payload.new as Record<string, unknown>;
        if (!this.meta) return;
        const clock: TrackerClock = {
          round_id: roundId,
          timer_status: r.timer_status === "running" ? "running" : "paused",
          timer_last_started_at: r.timer_last_started_at == null ? null : String(r.timer_last_started_at),
          timer_remaining_at_change: r.timer_remaining_at_change == null ? null : Number(r.timer_remaining_at_change),
          timer_duration_seconds: Number(r.timer_duration_seconds ?? this.meta.clock?.timer_duration_seconds ?? 0),
        };
        this.meta = { ...this.meta, clock };
        this.emit();
      });
    }
    this.channel = channel;
    channel
      .subscribe((status) => {
        if (this.closed) return;
        if (status === "SUBSCRIBED") {
          // Anything that happened while we weren't listening comes back with a fresh read.
          void this.resync();
        } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT" || status === "CLOSED") {
          this.setStatus("offline");
        }
      });
  }

  private async resync() {
    if (!this.meta) return;
    try {
      const state = await trackerState(this.meta.session_id);
      if (this.closed) return;
      this.status = this.queue.length ? this.status : "live";
      if (!this.queue.length) this.error = null;
      this.apply(state);
      if (this.queue.length) this.schedule(0);
    } catch (e) {
      this.setStatus("offline", errorText(e));
    }
  }

  private schedule(delay: number) {
    if (this.closed) return;
    if (this.flushTimer) window.clearTimeout(this.flushTimer);
    this.flushTimer = window.setTimeout(() => {
      this.flushTimer = null;
      void this.flush();
    }, delay);
  }

  private flush(): Promise<void> {
    if (this.inflight) return this.inflight;
    if (!this.meta || !this.queue.length) return Promise.resolve();
    const sid = this.meta.session_id;
    const batch = this.queue.slice(0, MAX_BATCH);
    this.inflight = (async () => {
      try {
        await trackerPush(sid, batch);
        const sent = new Set(batch.map((o) => o.client_op_id));
        this.queue = this.queue.filter((o) => !sent.has(o.client_op_id));
        saveQueue(sid, this.queue);
        this.backoff = 1000;
        if (this.retryTimer) {
          window.clearTimeout(this.retryTimer);
          this.retryTimer = null;
        }
        this.setStatus("live", null);
        if (this.queue.length) this.schedule(0);
      } catch (e) {
        if (errorCode(e) === "42501") {
          // Not a player in this match (e.g. the organizer watching): these changes can never be sent.
          this.queue = [];
          saveQueue(sid, this.queue);
          this.setStatus(this.status, errorText(e));
          return;
        }
        this.setStatus("offline", errorText(e));
        if (!this.closed && !this.retryTimer) {
          const wait = this.backoff;
          this.backoff = Math.min(this.backoff * 2, MAX_BACKOFF_MS);
          this.retryTimer = window.setTimeout(() => {
            this.retryTimer = null;
            void this.flush();
          }, wait);
        }
      } finally {
        this.inflight = null;
      }
    })();
    return this.inflight;
  }

  private async flushAll() {
    for (let i = 0; i < 10 && this.queue.length; i++) {
      const before = this.queue.length;
      await this.flush();
      if (this.queue.length >= before) break; // failed; caller decides
    }
  }

  private onOnline = () => {
    void this.flush();
    void this.resync();
  };

  private onVisibility = () => {
    if (document.visibilityState === "hidden") void this.flush();
    else void this.resync();
  };

  private onHide = () => {
    void this.flush();
  };
}
