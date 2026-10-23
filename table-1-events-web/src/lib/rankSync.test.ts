import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { RankScreen } from "./cubeRanking";
import { RankSaver, emptyPending, plan, screenKey, settle, type PushArgs, type RankPending, type SaveIO } from "./rankSync";

/* Saving a ranking (rankSync.ts) against the shared cases in testdata/ranking-save/cases.json (written by the reference
   make_cases.py; iOS RankSyncTests and Android RankSyncTest read the same file), then RankSaver against a fake server that
   refuses stale pushes the way cube_ranking_push does (migration 20261022180000_ranking_push_guard.sql). */

interface Case { name: string; server: RankScreen[]; adds: RankScreen[]; drops: RankScreen[];
  want: { log: RankScreen[]; add: RankScreen[]; drop: RankScreen[]; keep: number; removed: number } }
const cases: Case[] = JSON.parse(readFileSync(new URL("../../../testdata/ranking-save/cases.json", import.meta.url), "utf8")).cases;
const keys = (ss: RankScreen[]) => ss.map(screenKey);

describe("the shared save cases", () => {
  it("has them all", () => expect(cases.length).toBeGreaterThanOrEqual(16));
  for (const c of cases) {
    it(c.name, () => {
      const p = plan(c.server, c.adds, c.drops);
      expect(keys(p.log)).toEqual(keys(c.want.log));
      expect(keys(p.add)).toEqual(keys(c.want.add));
      expect(keys(p.drop)).toEqual(keys(c.want.drop));
      expect(p.keep).toBe(c.want.keep);
      expect(p.removed).toBe(c.want.removed);
    });
  }
});

describe("settling a save", () => {
  it("keeps what was done while it was out", () => {
    const a: RankScreen = { s: "W", o: ["a", "b"], t: 1 };
    const b: RankScreen = { s: "W", o: ["c", "d"], t: 2 };
    const p: RankPending = { adds: [a, b], drops: [a], changes: [], op: null };
    const after = settle(p, { id: "x", rev: 3, count: 9, adds: 1, drops: 0, changes: 0 });
    expect(after.adds).toEqual([b]);
    expect(after.drops).toEqual([a]);
  });
});

/* ── RankSaver against a fake server ─────────────────────────────────── */

const CONFLICT = new Error("This ranking changed on another device");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
let n = 0;
const screen = (s = "W"): RankScreen => ({ s: s as RankScreen["s"], o: [`card-${n}-a`, `card-${n}-b`], t: 1_000_000 + n++ });

function server(latency = 0) {
  const st = { log: [] as RankScreen[], rev: 0, lastOp: "", failNext: 0, landThenFail: 0, pushes: [] as PushArgs[], removed: 0 };
  const stored = { p: emptyPending() };
  let release: (() => void) | null = null;
  const io: SaveIO<{ rev: number; screens: number }, { rev: number; log: RankScreen[] }> = {
    async push(a) {
      await sleep(latency);
      st.pushes.push(a);
      if (st.failNext > 0) { st.failNext--; throw new Error("offline"); }
      if (st.lastOp === a.opId) return { rev: st.rev, screens: st.log.length };
      if (a.rev !== st.rev || a.count !== st.log.length) throw CONFLICT;
      const log = [...st.log];
      for (const d of a.drop) {
        const i = log.findIndex((x) => screenKey(x) === screenKey(d));
        if (i < 0) throw CONFLICT;
        log.splice(i, 1);
        st.removed++;
      }
      st.log = [...log, ...a.add];
      st.rev++;
      st.lastOp = a.opId;
      if (st.landThenFail > 0) { st.landThenFail--; throw new Error("timeout"); }
      return { rev: st.rev, screens: st.log.length };
    },
    async reload() { await sleep(latency); return { rev: st.rev, log: [...st.log] }; },
    isConflict: (e) => e === CONFLICT,
    storage: { load: () => structuredClone(stored.p), save: (p) => { stored.p = structuredClone(p); } },
    wait: () => new Promise<void>((r) => { release = r; }),
  };
  const elsewhere = (s: RankScreen) => { st.log = [...st.log, s]; st.rev++; };
  const retry = () => { const r = release; release = null; r?.(); };
  return { st, io, stored, elsewhere, retry };
}

async function idle(s: RankSaver<{ rev: number; screens: number }, { rev: number; log: RankScreen[] }>) {
  for (let i = 0; i < 500 && (s.saving || s.unsaved); i++) await sleep(5);
}

describe("saving a ranking (2026-10-23: two wipes of a 500-screen ranking)", () => {
  it("fast lock-ins with another device saving mid-burst: every screen kept, once, in order", async () => {
    const f = server(15);
    const s = new RankSaver(f.io);
    const mine: RankScreen[] = [];
    for (let i = 0; i < 12; i++) {
      const x = screen("F");
      mine.push(x);
      s.add(x);
      if (i === 5) f.elsewhere(screen("U"));
      await sleep(4);
    }
    await idle(s);
    expect(s.unsaved).toBe(false);
    expect(f.st.log).toEqual(s.log);
    expect(f.st.log.filter((x) => x.s === "F")).toEqual(mine);
    expect(f.st.log.filter((x) => x.s === "U")).toHaveLength(1);
    expect(f.st.removed).toBe(0);
    expect(f.st.pushes.every((p) => p.count >= 0 && p.drop.length === 0)).toBe(true);
  });

  it("a conflict never empties the log: what's waiting goes on top of the server's", async () => {
    const f = server(5);
    const s = new RankSaver(f.io);
    for (let i = 0; i < 6; i++) s.add(screen());
    await idle(s);
    const six = [...f.st.log];
    f.elsewhere(screen("U"));
    s.add(screen());
    expect(s.log.length).toBeGreaterThanOrEqual(7);
    await idle(s);
    expect(f.st.log).toHaveLength(8);
    expect(f.st.log.slice(0, 6)).toEqual(six);
    expect(f.st.log).toEqual(s.log);
  });

  it("undo and redo name the screen they take out, and only it leaves", async () => {
    const f = server();
    const s = new RankSaver(f.io);
    const five = [screen(), screen(), screen(), screen(), screen()];
    five.forEach((x) => s.add(x));
    await idle(s);
    s.drop([five[4]]); s.save();
    s.drop([five[0]]); s.save();
    await idle(s);
    expect(f.st.log).toEqual(five.slice(1, 4));
    expect(f.st.pushes.at(-1)!.add).toEqual([]);
    expect(f.st.pushes.flatMap((p) => p.drop).map(screenKey)).toEqual([five[4], five[0]].map(screenKey));
  });

  it("no signal: kept in storage, survives a closed tab, saved once a push gets through", async () => {
    const f = server();
    const first = new RankSaver(f.io);
    first.add(screen());
    await idle(first);
    f.st.failNext = 1000;
    const two = [screen(), screen()];
    two.forEach((x) => first.add(x));
    await sleep(20);
    expect(first.unsaved).toBe(true);
    expect(first.error).toMatch(/kept on this device/);
    expect(f.stored.p.adds).toEqual(two);
    first.stop();

    f.st.failNext = 0;
    const again = new RankSaver(f.io);  // the tab is opened again
    expect(again.waitingScreens).toBe(2);
    again.adopt([...f.st.log], f.st.rev);
    await idle(again);
    expect(f.st.log.slice(1)).toEqual(two);
    expect(f.stored.p.adds).toEqual([]);
  });

  it("a push that landed but whose answer was lost isn't applied twice", async () => {
    const f = server();
    const s = new RankSaver(f.io);
    s.add(screen());
    await idle(s);
    f.st.landThenFail = 1;
    s.add(screen());
    await sleep(10);
    expect(s.unsaved).toBe(true);
    f.retry();
    await idle(s);
    expect(f.st.log).toHaveLength(2);
    expect(f.st.log).toEqual(s.log);
    expect(new Set(f.st.pushes.slice(1).map((p) => p.opId)).size).toBe(1);
  });

  it("an undo of a screen still on its way is sent once it's saved, not lost", async () => {
    const f = server(20);
    const s = new RankSaver(f.io);
    const x = screen();
    s.add(x);
    await sleep(5);
    s.drop([x]); s.save();
    await idle(s);
    expect(f.st.log).toEqual([]);
    expect(s.log).toEqual([]);
  });
});
