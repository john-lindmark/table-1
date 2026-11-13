// The cube ranking engine as a file the apps download (contract/cube-rankings-2026-10-21.md § The engine as a file,
// 2026-11-13; John: "updates to the cube logic don't require new builds and just require a server update").
// tools/rank-engine/build.mjs bundles this with cubeRanking.ts into one script that sets `globalThis.T1Rank`; iOS runs it
// in JavaScriptCore and Android in QuickJS, both through strings so neither needs to know the engine's types. The apps
// keep their own engine (CubeRanking.swift / CubeRanking.kt) and use it whenever this file is missing, fails its self
// test or speaks another `api`. Knowledge, why-chains and comparisons stay native; what this file decides is each job's
// session (the list, the next screen, the checks) and the screen estimates: the parts whose rules change.
import { RULES, RankingState, type RankDepth, type RankJob, type RankScreen, type RankSession } from "./cubeRanking";
import selfCase from "./rankEngineSelfTest.json";

/** What the apps check before they load a file: they only run an engine whose `api` they were built for. */
export const API = 1;

interface OpenArgs { id: string; cards: Record<string, RankJob>; log: RankScreen[]; depth: RankDepth; top: number; fresh?: string[] }

/** A session with card ids in place of indexes (each app maps them onto its own knowledge, indexed the same way). */
export interface WireSession {
  top: string[]; done: boolean; target: number; size: number; question: string[] | null; pinned: string[];
  open: string[]; waiting: string[]; check: boolean; checked: number;
}

const states = new Map<number, RankingState>();
let nextHandle = 1;

function keep(st: RankingState): number {
  const h = nextHandle++;
  states.set(h, st);
  return h;
}

function get(h: number): RankingState {
  const st = states.get(h);
  if (!st) throw new Error(`no ranking ${h}`);
  return st;
}

export function wire(st: RankingState, s: RankSession): WireSession {
  const ids = (xs: number[]) => xs.map((x) => st.id(x));
  const open: string[] = [];
  st.knowledge.ids.forEach((id, i) => { if ((s.open[i >>> 5] >>> (i & 31)) & 1) open.push(id); });
  return { top: ids(s.top), done: s.done, target: s.target, size: s.size, question: s.question ? ids(s.question) : null,
           pinned: ids(s.pinned), open, waiting: ids(s.waiting), check: s.check, checked: s.checked };
}

export const T1Rank = {
  api: API,
  /** The rules it implements (cubeRanking.ts RULES): an app whose own engine has the same rules uses its own. */
  rules: RULES,
  /** The date-stamped version the build writes in (rank-engine-<version>.js). */
  version: typeof __RANK_ENGINE_VERSION__ === "string" ? __RANK_ENGINE_VERSION__ : "dev",
  /** A ranking from its log: JSON of OpenArgs. Returns a handle. */
  open(json: string): number {
    const a = JSON.parse(json) as OpenArgs;
    return keep(new RankingState(a.id, new Map(Object.entries(a.cards)), a.log, a.depth, a.top, undefined, a.fresh ?? []));
  },
  /** The same ranking with one more screen (JSON of a RankScreen): a new handle; the old one stays until freed. */
  append(h: number, screen: string): number { return keep(get(h).appending(JSON.parse(screen) as RankScreen)); },
  free(h: number): void { states.delete(h); },
  /** A job's session as JSON of WireSession. */
  session(h: number, job: RankJob): string { const st = get(h); return JSON.stringify(wire(st, st.session(job))); },
  /** Screens a job is expected to take in all. */
  expected(h: number, job: RankJob): number { return get(h).expected(job); },
  /** Replays a short run from the shared cases and compares each next screen: false means don't use this file. */
  selfTest(): boolean {
    try {
      const c = selfCase as { id: string; depth: RankDepth; top: number; cards: Record<string, RankJob>;
                              steps: { s: RankJob; question: string[]; answer: string[] }[]; final: string[] };
      let st = new RankingState(c.id, new Map(Object.entries(c.cards)), [], c.depth, c.top);
      for (const step of c.steps) {
        const q = st.session(step.s).question;
        if (!q || q.map((x) => st.id(x)).join() !== step.question.join()) return false;
        st = st.appending({ s: step.s, o: step.answer });
      }
      return st.session("F").top.map((x) => st.id(x)).join() === c.final.join();
    } catch {
      return false;
    }
  },
};

declare const __RANK_ENGINE_VERSION__: string | undefined;
