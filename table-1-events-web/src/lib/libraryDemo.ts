// Dev server only: `/library?demo` opens the Library without signing in, on the same fixture the iOS Debug
// demo uses (apps/ios/Table1/DebugResources/library-demo.json: 2,000 cards, five Modern decks, a Vintage
// cube). Writes stay in memory. Production builds drop all of this (import.meta.env.DEV is false there).
import type { ApplyResult, CollectionOp, HistoryEntry, Item, LibrarySummary } from "./collection";
import { allocItemKey, allocKey, meetWants, planAllocations, wantKey, type Alloc, type AllocRow, type Binder, type BinderMove,
         type Want, type WantOp, type WantRow } from "./binders";
import type { Board, CardList } from "./lists";

const FLAG = "table1.libraryDemo";

/** True for the rest of the tab session once a page opened with ?demo. */
export function isLibraryDemo(): boolean {
  if (!import.meta.env.DEV) return false;
  try {
    if (new URLSearchParams(location.search).has("demo")) sessionStorage.setItem(FLAG, "1");
    return sessionStorage.getItem(FLAG) === "1";
  } catch {
    return false;
  }
}

interface Fixture {
  lists: { id: string; kind: "deck" | "cube"; name: string; format: string;
           versions: { version: number; at: number; note: string; entries: [string, string, number][] }[] }[];
  summary: LibrarySummary;
  items: [string, Item["finish"], Item["condition"], string, number][];
  prices: Record<string, (number | null)[]>;
}

export class DemoBackend {
  items = new Map<string, Item>();
  summary: LibrarySummary;
  private seq = 0;
  /** [usd, usd_foil, usd_etched, eur, eur_foil] per printing, as card_prices_get returns them. */
  readonly prices: Fixture["prices"];
  private ledger = new Map<string, HistoryEntry[]>();
  private batches = new Map<string, { rows: { it: Item; delta: number }[]; undone: boolean }>();
  private seedAt = new Date().toISOString();
  private seed = new Map<string, Item>();
  /** Binders, allocations and wants, with what each batch did to them (for undo). */
  binders = new Map<string, Binder>();
  allocs = new Map<string, Alloc>();
  wants = new Map<string, Want>();
  private batchAllocs = new Map<string, { a: Alloc; delta: number }[]>();
  private batchWants = new Map<string, { w: Want; delta: number }[]>();

  constructor(f: Fixture) {
    this.prices = f.prices;
    for (const [cardId, finish, condition, lang, qty] of f.items) {
      const k = `${cardId}|${finish}|${condition}|${lang}`;
      this.items.set(k, { k, cardId, finish, condition, lang, qty, seq: ++this.seq });
    }
    this.seed = new Map(this.items);
    this.summary = { ...f.summary, seq: this.seq };
    this.seedBinders();
  }

  /** Two binders to start with, as on iOS: a for-trade binder holding a copy or two of every seventh item and
   *  "Box 1" holding every fifth item's other copies (the rest stay Unsorted). */
  private seedBinders() {
    const trade: Binder = { id: "d0000000-0000-0000-0000-00000000b001", name: "Trade binder", for_trade: true, seq: 1 };
    const box: Binder = { id: "d0000000-0000-0000-0000-00000000b002", name: "Box 1", for_trade: false, seq: 2 };
    this.binders = new Map([[trade.id, trade], [box.id, box]]);
    [...this.items.values()].sort((a, b) => (a.k < b.k ? -1 : 1)).forEach((it, i) => {
      let left = it.qty;
      const put = (b: Binder, qty: number) => {
        const a: Alloc = { binderId: b.id, cardId: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, qty, seq: 0 };
        this.allocs.set(allocKey(a), a);
      };
      if (i % 7 === 0) {
        const n = Math.min(left, 1 + (i % 2));
        put(trade, n);
        left -= n;
      }
      if (i % 5 === 0 && left > 0) put(box, left);
    });
  }

  private row = (a: Alloc): AllocRow => [a.binderId, a.cardId, a.finish, a.condition, a.lang, a.qty, a.seq];
  private wrow = (w: Want): WantRow => [w.oracleId, w.cardId, w.finish, w.qty, w.maxUsd, w.seq];

  saveBinder(id: string, name: string, forTrade: boolean): Binder {
    const n = name.trim().slice(0, 60);
    if (!n) throw new Error("Name the binder");
    if ([...this.binders.values()].some((b) => b.id !== id && b.name.toLowerCase() === n.toLowerCase())) {
      throw new Error(`You already have a binder called ${n}`);
    }
    const b: Binder = { id, name: n, for_trade: forTrade, seq: ++this.seq };
    this.binders.set(id, b);
    return b;
  }

  deleteBinder(id: string): AllocRow[] {
    this.binders.delete(id);
    const out: AllocRow[] = [];
    for (const [k, a] of this.allocs) {
      if (a.binderId !== id) continue;
      out.push(this.row({ ...a, qty: 0, seq: ++this.seq }));
      this.allocs.delete(k);
    }
    return out;
  }

  /** binder_move: refused whole if a source holds fewer copies than asked. */
  move(moves: BinderMove[]): ApplyResult {
    for (const m of moves) {
      const held = [...this.allocs.values()].filter((a) => allocItemKey(a) === m.item.k).reduce((n, a) => n + a.qty, 0);
      const have = m.from ? this.allocs.get(`${m.from}|${m.item.k}`)?.qty ?? 0 : Math.max(0, (this.items.get(m.item.k)?.qty ?? 0) - held);
      if (m.qty > have) throw new Error("Not that many copies there");
    }
    const base = (m: BinderMove) => ({ card_id: m.item.cardId, finish: m.item.finish, condition: m.item.condition, lang: m.item.lang });
    return this.apply(moves.flatMap((m) => [{ ...base(m), delta: -m.qty, binder_id: m.from }, { ...base(m), delta: m.qty, binder_id: m.to }]), "binder");
  }

  applyWants(ops: WantOp[], batchId?: string, oracleOf?: (cardId: string) => string | null): WantRow[] {
    const out: WantRow[] = [];
    for (const op of ops) {
      const oracle = (op.card_id && oracleOf?.(op.card_id)) || op.oracle_id;
      const k = wantKey(oracle, op.card_id ?? null, op.finish ?? null);
      const cur = this.wants.get(k);
      const qty = Math.min(999, Math.max(0, op.qty ?? (cur?.qty ?? 0) + (op.delta ?? 0)));
      if (!cur && qty === 0) continue;
      const w: Want = { oracleId: oracle, cardId: op.card_id ?? null, finish: op.finish ?? null, qty,
                        maxUsd: "max_usd" in op ? op.max_usd ?? null : cur?.maxUsd ?? null, seq: ++this.seq };
      if (qty > 0) this.wants.set(k, w);
      else this.wants.delete(k);
      out.push(this.wrow(w));
      if (batchId && qty !== (cur?.qty ?? 0)) this.batchWants.set(batchId, [...(this.batchWants.get(batchId) ?? []), { w, delta: qty - (cur?.qty ?? 0) }]);
    }
    return out;
  }

  /** trade_confirm's second half: the gets come off the wants they meet, recorded on the trade's batch. */
  meetTradeWants(gets: { card_id: string; finish: Item["finish"]; qty: number }[], batchId: string, oracleOf: (cardId: string) => string | null): WantRow[] {
    const out: WantRow[] = [];
    for (const g of gets) {
      const oracle = oracleOf(g.card_id);
      if (!oracle) continue;
      const before = new Map(this.wants);
      for (const w of meetWants(oracle, g.card_id, g.finish, g.qty, this.wants)) {
        const k = wantKey(w.oracleId, w.cardId, w.finish);
        const nw = { ...w, seq: ++this.seq };
        if (nw.qty > 0) this.wants.set(k, nw);
        else this.wants.delete(k);
        out.push(this.wrow(nw));
        this.batchWants.set(batchId, [...(this.batchWants.get(batchId) ?? []), { w: nw, delta: nw.qty - (before.get(k)?.qty ?? 0) }]);
      }
    }
    return out;
  }

  apply(ops: CollectionOp[], source: string): ApplyResult {
    const plan = new Map<string, { op: CollectionOp; cur: number; next: number }>();
    for (const op of ops) {
      const finish = op.finish ?? "nonfoil", condition = op.condition ?? "NM", lang = op.lang ?? "en";
      const k = `${op.card_id}|${finish}|${condition}|${lang}`;
      const cur = this.items.get(k)?.qty ?? 0;
      const p = plan.get(k) ?? { op: { ...op, finish, condition, lang }, cur, next: cur };
      p.next = op.qty != null ? op.qty : p.next + (op.delta ?? 0);
      plan.set(k, p);
    }
    for (const p of plan.values()) if (p.next < 0) throw new Error(`Not enough copies (have ${p.cur})`);
    if (source !== "undo" && ops.some((o) => o.binder_id && !this.binders.has(o.binder_id))) throw new Error("That binder is gone");
    if (ops.some((o) => o.binder_id && o.qty != null)) throw new Error("A binder goes with copies added or removed, not a set quantity");
    const batchId = crypto.randomUUID();
    const rows: ApplyResult["items"] = [];
    const done: { it: Item; delta: number }[] = [];
    const at = new Date().toISOString();
    for (const [k, p] of plan) {
      if (p.next === p.cur) continue;
      const it: Item = { k, cardId: p.op.card_id, finish: p.op.finish!, condition: p.op.condition!, lang: p.op.lang!, qty: p.next, seq: ++this.seq };
      if (p.next > 0) this.items.set(k, it);
      else this.items.delete(k);
      rows.push({ card_id: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, qty: it.qty, seq: it.seq });
      done.push({ it, delta: p.next - p.cur });
      const h = this.ledger.get(it.cardId) ?? [];
      h.unshift({ at, finish: it.finish, condition: it.condition, lang: it.lang, delta: p.next - p.cur, qty_after: p.next,
                  source, batch_id: batchId, undone: false });
      this.ledger.set(it.cardId, h);
    }
    this.batches.set(batchId, { rows: done, undone: false });
    // Allocations: hints, then whatever an item no longer has copies for (planAllocations, as the server does).
    const hints = new Map<string, Map<string, number>>();
    for (const op of ops) {
      if (!op.binder_id || op.delta == null || !this.binders.has(op.binder_id)) continue;
      const k = `${op.card_id}|${op.finish ?? "nonfoil"}|${op.condition ?? "NM"}|${op.lang ?? "en"}`;
      const h = hints.get(k) ?? new Map<string, number>();
      h.set(op.binder_id, (h.get(op.binder_id) ?? 0) + op.delta);
      hints.set(k, h);
    }
    const changed: AllocRow[] = [];
    for (const [k, p] of plan) {
      const cur = new Map<string, number>();
      for (const a of this.allocs.values()) if (allocItemKey(a) === k && a.qty > 0) cur.set(a.binderId, a.qty);
      for (const [b, q] of planAllocations(cur, hints.get(k) ?? new Map(), p.next, this.binders)) {
        if (q === (cur.get(b) ?? 0)) continue;
        const a: Alloc = { binderId: b, cardId: p.op.card_id, finish: p.op.finish!, condition: p.op.condition!, lang: p.op.lang!, qty: q, seq: ++this.seq };
        if (q > 0) this.allocs.set(allocKey(a), a);
        else this.allocs.delete(allocKey(a));
        changed.push(this.row(a));
        this.batchAllocs.set(batchId, [...(this.batchAllocs.get(batchId) ?? []), { a, delta: q - (cur.get(b) ?? 0) }]);
      }
    }
    this.recompute();
    return { batch_id: batchId, duplicate: false, changes: rows.length, items: rows, summary: this.summary, binder_items: changed };
  }

  undo(batchId: string): ApplyResult {
    const b = this.batches.get(batchId);
    if (!b) throw new Error("Nothing to undo");
    if (b.undone) throw new Error("Already undone");
    // Per item: each binder's copies go back where they were; the rest to or from Unsorted (as on the server).
    const net = new Map<string, { op: CollectionOp; d: number; bd: number }>();
    for (const { it, delta } of b.rows) net.set(it.k, { op: { card_id: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang }, d: delta, bd: 0 });
    const ops: CollectionOp[] = [];
    for (const { a, delta } of this.batchAllocs.get(batchId) ?? []) {
      const base = { card_id: a.cardId, finish: a.finish, condition: a.condition, lang: a.lang };
      ops.push({ ...base, delta: -delta, binder_id: a.binderId });
      const v = net.get(allocItemKey(a)) ?? { op: base, d: 0, bd: 0 };
      v.bd += delta;
      net.set(allocItemKey(a), v);
    }
    for (const v of net.values()) if (-v.d + v.bd !== 0) ops.push({ ...v.op, delta: -v.d + v.bd });
    if (!ops.length) throw new Error("Nothing to undo");
    const res = this.apply(ops, "undo");
    b.undone = true;
    const ws = this.batchWants.get(batchId);
    if (ws) res.wants = this.applyWants(ws.map(({ w, delta }) => ({ oracle_id: w.oracleId, card_id: w.cardId, finish: w.finish, delta: -delta })));
    for (const [card, list] of this.ledger) this.ledger.set(card, list.map((e) => (e.batch_id === batchId ? { ...e, undone: true } : e)));
    return res;
  }

  history(cardId: string): HistoryEntry[] {
    const seeded = [...this.seed.values()].filter((it) => it.cardId === cardId).map((it) => ({
      at: this.seedAt, finish: it.finish, condition: it.condition, lang: it.lang, delta: it.qty, qty_after: it.qty,
      source: "import", batch_id: "demo-import", undone: false,
    }));
    return [...(this.ledger.get(cardId) ?? []), ...seeded];
  }

  private recompute() {
    let qty = 0, usd = 0, eur = 0;
    const printings = new Set<string>();
    for (const it of this.items.values()) {
      qty += it.qty;
      printings.add(it.cardId);
      const [u = 0, uf = 0, ue = 0, e = 0, ef = 0] = (this.prices[it.cardId] ?? []).map((x) => x ?? 0);
      usd += it.qty * (it.finish === "foil" ? uf : it.finish === "etched" ? ue : u);
      eur += it.qty * (it.finish === "nonfoil" ? e : ef);
    }
    // Distinct cards need the catalog; keep the fixture's count moving with printings as an approximation.
    const cards = this.summary.unique_cards + (printings.size - this.summary.unique_printings);
    this.summary = { total_qty: qty, unique_printings: printings.size, unique_cards: cards,
                     value_usd: Math.round(usd * 100) / 100, value_eur: Math.round(eur * 100) / 100, seq: this.seq };
  }
}

/** The fixture, imported only in dev builds: production drops the import (and the 200 KB chunk) entirely. */
async function fixture(): Promise<Fixture> {
  if (!import.meta.env.DEV) throw new Error("The Library demo is dev-only");
  return (await import("../../../apps/ios/Table1/DebugResources/library-demo.json")).default as unknown as Fixture;
}

export async function loadDemo(): Promise<DemoBackend> {
  const f = await fixture();
  return new DemoBackend(f);
}

/** The demo decks and cube, with their version history, for the lists store. */
export async function loadDemoLists(): Promise<CardList[]> {
  const f = await fixture();
  return f.lists.map((l) => ({
    id: l.id, kind: l.kind, name: l.name, format: l.format,
    versions: l.versions.map((v) => ({
      number: v.version, at: v.at, note: v.note,
      entries: v.entries.map(([cardId, board, qty]) => ({ cardId, board: board as Board, qty })),
    })),
  }));
}
