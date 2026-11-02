// Sync a cube with Cube Cobra (contract/cube-sync-2026-10-30.md): what's in, out and in a new printing or finish
// between the cube and Cube Cobra's answer, and the entries to save. Shared cases: testdata/cube-sync/cases.json
// (also iOS CubeSyncTests and Android CubeSyncTest).
import type { Condition } from "./collection";
import { LIST_CONDITIONS, condOf, entry, finishOf, langOf, type Board, type Entry, type ListFinish } from "./lists";

/** `cond` only when the line records one other than NM (Cube Cobra records none, so In lines never do). */
export interface SyncLine { board: Board; card: string; finish: ListFinish; lang: string; cond?: Condition; qty: number }
export interface SyncChanged {
  board: Board; from_card: string; from_finish: ListFinish; from_lang: string;
  to_card: string; to_finish: ListFinish; to_lang: string; qty: number;
}
export interface SyncResult { in: SyncLine[]; out: SyncLine[]; changed: SyncChanged[]; same: number; entries: Entry[] }
/** A printing's card (oracle) and language, from the catalog. */
export interface SyncPrinting { oracle: string; lang: string }

const SEP = "\u0001";
const cmp = (a: string[], b: string[]) => {
  for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  return a.length - b.length;
};
/** English first, then by code. */
const langKey = (l: string) => (l === "en" ? "0" : "1" + l);
/** Best condition first. */
const condKey = (c: string) => String(LIST_CONDITIONS.indexOf(c as Condition));
const add = (m: Map<string, number>, k: string, n: number) => m.set(k, (m.get(k) ?? 0) + n);
const parts = (k: string) => k.split(SEP);

export function cubeSyncDiff(current: Entry[], incoming: Entry[], printings: (cardId: string) => SyncPrinting | undefined): SyncResult {
  const plang = (c: string) => printings(c)?.lang ?? "en";
  const oracle = (c: string) => printings(c)?.oracle ?? c;
  const cur = new Map<string, number>(); // board|card|finish|lang|cond
  for (const e of current) add(cur, [e.board, e.cardId, finishOf(e), langOf(e), condOf(e)].join(SEP), e.qty);
  const inc = new Map<string, number>(); // board|card|finish
  for (const e of incoming) add(inc, [e.board, e.cardId, finishOf(e)].join(SEP), e.qty);
  const final = new Map<string, number>();
  const changed = new Map<string, number>();
  let same = 0;
  const incKeys = [...inc.keys()].sort((a, b) => cmp(parts(a), parts(b)));

  // 1. Same printing and finish.
  for (const k of incKeys) {
    const matches = [...cur.keys()].filter((m) => parts(m).slice(0, 3).join(SEP) === k)
      .sort((a, b) => cmp([langKey(parts(a)[3]), condKey(parts(a)[4])], [langKey(parts(b)[3]), condKey(parts(b)[4])]));
    for (const m of matches) {
      const n = Math.min(inc.get(k)!, cur.get(m)!);
      if (n <= 0) continue;
      cur.set(m, cur.get(m)! - n);
      inc.set(k, inc.get(k)! - n);
      add(final, m, n);
      same += n;
    }
  }

  // 2. Same printing, other finish. 3. Same card, other printing.
  const pair = (match: (m: string[], card: string) => boolean) => {
    for (const k of incKeys) {
      const [b, c, f] = parts(k);
      const order = [...cur.keys()].sort((x, y) => {
        const px = parts(x), py = parts(y);
        return cmp([...px.slice(0, 3), langKey(px[3]), condKey(px[4])], [...py.slice(0, 3), langKey(py[3]), condKey(py[4])]);
      });
      for (const m of order) {
        if (inc.get(k)! <= 0) break;
        const pm = parts(m);
        if (cur.get(m)! <= 0 || pm[0] !== b || !match(pm, c)) continue;
        const n = Math.min(inc.get(k)!, cur.get(m)!);
        cur.set(m, cur.get(m)! - n);
        inc.set(k, inc.get(k)! - n);
        const toLang = changedLang(pm[1], pm[3], c, plang);
        add(final, [b, c, f, toLang, pm[4]].join(SEP), n);
        add(changed, [b, pm[1], pm[2], pm[3], c, f, toLang].join(SEP), n);
      }
    }
  };
  pair((m, c) => m[1] === c);
  pair((m, c) => oracle(m[1]) === oracle(c));

  const into = new Map<string, number>();
  for (const [k, n] of inc) {
    if (n <= 0) continue;
    const [b, c, f] = parts(k);
    const key = [b, c, f, plang(c), "NM"].join(SEP);
    add(into, key, n);
    add(final, key, n);
  }
  const sortedOf = (m: Map<string, number>) => [...m.entries()].filter(([, n]) => n > 0).sort(([a], [b]) => cmp(parts(a), parts(b)));
  const line = ([k, n]: [string, number]): SyncLine => {
    const [board, card, finish, lang, cond] = parts(k);
    return { board: board as Board, card, finish: finish as ListFinish, lang, ...(cond !== "NM" ? { cond: cond as Condition } : {}), qty: n };
  };
  return {
    in: sortedOf(into).map(line),
    out: sortedOf(cur).map(line),
    changed: sortedOf(changed).map(([k, qty]) => {
      const [board, from_card, from_finish, from_lang, to_card, to_finish, to_lang] = parts(k);
      return { board: board as Board, from_card, from_finish: from_finish as ListFinish, from_lang, to_card,
               to_finish: to_finish as ListFinish, to_lang, qty };
    }),
    same,
    entries: sortedOf(final).map(([k, n]) => {
      const [board, card, finish, lang, cond] = parts(k);
      return entry(card, board as Board, n, finish as ListFinish, lang, cond as Condition);
    }),
  };
}

/** The new printing's own language when it isn't English; else the old line's when it wasn't its printing's own;
 *  else English. */
export function changedLang(fromCard: string, fromLang: string, toCard: string, plang: (c: string) => string): string {
  const to = plang(toCard);
  if (to !== "en") return to;
  if (fromLang !== plang(fromCard)) return fromLang;
  return "en";
}

const sum = (rows: { qty: number }[]) => rows.reduce((n, r) => n + r.qty, 0);
export const syncCounts = (r: SyncResult) => ({ in: sum(r.in), out: sum(r.out), changed: sum(r.changed) });
export const syncIsEmpty = (r: SyncResult) => !r.in.length && !r.out.length && !r.changed.length;

/** "3 in · 2 out · 5 new printings", or "Up to date". */
export function syncSummary(r: SyncResult): string {
  const c = syncCounts(r);
  const out = [c.in ? `${c.in} in` : "", c.out ? `${c.out} out` : "", c.changed ? `${c.changed} new printing${c.changed === 1 ? "" : "s"}` : ""];
  return out.filter(Boolean).join(" · ") || "Up to date";
}

/** The Cube Cobra id in a link ("cubecobra.com/cube/list/<id>", "/c/<id>"), for the row's detail. */
export function cubeCobraId(link: string | null | undefined): string | null {
  if (!link) return null;
  let u: URL;
  try {
    u = new URL(/^https?:\/\//i.test(link) ? link : `https://${link}`);
  } catch {
    return null;
  }
  if (!/(^|\.)cubecobra\.com$/i.test(u.hostname)) return null;
  const p = u.pathname.split("/").filter(Boolean);
  if (p[0] === "c" && p[1]) return p[1];
  if (p[0] === "cube") return p.length >= 3 ? p[2] : p[1] ?? null;
  return null;
}
