// Dev server only: `/library?demo` opens the Library without signing in, on the same fixture the iOS Debug
// demo uses (apps/ios/Table1/DebugResources/library-demo.json: 2,000 cards, five Modern decks, a Vintage
// cube). Writes stay in memory. Production builds drop all of this (import.meta.env.DEV is false there).
import type { ApplyResult, CollectionOp, HistoryEntry, Item, LibrarySummary } from "./collection";

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
  summary: LibrarySummary;
  items: [string, Item["finish"], Item["condition"], string, number][];
  prices: Record<string, (number | null)[]>;
}

export class DemoBackend {
  items = new Map<string, Item>();
  summary: LibrarySummary;
  private seq = 0;
  private prices: Fixture["prices"];
  private ledger = new Map<string, HistoryEntry[]>();
  private batches = new Map<string, { rows: { it: Item; delta: number }[]; undone: boolean }>();
  private seedAt = new Date().toISOString();
  private seed = new Map<string, Item>();

  constructor(f: Fixture) {
    this.prices = f.prices;
    for (const [cardId, finish, condition, lang, qty] of f.items) {
      const k = `${cardId}|${finish}|${condition}|${lang}`;
      this.items.set(k, { k, cardId, finish, condition, lang, qty, seq: ++this.seq });
    }
    this.seed = new Map(this.items);
    this.summary = { ...f.summary, seq: this.seq };
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
    this.recompute();
    return { batch_id: batchId, duplicate: false, changes: rows.length, items: rows, summary: this.summary };
  }

  undo(batchId: string): ApplyResult {
    const b = this.batches.get(batchId);
    if (!b) throw new Error("Nothing to undo");
    if (b.undone) throw new Error("Already undone");
    const res = this.apply(b.rows.map(({ it, delta }) => ({ card_id: it.cardId, finish: it.finish, condition: it.condition,
                                                              lang: it.lang, delta: -delta })), "undo");
    b.undone = true;
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

export async function loadDemo(): Promise<DemoBackend> {
  const f = (await import("../../../apps/ios/Table1/DebugResources/library-demo.json")).default as unknown as Fixture;
  return new DemoBackend(f);
}
