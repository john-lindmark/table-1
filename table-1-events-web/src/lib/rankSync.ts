/* Saving a cube ranking (contract/cube-rankings-2026-10-21.md, "Saving"; reference testdata/ranking-save/make_cases.py,
   shared cases in testdata/ranking-save/cases.json, read by iOS RankSyncTests and Android RankSyncTest too).
   Twice on 2026-10-23 an iPhone wiped a 500-screen ranking: overlapping saves hit a conflict, the recovery cleared the
   app's copy of the server's log, and a save still waiting worked out "keep 0, add 1" from it. Now nothing is worked out
   by comparing logs: the app keeps the server's log as it last said it is, plus what was done here and not yet saved
   (lock-ins and picks to add, undone or redone screens to drop), and everything shown and sent comes from plan().
   Removals are only ever ones the person made. */
import type { RankChange, RankScreen } from "./cubeRanking";

/** What makes two screens the same screen: session, cards in order and time in whole ms (the server's rule too). */
export const screenKey = (s: RankScreen) => `${s.s}|${s.o.join(",").toLowerCase()}|${s.t == null ? "" : Math.round(s.t)}`;

export interface SavePlan { log: RankScreen[]; add: RankScreen[]; drop: RankScreen[]; keep: number; removed: number }

export function plan(server: RankScreen[], adds: RankScreen[], drops: RankScreen[]): SavePlan {
  const log = server.map((screen) => ({ screen, added: false }));
  const have = new Set(server.map(screenKey));
  for (const a of adds) {
    const k = screenKey(a);
    if (have.has(k)) continue;
    log.push({ screen: a, added: true });
    have.add(k);
  }
  const drop: RankScreen[] = [];
  for (const d of drops) {
    const k = screenKey(d);
    const i = log.findIndex((x) => screenKey(x.screen) === k);
    if (i < 0) continue;
    const [gone] = log.splice(i, 1);
    if (!gone.added) drop.push(d);
  }
  return { log: log.map((x) => x.screen), add: log.filter((x) => x.added).map((x) => x.screen), drop, keep: server.length, removed: drop.length };
}

/** What's waiting to be saved for one ranking, kept on the device so a closed tab or no signal loses nothing. */
export interface RankPending {
  adds: RankScreen[];
  drops: RankScreen[];
  changes: RankChange[];
  /** The push being sent: retried with the same op id, so one that landed isn't applied twice. */
  op?: { id: string; rev: number; count: number; adds: number; drops: number; changes: number } | null;
}
export const emptyPending = (): RankPending => ({ adds: [], drops: [], changes: [], op: null });
export const isEmpty = (p: RankPending) => !p.adds.length && !p.drops.length && !p.changes.length;

/** After a save: what it sent is no longer waiting (anything done meanwhile stays, in order). */
export function settle(p: RankPending, op: NonNullable<RankPending["op"]>): RankPending {
  return { adds: p.adds.slice(op.adds), drops: p.drops.slice(op.drops), changes: p.changes.slice(op.changes), op: null };
}

/** Pending work in localStorage, per ranking (it survives a closed tab or a crash; private windows may refuse it). */
export const pendingStore = {
  load(id: string): RankPending {
    try {
      const raw = localStorage.getItem(`t1.ranking.pending.${id.toLowerCase()}`);
      if (!raw) return emptyPending();
      const p = JSON.parse(raw) as RankPending;
      return { adds: p.adds ?? [], drops: p.drops ?? [], changes: p.changes ?? [], op: p.op ?? null };
    } catch { return emptyPending(); }
  },
  save(id: string, p: RankPending) {
    try {
      const k = `t1.ranking.pending.${id.toLowerCase()}`;
      if (isEmpty(p)) localStorage.removeItem(k); else localStorage.setItem(k, JSON.stringify(p));
    } catch { /* storage refused: it stays in memory and is still sent */ }
  },
};

export interface PushArgs { rev: number; count: number; add: RankScreen[]; drop: RankScreen[]; changes: RankChange[]; opId: string }

export interface SaveIO<R extends { rev: number; screens: number }, D extends { rev: number; log: RankScreen[] }> {
  /** cube_ranking_push with p_keep = p_count = count, p_removed = drop.length. */
  push(a: PushArgs): Promise<R>;
  /** cube_ranking_get, after a conflict. */
  reload(): Promise<D>;
  isConflict(e: unknown): boolean;
  storage: { load(): RankPending; save(p: RankPending): void };
  /** Waits before a retry (tests make it instant). */
  wait?: (ms: number) => Promise<void>;
  newId?: () => string;
}

/** Retries after a failure: 2 s, 5 s, 15 s, 30 s, then every minute. */
export const RETRY_MS = [2000, 5000, 15000, 30000, 60000];

/** One ranking's saving: the server's log, what's waiting, and one push at a time until nothing is. Each push names
 *  exactly what it adds and takes out against the log the server last sent; the server refuses it unless its log is that
 *  log, so a stale push can only cause a reload, never a loss. After a conflict the log is read again and what's waiting
 *  goes on top of it: nothing done here is thrown away. With no signal it's kept and tried again. */
export class RankSaver<R extends { rev: number; screens: number }, D extends { rev: number; log: RankScreen[] }> {
  server: RankScreen[] = [];
  rev = 0;
  pending: RankPending;
  saving = false;
  failures = 0;
  error: string | null = null;
  private retry: ReturnType<typeof setTimeout> | null = null;
  /** A push landed: the row it answered with. */
  onSaved: (r: R) => void = () => {};
  /** A conflict made it read the log again: the detail, and whether someone else had changed it. */
  onReloaded: (d: D, theirs: boolean) => void = () => {};
  onChange: () => void = () => {};

  constructor(private io: SaveIO<R, D>) { this.pending = io.storage.load(); }

  get log() { return plan(this.server, this.pending.adds, this.pending.drops).log; }
  get unsaved() { return !isEmpty(this.pending); }
  get waitingScreens() { return this.pending.adds.length + this.pending.drops.length; }

  /** The server's log, read (not while a push is out: that push reloads if it has to). */
  adopt(log: RankScreen[], rev: number) {
    if (this.saving) return;
    this.server = log;
    this.rev = rev;
    if (this.unsaved) this.save();
  }

  add(s: RankScreen) { this.pending.adds.push(s); this.save(); }
  drop(ss: RankScreen[]) { this.pending.drops.push(...ss); }
  changes(rows: RankChange[]) { this.pending.changes.push(...rows); this.keep(); }

  private keep() { this.io.storage.save(this.pending); }

  save() {
    this.keep();
    if (this.saving || !this.unsaved) return;
    this.saving = true;
    if (this.retry) { clearTimeout(this.retry); this.retry = null; }
    void this.flush().finally(() => { this.saving = false; this.onChange(); });
  }

  /** Resolves once nothing is waiting or a failure has scheduled a retry. */
  async flush() {
    let conflicts = 0;
    while (this.unsaved) {
      const p = plan(this.server, this.pending.adds, this.pending.drops);
      const o = this.pending.op;
      const op = o && o.rev === this.rev && o.count === this.server.length && o.adds === this.pending.adds.length
        && o.drops === this.pending.drops.length && o.changes === this.pending.changes.length ? o
        : { id: this.io.newId?.() ?? crypto.randomUUID().toLowerCase(), rev: this.rev, count: this.server.length,
            adds: this.pending.adds.length, drops: this.pending.drops.length, changes: this.pending.changes.length };
      this.pending.op = op;
      this.keep();
      try {
        const r = await this.io.push({ rev: this.rev, count: p.keep, add: p.add, drop: p.drop, changes: this.pending.changes.slice(0, op.changes), opId: op.id });
        if (r.screens !== p.log.length) throw new Mismatch();
        this.server = p.log;
        this.rev = r.rev;
        this.pending = settle(this.pending, op);
        this.keep();
        this.failures = 0;
        this.error = null;
        this.onSaved(r);
      } catch (e) {
        if (this.io.isConflict(e) || e instanceof Mismatch) {
          conflicts++;
          this.pending.op = null;
          let d: D | null = null;
          if (conflicts <= 5) { try { d = await this.io.reload(); } catch { d = null; } }
          if (!d) {
            this.error = "Couldn't save just now. What you've done is kept on this device and saved when Table 1 can.";
            this.later();
            return;
          }
          const theirs = JSON.stringify(d.log) !== JSON.stringify(this.server);
          this.server = d.log;
          this.rev = d.rev;
          this.onReloaded(d, theirs);
        } else {
          this.error = `Not saved yet: ${(e as Error).message}. It's kept on this device and saved when Table 1 can.`;
          this.later();
          return;
        }
      }
      this.onChange();
    }
  }

  private later() {
    this.failures++;
    const ms = RETRY_MS[Math.min(this.failures, RETRY_MS.length) - 1];
    if (this.io.wait) { void this.io.wait(ms).then(() => this.save()); return; }
    this.retry = setTimeout(() => { this.retry = null; this.save(); }, ms);
  }

  stop() { if (this.retry) clearTimeout(this.retry); this.retry = null; }
}

/** A push answered with a log of the wrong length: read the log again. */
export class Mismatch extends Error { constructor() { super("The saved ranking didn't match"); } }
