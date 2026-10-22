// Cube rankings (contract/cube-rankings-2026-10-21.md): stack-rank a cube's cards, cuberanker.com style, refined with
// P1P1 picks. The server keeps each ranking's screen log and change log; everything shown is worked out here from the
// log (lib/cubeRanking.ts). One RankingModel per open ranking is shared by its screens: it holds the log, saves one push
// at a time, and re-reads someone else's ranking while it's open so it can be watched live. Same as iOS Rankings.swift.
import { useEffect, useSyncExternalStore } from "react";
import { coverPrinting, type Catalog } from "./catalog";
import { keysOf } from "./cardGrouping";
import {
  COLOR_JOBS, JOB_TITLE, Knowledge, RankingState, diffPlaces, disagreements as disagreementsOf, pack as packOf, pickWins, reaskOpen,
  jobOfColor, type RankChange, type RankJob, type RankScreen, type RankSession,
} from "./cubeRanking";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";

export interface Person { user_id: string; display_name: string; handle?: string | null; avatar_url?: string | null }
export interface RankingCube {
  id: string; name: string; mine: boolean; owner?: Person | null; can_see?: boolean; cards?: string[];
  /** cube_ranking_get only: Oracle id → the printing the cube holds, so cards show as they are in the cube. */
  printings?: Record<string, string>;
}
export interface RankingRow {
  id: string; list_id: string; name: string; depth: "half" | "full"; top: number; sharing: "cube" | "private";
  screens: number; rev: number; sorted: number; categories: number; ranked: number; updated_at?: string; mine: boolean;
  by?: Person | null; cube?: RankingCube | null;
}
export interface CubeRankings { cube: RankingCube | null; can_rank: boolean; rankings: RankingRow[] }
/** rankable_cubes: someone else's cube you can rank, with how many rankings of it you can see and how many are yours. */
export interface RankableCube { id: string; name: string; owner: Person | null; cards: number; rankings: number; mine: number }
export interface RankingDetail extends RankingRow { log: RankScreen[]; changes: RankChange[]; cube: RankingCube | null }

export const whose = (r: RankingRow) => (r.mine ? "Your ranking" : `${r.by?.display_name ?? "Someone"}'s ranking`);
export const progressText = (r: RankingRow) => `${r.sorted}/${r.categories} sorted · ${r.ranked}/${r.top} ranked`;
export const shortDate = (iso?: string) => (iso ? new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric" }) : null);

/* ── server (or the dev demo) ───────────────────────────────────────── */

let demo: DemoRankings | null = null;
export const rankingsDemo = () => demo;

async function rpc<T>(name: string, params: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(name, params);
  if (error) throw Object.assign(new Error(error.message), { code: error.code });
  return data as T;
}

export const fetchRankings = (listId: string | null): Promise<CubeRankings> =>
  demo ? Promise.resolve(demo.rankings(listId)) : rpc("cube_rankings", { p_list_id: listId });

/** ranking-brief: Claude's 2-5 sentence comparison of two rankings for one list, or why there isn't one yet. */
export interface RankingBrief { brief: string | null; reason?: string; cached?: boolean; /** The dev demo's stand-in. */ sample?: boolean }
const briefs = new Map<string, RankingBrief>();

/** The brief comparing ranking `a` with `b` on one list (written once per change on the server; kept for the session). */
export async function fetchBrief(a: string, b: string, list: RankJob): Promise<RankingBrief> {
  const key = `${a}|${b}|${list}`;
  const hit = briefs.get(key);
  if (hit) return hit;
  let r: RankingBrief;
  if (demo) r = demo.brief(a, b, list);
  else {
    const { data, error } = await supabase.functions.invoke("ranking-brief", { body: { a, b, list } });
    if (error) {
      let message = "The brief couldn't be written just now.";
      const ctx = (error as { context?: unknown }).context;
      if (ctx && typeof (ctx as Response).json === "function") {
        try { const payload = await (ctx as Response).clone().json(); if (payload?.error) message = String(payload.error); } catch { /* not JSON */ }
      }
      throw new Error(message);
    }
    r = data as RankingBrief;
  }
  if (r.brief || r.reason) briefs.set(key, r);
  capture(r.brief ? "ranking_brief_shown" : "ranking_brief_missing", { list, cached: !!r.cached });
  return r;
}

/** Other people's cubes you can see and rank (friends' and people you've played with). */
export const fetchRankable = (): Promise<RankableCube[]> => (demo ? Promise.resolve(demo.rankable()) : rpc("rankable_cubes", {}));

export const fetchRanking = (id: string): Promise<RankingDetail> => (demo ? Promise.resolve(demo.get(id)) : rpc("cube_ranking_get", { p_id: id }));

export async function createRanking(o: { listId: string; name: string; depth: "half" | "full"; top: number; sharing: "cube" | "private"; ownCube: boolean }) {
  const id = crypto.randomUUID().toLowerCase();
  const row: RankingRow = demo ? demo.create(id, o.listId, o.name, o.depth, o.top, o.sharing)
    : await rpc("cube_ranking_create", { p_id: id, p_list_id: o.listId, p_name: o.name, p_depth: o.depth, p_top: o.top, p_sharing: o.sharing });
  capture("ranking_created", { depth: o.depth, top: o.top, sharing: o.sharing, own_cube: o.ownCube });
  return row;
}

export async function deleteRanking(id: string) {
  if (demo) demo.delete(id);
  else await rpc("cube_ranking_delete", { p_id: id });
  models.delete(id);
  capture("ranking_deleted");
}

/* ── cards ──────────────────────────────────────────────────────────── */

export interface RankCard { oracleId: string; name: string; p: number | null }
const oracleIndex = new WeakMap<Catalog, Map<string, number>>();
function oracleOf(c: Catalog, id: string): number | undefined {
  let m = oracleIndex.get(c);
  if (!m) { m = new Map(c.oId.map((o, i) => [o.toLowerCase(), i])); oracleIndex.set(c, m); }
  return m.get(id.toLowerCase());
}

/** The cube's cards with how they show and their color; cards the pack doesn't know are left out. Each shows in the
 *  printing the cube holds (`printings`), else its usual art. */
export function resolveCards(c: Catalog, ids: string[], printings: Record<string, string> = {}): { cards: Map<string, RankCard>; jobs: Map<string, RankJob> } {
  const cards = new Map<string, RankCard>(), jobs = new Map<string, RankJob>();
  for (const raw of ids) {
    const id = raw.toLowerCase();
    const oi = oracleOf(c, id);
    if (oi == null) continue;
    const job = jobOfColor(keysOf(c, oi).color);
    if (!job) continue;
    const held = printings[id] ?? printings[raw];
    const p = held != null ? c.printingIndex.get(held.toLowerCase()) : undefined;
    cards.set(id, { oracleId: id, name: c.oName[oi], p: p ?? coverPrinting(c, oi) });
    jobs.set(id, job);
  }
  return { cards, jobs };
}

/* ── one open ranking ───────────────────────────────────────────────── */

const now = () => Math.round(Date.now());

export class RankingModel {
  readonly id: string;
  row: RankingRow | null = null;
  cube: RankingCube | null = null;
  log: RankScreen[] = [];
  changes: RankChange[] = [];
  state: RankingState | null = null;
  cards = new Map<string, RankCard>();
  reask: { job: RankJob; cards: string[] } | null = null;
  error: string | null = null;
  notice: string | null = null;
  cubeGone = false;
  version = 0;
  private serverLog: RankScreen[] = [];
  private pending: RankChange[] = [];
  private saving = false;
  private force = false;
  private op: { keep: number; count: number; id: string } | null = null;
  private lastChange = Date.now();
  private listeners = new Set<() => void>();
  private catalog: Catalog | null = null;

  constructor(id: string) { this.id = id; }

  subscribe = (l: () => void) => { this.listeners.add(l); return () => this.listeners.delete(l); };
  private bump() { this.version++; this.listeners.forEach((l) => l()); }

  get mine() { return this.row?.mine ?? false; }
  get unsaved() { return JSON.stringify(this.log) !== JSON.stringify(this.serverLog); }
  card(id: string) { return this.cards.get(id.toLowerCase()); }
  cardAt(x: number) { return this.state ? this.cards.get(this.state.id(x)) : undefined; }

  async load(catalog: Catalog) {
    this.catalog = catalog;
    try {
      this.adopt(await fetchRanking(this.id));
      this.error = null;
    } catch (e) {
      this.error = (e as Error).message;
    }
    this.bump();
  }

  private adopt(d: RankingDetail) {
    const same = JSON.stringify(d.log) === JSON.stringify(this.serverLog);
    const changed = !same || this.row?.depth !== d.depth || this.row?.top !== d.top || !this.state;
    this.row = d;
    this.cube = d.cube;
    if (changed) this.lastChange = Date.now();
    if (this.saving || (this.unsaved && same)) return;
    this.serverLog = d.log;
    this.log = d.log.slice();
    this.changes = d.changes ?? [];
    this.pending = [];
    if (changed || !this.cards.size) this.rebuild(d.cube?.cards ?? null);
  }

  private rebuild(cubeCards: string[] | null) {
    if (!this.row || !this.catalog) return;
    this.cubeGone = cubeCards == null;
    const ids = cubeCards ?? (this.cards.size ? [...this.cards.keys()] : [...new Set(this.log.flatMap((s) => s.o))]);
    const { cards, jobs } = resolveCards(this.catalog, ids, this.cube?.printings);
    this.cards = cards;
    this.state = new RankingState(this.id, jobs, this.log, this.row.depth, this.row.top);
  }

  private rebuildState() {
    if (!this.state || !this.row) return;
    this.state = new RankingState(this.id, this.state.category, this.log, this.row.depth, this.row.top);
  }

  /** The next screen of a job: a redone screen's cards first while their order is open. */
  question(job: RankJob): { session: RankSession; cards: number[]; pinned: number[] } | null {
    if (!this.state) return null;
    const s = this.state.session(job);
    if (!s.question) return { session: s, cards: [], pinned: [] };
    if (this.reask?.job === job && reaskOpen(this.state.knowledge, s, this.reask.cards)) {
      return { session: s, cards: this.state.knowledge.indexes(this.reask.cards), pinned: [] };
    }
    return { session: s, cards: s.question, pinned: s.pinned };
  }

  private record(before: RankingState | null, after: RankingState | null, by: string, screen: number | undefined, only?: RankJob[]) {
    if (!before || !after) return;
    const t = now();
    const rows = diffPlaces(before.places(only), after.places(only)).map((c) => ({ ...c, t, by, ...(screen ? { n: screen } : {}) }));
    this.changes = [...this.changes, ...rows];
    this.pending.push(...rows);
  }

  lockIn(job: RankJob, order: number[]) {
    if (!this.mine || !this.state) return;
    const st = this.state;
    const screen: RankScreen = { s: job, o: order.map((x) => st.id(x)), t: now() };
    const wasDone = st.session(job).done;
    this.log = [...this.log, screen];
    this.reask = null;
    const next = st.appending(screen);
    this.state = next;
    this.record(st, next, "screen", this.log.length, job === "F" ? undefined : [job, "F"]);
    if (!wasDone && next.session(job).done) capture("ranking_job_done", { job, screens: next.knowledge.perJob[job] ?? 0 });
    this.bump();
    this.save();
  }

  undo(job: RankJob) {
    if (!this.mine) return;
    const i = this.log.map((s) => s.s).lastIndexOf(job);
    if (i < 0) return;
    const removed = this.log[i];
    this.log = this.log.filter((_, k) => k !== i);
    this.reask = { job, cards: removed.o };
    capture("ranking_undo");
    const before = this.state;
    this.rebuildState();
    this.record(before, this.state, "undo", i + 1);
    this.bump();
    this.save();
  }

  redo(i: number) {
    if (!this.mine || !this.log[i]) return;
    const removed = this.log[i];
    this.log = this.log.filter((_, k) => k !== i);
    this.reask = removed.s === "P" ? null : { job: removed.s, cards: removed.o };
    capture("ranking_redo");
    const before = this.state;
    this.rebuildState();
    this.record(before, this.state, "redo", i + 1);
    this.bump();
    this.save();
  }

  redoChangesNothing(i: number) {
    if (!this.state || !this.log[i]) return false;
    return new Knowledge(this.state.knowledge.ids, this.log.filter((_, k) => k !== i)).same(this.state.knowledge);
  }

  /* P1P1 */
  get pack(): string[] { return this.state ? packOf(this.id, this.state.knowledge) : []; }
  disagreements(picked: string, pk: string[]) { return this.state ? disagreementsOf(this.state.knowledge, picked, pk) : []; }
  newOrders(picked: string, pk: string[]) {
    const K = this.state?.knowledge;
    const p = K?.index.get(picked.toLowerCase());
    if (!K || p == null) return 0;
    return pk.map((c) => K.index.get(c.toLowerCase())).filter((x): x is number => x != null && x !== p && !K.known(p, x) && !K.known(x, p)).length;
  }
  pickWinRemovals(picked: string, pk: string[]) {
    return this.state ? pickWins(this.state.knowledge.ids, this.log, picked, pk) : [];
  }

  pick(picked: string, pk: string[], wins: boolean) {
    if (!this.mine || !this.state || !this.row) return;
    const st = this.state;
    const disagreed = this.disagreements(picked, pk).length;
    const removed = wins ? this.pickWinRemovals(picked, pk) : [];
    const screen: RankScreen = { s: "P", o: [picked, ...pk.filter((c) => c !== picked)], t: now() };
    this.log = [...this.log.filter((_, i) => !removed.includes(i)), screen];
    this.reask = null;
    const next = removed.length ? new RankingState(this.id, st.category, this.log, this.row.depth, this.row.top) : st.appending(screen);
    this.state = next;
    this.record(st, next, removed.length ? "pick_win" : "pick", this.log.length);
    capture("ranking_pick", { disagreed, resolution: disagreed === 0 ? "none" : wins ? "pick_wins" : "keep", removed: removed.length });
    this.bump();
    this.save();
  }

  /** Every pick so far, newest first: how many of its orders disagreed with the ranking and were kept out, and whether
   *  it won over the ranking (its screens taken out; the change log says so). */
  get picks(): { index: number; screen: RankScreen; disagreed: number; won: boolean }[] {
    const K = this.state?.knowledge;
    if (!K) return [];
    const won = new Set(this.changes.filter((c) => c.by === "pick_win").map((c) => c.n));
    return this.log.map((screen, index) => ({ index, screen, disagreed: K.contradicted.get(index)?.length ?? 0, won: won.has(index + 1) }))
      .filter((p) => p.screen.s === "P").reverse();
  }

  async update(patch: { name?: string; depth?: "half" | "full"; top?: number; sharing?: "cube" | "private" }) {
    try {
      const before = this.state;
      const row: RankingRow = demo ? demo.update(this.id, patch)
        : await rpc("cube_ranking_update", { p_id: this.id, p_name: patch.name ?? null, p_depth: patch.depth ?? null, p_top: patch.top ?? null,
                                            p_sharing: patch.sharing ?? null });
      this.row = { ...this.row!, ...row };
      this.rebuildState();
      if (patch.depth || patch.top) {
        this.record(before, this.state, "settings", undefined);
        this.force = true;
        this.save();
      }
      this.error = null;
    } catch (e) {
      this.error = (e as Error).message;
    }
    this.bump();
  }

  /** One push at a time: keep what the server and this device agree on, send the rest. */
  private save() {
    if (this.saving || !this.row || (!this.unsaved && !this.force)) return;
    this.force = false;
    this.saving = true;
    const local = this.log.slice();
    let keep = 0;
    while (keep < Math.min(local.length, this.serverLog.length) && JSON.stringify(local[keep]) === JSON.stringify(this.serverLog[keep])) keep++;
    const add = local.slice(keep);
    const opId = this.op && this.op.keep === keep && this.op.count === local.length ? this.op.id : crypto.randomUUID().toLowerCase();
    this.op = { keep, count: local.length, id: opId };
    const progress = this.state?.progress ?? { sorted: 0, categories: 0, ranked: 0 };
    const sending = this.pending.slice();
    const rev = this.row.rev;
    void (async () => {
      try {
        const r: RankingRow = demo ? demo.push(this.id, keep, add, progress, sending)
          : await rpc("cube_ranking_push", { p_id: this.id, p_rev: rev, p_keep: keep, p_add: add, p_sorted: progress.sorted,
                                             p_categories: progress.categories, p_ranked: progress.ranked, p_op_id: opId, p_changes: sending });
        this.row = { ...this.row!, ...r };
        this.serverLog = local;
        this.pending.splice(0, sending.length);
        this.op = null;
        this.error = null;
        this.lastChange = Date.now();
        this.saving = false;
        if (this.unsaved) this.save();
      } catch (e) {
        this.saving = false;
        if (["PT409", "40001"].includes((e as { code?: string }).code ?? "")) {
          this.op = null;
          this.pending = [];
          this.serverLog = [];
          this.notice = "This ranking changed on another device, so it has been reloaded. Check the screen you just locked in.";
          try { const d = await fetchRanking(this.id); this.serverLog = d.log; this.log = d.log.slice(); this.row = d; this.changes = d.changes ?? []; this.reask = null; this.rebuild(d.cube?.cards ?? null); } catch { /* next poll */ }
        } else {
          this.error = `Couldn't save: ${(e as Error).message}. It's kept here and saves on the next lock-in.`;
        }
      }
      this.bump();
    })();
  }

  /** Watching: someone else's ranking every 10 s (60 s once nothing changed for a minute); yours every 60 s. */
  watch(): () => void {
    let stop = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = () => {
      const quiet = Date.now() - this.lastChange > 60_000;
      timer = setTimeout(async () => {
        if (stop) return;
        if (!document.hidden && !this.saving && !this.unsaved) {
          try { this.adopt(await fetchRanking(this.id)); this.bump(); } catch { /* try again next tick */ }
        }
        if (!stop) tick();
      }, this.mine || quiet ? 60_000 : 10_000);
    };
    tick();
    return () => { stop = true; clearTimeout(timer); };
  }

  /** A job's list: the placed cards, best first, then the rest by name. */
  list(job: RankJob) {
    if (!this.state) return null;
    const st = this.state;
    const s = st.session(job);
    const placed = s.top.map((x) => this.cardAt(x)).filter((c): c is RankCard => !!c);
    const inTop = new Set(s.top);
    const scope: number[] = [];
    st.knowledge.ids.forEach((id, i) => { if ((job === "F" || st.category.get(id) === job) && !inTop.has(i)) scope.push(i); });
    const rest = scope.map((x) => this.cardAt(x)).filter((c): c is RankCard => !!c).sort((a, b) => a.name.localeCompare(b.name));
    const restTitle = !rest.length ? null : s.done ? `Below the top ${s.target}, in no particular order · ${rest.length}` : `Not placed yet · ${rest.length}`;
    return { placed, rest, restTitle, session: s };
  }

  listText(job: RankJob) {
    const l = this.list(job);
    if (!l) return "";
    const lines = l.placed.map((c, i) => `${i + 1}. ${c.name}`);
    if (l.restTitle && l.rest.length) lines.push("", l.restTitle, ...l.rest.map((c) => c.name));
    return lines.join("\n") + "\n";
  }
}

const models = new Map<string, RankingModel>();
export function rankingModel(id: string) {
  let m = models.get(id);
  if (!m) { m = new RankingModel(id); models.set(id, m); }
  return m;
}

/** An open ranking, loaded once the card data is in, watched while the screen is open. */
export function useRanking(id: string, catalog: Catalog | null, watch = true): RankingModel {
  const m = rankingModel(id);
  useSyncExternalStore(m.subscribe, () => m.version);
  useEffect(() => { if (catalog && !m.state) void m.load(catalog); }, [id, catalog]);
  useEffect(() => (watch && catalog ? m.watch() : undefined), [id, catalog, watch]);
  return m;
}

/* ── dev demo: the fixture's cube, two friends' finished rankings and one of yours in progress ── */

export class DemoRankings {
  private rows = new Map<string, RankingRow>();
  private logs = new Map<string, RankScreen[]>();
  private changeLogs = new Map<string, RankChange[]>();
  static readonly mine = "d0000000-0000-0000-0000-0000000aa001";
  static readonly mara = "d0000000-0000-0000-0000-0000000aa002";
  static readonly theo = "d0000000-0000-0000-0000-0000000aa003";
  /** Mara's cube, shared with you: one that isn't yours to rank. */
  static readonly maraCube = "d0000000-0000-0000-0000-0000000fc001";
  static readonly maraCubeName = "Mara's Legacy Cube";
  private static readonly maraPerson: Person = { user_id: "d0000000-0000-0000-0000-0000000f0001", display_name: "Mara Quinn" };

  constructor(private cubeId: string, private cubeName: string, private cards: string[], categories: Map<string, RankJob>) {
    const fnvTaste = (salt: string) => {
      const order = cards.slice().sort((a, b) => hash(salt + a) - hash(salt + b));
      return new Map(order.map((c, i) => [c, i]));
    };
    const base = fnvTaste("base");
    const mixed = (salt: string) => {
      const own = fnvTaste(salt);
      const order = cards.slice().sort((a, b) => 3 * base.get(a)! + own.get(a)! - (3 * base.get(b)! + own.get(b)!));
      return new Map(order.map((c, i) => [c, i]));
    };
    const run = (id: string, who: Person, name: string, depth: "half" | "full", top: number, mine: boolean, finalScreens: number | null,
                 t: Map<string, number>, listId = cubeId, stopAfter: RankJob | null = mine ? "B" : null) => {
      let st = new RankingState(id, categories, [], depth, top);
      const log: RankScreen[] = [], changes: RankChange[] = [];
      for (const job of [...st.jobs, "F" as RankJob]) {
        let n = 0;
        for (let q = st.session(job).question; q && n < (job === "F" ? finalScreens ?? 1e9 : 1e9); q = st.session(job).question) {
          const s: RankScreen = { s: job, o: q.map((x) => st.id(x)).sort((a, b) => t.get(a)! - t.get(b)!), t: Date.now() + (log.length - 3000) * 20_000 };
          log.push(s);
          const next = st.appending(s);
          const only = job === "F" ? undefined : [job, "F" as RankJob];
          changes.push(...diffPlaces(st.places(only), next.places(only)).map((c) => ({ ...c, t: s.t, by: "screen", n: log.length })));
          st = next;
          n++;
        }
        if (job === stopAfter) break;
      }
      if (!mine && !stopAfter) {
        for (let i = 0; i < 5; i++) {
          const pk = packOf(id, st.knowledge);
          const picked = pk.slice().sort((a, b) => t.get(a)! - t.get(b)!)[0];
          const s: RankScreen = { s: "P", o: [picked, ...pk.filter((c) => c !== picked)], t: Date.now() };
          log.push(s);
          st = st.appending(s);
        }
      }
      const p = st.progress;
      this.rows.set(id, { id, list_id: listId, name, depth, top, sharing: "cube", screens: log.length, rev: 1, ...p,
                          updated_at: new Date().toISOString(), mine, by: who });
      this.logs.set(id, log);
      this.changeLogs.set(id, changes);
    };
    run(DemoRankings.mara, { user_id: "d0000000-0000-0000-0000-0000000f0001", display_name: "Mara Quinn" }, "Aggro all the way", "half", 100, false, null, mixed("mara"));
    run(DemoRankings.theo, { user_id: "d0000000-0000-0000-0000-0000000f0002", display_name: "Theo Vance" }, "Theo's picks", "half", 50, false, null, mixed("theo"));
    run(DemoRankings.mine, { user_id: "d0000000-0000-0000-0000-0000000f0000", display_name: "You" }, "My ranking", "half", 100, true, 0, mixed("me"));
    run("d0000000-0000-0000-0000-0000000aa004", DemoRankings.maraPerson, "Mara's own order", "half", 100, false, 0, mixed("mara2"), DemoRankings.maraCube, "U");
  }

  private cube(listId: string, cards: boolean): RankingCube {
    const base = listId === DemoRankings.maraCube
      ? { id: listId, name: DemoRankings.maraCubeName, mine: false, owner: DemoRankings.maraPerson }
      : { id: this.cubeId, name: this.cubeName, mine: true, owner: { user_id: "d0000000-0000-0000-0000-0000000f0000", display_name: "You" } };
    return { ...base, can_see: true, ...(cards ? { cards: this.cards } : {}) };
  }

  rankings(listId: string | null): CubeRankings {
    const all = [...this.rows.values()].sort((a, b) => (a.mine === b.mine ? a.name.localeCompare(b.name) : a.mine ? -1 : 1));
    if (listId == null) return { cube: null, can_rank: false, rankings: all.filter((r) => r.mine).map((r) => ({ ...r, cube: this.cube(r.list_id, false) })) };
    if (listId !== this.cubeId && listId !== DemoRankings.maraCube) return { cube: null, can_rank: false, rankings: [] };
    return { cube: this.cube(listId, false), can_rank: true, rankings: all.filter((r) => r.list_id === listId) };
  }

  /** A stand-in for Claude's brief (the demo has no server): marked as a sample. */
  brief(a: string, b: string, list: RankJob): RankingBrief {
    const ra = this.rows.get(a), rb = this.rows.get(b);
    if (!ra || !rb) return { brief: null, reason: "That's private" };
    const where = list === "F" ? `the top ${Math.min(ra.top, rb.top)}` : JOB_TITLE[list];
    return { brief: `Sample brief (the demo has no server; on Table 1 Claude writes this from both rankings): ${ra.by?.display_name ?? "One"} and ` +
                    `${rb.by?.display_name ?? "the other"} agree on most of the strongest cards in ${where}, and part ways further down.`, cached: true, sample: true };
  }

  /** Cubes of other people you can rank: Mara's. */
  rankable(): RankableCube[] {
    const of = [...this.rows.values()].filter((r) => r.list_id === DemoRankings.maraCube);
    return [{ id: DemoRankings.maraCube, name: DemoRankings.maraCubeName, owner: DemoRankings.maraPerson, cards: this.cards.length,
              rankings: of.length, mine: of.filter((r) => r.mine).length }];
  }

  get(id: string): RankingDetail {
    const r = this.rows.get(id);
    if (!r) throw new Error("That's private");
    return { ...r, log: this.logs.get(id) ?? [], changes: this.changeLogs.get(id) ?? [], cube: this.cube(r.list_id, true) };
  }

  create(id: string, listId: string, name: string, depth: "half" | "full", top: number, sharing: "cube" | "private"): RankingRow {
    const r: RankingRow = { id, list_id: listId, name: name || "My ranking", depth, top, sharing, screens: 0, rev: 0, sorted: 0, categories: 0, ranked: 0,
                            updated_at: new Date().toISOString(), mine: true, by: { user_id: "d0000000-0000-0000-0000-0000000f0000", display_name: "You" } };
    this.rows.set(id, r);
    this.logs.set(id, []);
    this.changeLogs.set(id, []);
    return r;
  }

  update(id: string, patch: Partial<Pick<RankingRow, "name" | "depth" | "top" | "sharing">>): RankingRow {
    const r = { ...this.rows.get(id)!, ...Object.fromEntries(Object.entries(patch).filter(([, v]) => v != null)) } as RankingRow;
    this.rows.set(id, r);
    return r;
  }

  push(id: string, keep: number, add: RankScreen[], p: { sorted: number; categories: number; ranked: number }, changes: RankChange[]): RankingRow {
    const log = [...(this.logs.get(id) ?? []).slice(0, keep), ...add];
    this.logs.set(id, log);
    this.changeLogs.set(id, [...(this.changeLogs.get(id) ?? []), ...changes]);
    const r = { ...this.rows.get(id)!, rev: this.rows.get(id)!.rev + 1, screens: log.length, ...p, updated_at: new Date().toISOString() };
    this.rows.set(id, r);
    return r;
  }

  delete(id: string) { this.rows.delete(id); this.logs.delete(id); this.changeLogs.delete(id); }
}

function hash(s: string) {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  return h;
}

/** Dev demo: builds the rankings demo on the fixture's cube once the card data is in. */
export function startRankingsDemo(catalog: Catalog, cube: { id: string; name: string; cardIds: string[] }) {
  if (demo) return;
  const oracleIds = [...new Set(cube.cardIds.map((cid) => catalog.printingIndex.get(cid)).filter((p): p is number => p != null)
    .map((p) => catalog.oId[catalog.pOracle[p]].toLowerCase()))];
  const { jobs } = resolveCards(catalog, oracleIds);
  demo = new DemoRankings(cube.id, cube.name, [...jobs.keys()].sort(), jobs);
}

export const COLOR_ORDER = COLOR_JOBS;
