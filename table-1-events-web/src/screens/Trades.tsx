import { useEffect, useMemo, useRef, useState } from "react";
import { Bar, BigAction, Field, GhostAction, Modal, Notice, Row, Screen, Section, Segmented } from "../components/kit";
import { errorMessage } from "../lib/api";
import { coverPrinting, normName, searchCatalog, type Catalog } from "../lib/catalog";
import { useCollection, type Condition, type Finish, type Item } from "../lib/collection";
import { editList, entriesOf, useLists, type CardList, type ListOp } from "../lib/lists";
import { loadDemoLists } from "../lib/libraryDemo";
import { usdPrice, usdText, usePrices } from "../lib/prices";
import { confirmTrade, deleteTrade, lineKey, saveTrade, useTrades, type Trade, type TradeLine } from "../lib/trades";
import { DEMO_USER } from "../lib/collection";
import { capture } from "../lib/telemetry";
import { binderById, forTrade, liveWants, missingLines, useBinders, wantFor } from "../lib/binders";
import { CONDITIONS, CardArt, CardRow, LibScreen, useCatalog, useLibrarySession } from "./Library";

/* Trades (contract/trades-2026-10-16.md): what you give (copies you own) and what you get (any printing). Drafts
   save as you build them; Confirm applies both sides to the collection in one batch. Scanning is on the apps. */

const FINISH_LABEL: Record<Finish, string> = { nonfoil: "Non-foil", foil: "Foil", etched: "Etched" };
const FINISHES: Finish[] = ["nonfoil", "foil", "etched"];
const LETTER: Record<Finish, string> = { nonfoil: "n", foil: "f", etched: "e" };
const finishesOf = (c: Catalog, p: number) => FINISHES.filter((f) => c.pFinishes[p].includes(LETTER[f]));

export function TradesScreen({ onBack, onOpen, onNew }: { onBack: () => void; onOpen: (id: string) => void; onNew: () => void }) {
  const { session } = useLibrarySession();
  const { trades, loaded, error } = useTrades();
  const drafts = trades.filter((t) => t.status === "draft");
  const done = trades.filter((t) => t.status === "confirmed");
  if (!session) return <Screen><Bar title="Trades" onBack={onBack} /><Notice tone="info">Sign in to trade.</Notice></Screen>;
  const row = (t: Trade) => {
    const give = t.gives.reduce((n, l) => n + l.qty, 0), get = t.gets.reduce((n, l) => n + l.qty, 0);
    return <Row key={t.id} title={t.partner ?? "Trade"} detail={`Give ${give} · get ${get} · ${new Date(t.confirmed_at ?? t.updated_at).toLocaleDateString()}`}
                onClick={() => onOpen(t.id)} />;
  };
  return (
    <Screen>
      <Bar title="Trades" subtitle={loaded ? `${drafts.length} open` : undefined} onBack={onBack} />
      {error && <Notice tone="error">{error}</Notice>}
      <Row title="New trade" detail="What you give, what you get" onClick={onNew} />
      {drafts.length > 0 && <Section title="Open" count={drafts.length} />}
      {drafts.map(row)}
      {done.length > 0 && <Section title="Confirmed" count={done.length} />}
      {done.map(row)}
      {loaded && trades.length === 0 && <Notice tone="info">No trades yet.</Notice>}
    </Screen>
  );
}

type Conflict = { list: CardList; oracle: number; short: number };

export function TradeScreen({ id, onBack, onSaved }: { id: string | null; onBack: () => void; onSaved: (id: string) => void }) {
  const { userId } = useLibrarySession();
  const col = useCollection(userId);
  const lists = useLists(userId, userId === DEMO_USER ? loadDemoLists : undefined);
  const { catalog, error: catError } = useCatalog();
  const { trades, loaded } = useTrades();
  const binders = useBinders(userId);
  const [trade, setTrade] = useState<Trade | null>(null);
  const [partner, setPartner] = useState("");
  const [gives, setGives] = useState<TradeLine[]>([]);
  const [gets, setGets] = useState<TradeLine[]>([]);
  const [started, setStarted] = useState(id == null);
  const [picking, setPicking] = useState<"give" | "get" | null>(null);
  const [editing, setEditing] = useState<{ side: "give" | "get"; k: string } | null>(null);
  const [conflicts, setConflicts] = useState<Conflict[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const saveTimer = useRef<number | null>(null);
  const confirmed = trade?.status === "confirmed";

  useEffect(() => {
    if (started || !loaded || !id) return;
    const t = trades.find((x) => x.id === id);
    if (t) {
      setTrade(t);
      setPartner(t.partner ?? "");
      setGives(t.gives);
      setGets(t.gets);
    }
    setStarted(true);
  }, [loaded, id, trades, started]);

  const ids = useMemo(() => [...new Set([...gives, ...gets].map((l) => l.card_id))], [gives, gets]);
  /** What a get is to you: a want (and whether it's over your max price), or missing from a deck or cube. */
  const missing = useMemo(() => {
    const owned = new Map<string, number>();
    for (const it of col.items.values()) owned.set(`${it.cardId}|${it.finish}`, (owned.get(`${it.cardId}|${it.finish}`) ?? 0) + it.qty);
    return new Map(missingLines(lists.lists, owned).map((m) => [`${m.cardId}|${m.finish}`, m]));
  }, [lists.lists, col.version]);
  const wantNote = (l: TradeLine): { text: string; over: boolean } | null => {
    const p = catalog?.printingIndex.get(l.card_id);
    if (!catalog || p == null) return null;
    const w = wantFor(catalog.oId[catalog.pOracle[p]], l.card_id, l.finish, liveWants());
    if (w) {
      const price = usdPrice(l.card_id, l.finish);
      return w.maxUsd != null && price != null && price > w.maxUsd ? { text: `Want · over your max $${w.maxUsd}`, over: true } : { text: "Want", over: false };
    }
    const m = missing.get(`${l.card_id}|${l.finish}`);
    return m ? { text: `Missing · ${m.lists.slice(0, 2).join(", ")}`, over: false } : null;
  };
  void binders.version;
  usePrices(ids);

  // Drafts save half a second after the last change.
  useEffect(() => {
    if (!started || confirmed || (!trade && !gives.length && !gets.length)) return;
    if (saveTimer.current) window.clearTimeout(saveTimer.current);
    saveTimer.current = window.setTimeout(() => {
      saveTrade(trade, partner.trim() || null, gives, gets).then((t) => {
        if (!trade) onSaved(t.id);
        setTrade(t);
      }, (e) => setError(errorMessage(e)));
    }, 500);
    return () => {
      if (saveTimer.current) window.clearTimeout(saveTimer.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [gives, gets, partner, started]);

  /** Market value of a side; null when none of its cards has a market price. */
  const sum = (lines: TradeLine[]) => {
    const priced = lines.filter((l) => usdPrice(l.card_id, l.finish) != null);
    return priced.length ? priced.reduce((n, l) => n + l.qty * usdPrice(l.card_id, l.finish)!, 0) : null;
  };

  const add = (side: "give" | "get", line: TradeLine) => {
    const setter = side === "give" ? setGives : setGets;
    setter((lines) => {
      const i = lines.findIndex((l) => lineKey(l) === lineKey(line));
      if (i < 0) return [...lines, line];
      const have = col.items.get(lineKey(line))?.qty ?? Infinity;
      return lines.map((l, j) => (j === i ? { ...l, qty: side === "give" ? Math.min(l.qty + line.qty, have) : l.qty + line.qty } : l));
    });
  };
  const update = (side: "give" | "get", k: string, next: TradeLine | null) => {
    const setter = side === "give" ? setGives : setGets;
    setter((lines) => (next ? lines.map((l) => (lineKey(l) === k ? next : l)) : lines.filter((l) => lineKey(l) !== k)));
    if (next && lineKey(next) !== k) setEditing({ side, k: lineKey(next) });
    if (!next) setEditing(null);
  };

  /** Lists that would need more copies than you'll have left after giving these away. */
  const findConflicts = (): Conflict[] => {
    if (!catalog) return [];
    const oracleOf = (cardId: string) => {
      const p = catalog.printingIndex.get(cardId);
      return p == null ? -1 : catalog.pOracle[p];
    };
    const giving = new Set(gives.map((l) => oracleOf(l.card_id)).filter((o) => o >= 0));
    if (!giving.size) return [];
    const have = new Map<number, number>();
    for (const it of col.items.values()) {
      const o = oracleOf(it.cardId);
      if (giving.has(o)) have.set(o, (have.get(o) ?? 0) + it.qty);
    }
    for (const l of gives) have.set(oracleOf(l.card_id), (have.get(oracleOf(l.card_id)) ?? 0) - l.qty);
    for (const l of gets) if (giving.has(oracleOf(l.card_id))) have.set(oracleOf(l.card_id), (have.get(oracleOf(l.card_id)) ?? 0) + l.qty);
    const out: Conflict[] = [];
    for (const list of lists.lists) {
      const need = new Map<number, number>();
      for (const e of entriesOf(list)) {
        if (e.board === "maybe") continue;
        const o = oracleOf(e.cardId);
        if (giving.has(o)) need.set(o, (need.get(o) ?? 0) + e.qty);
      }
      for (const [o, n] of need) {
        const left = Math.max(have.get(o) ?? 0, 0);
        if (n > left) out.push({ list, oracle: o, short: n - left });
      }
    }
    return out;
  };

  const run = async (remove: Conflict[]) => {
    setConflicts(null);
    setBusy(true);
    setError(null);
    try {
      if (saveTimer.current) window.clearTimeout(saveTimer.current);
      const saved = await saveTrade(trade, partner.trim() || null, gives, gets);
      const fromTrade = gives.filter((l) => binderById(l.binder_id)?.for_trade).reduce((n, l) => n + l.qty, 0);
      const res = await confirmTrade(saved, (cardId) => {
        const p = catalog?.printingIndex.get(cardId);
        return catalog && p != null ? catalog.oId[catalog.pOracle[p]] : null;
      });
      capture("trade_confirmed", {
        gives: gives.reduce((n, l) => n + l.qty, 0),
        gets: gets.reduce((n, l) => n + l.qty, 0),
        list_conflict: remove.length ? "removed" : conflicts ? "kept" : "none",
        wants_met: res.wantsMet, from_trade_binder: fromTrade,
      });
      setTrade({ ...saved, status: "confirmed" });
      // Take the missing copies out of each list, sideboard first.
      for (const c of remove) {
        if (!catalog) break;
        let left = c.short;
        const entries = entriesOf(c.list).filter((e) => e.board !== "maybe")
          .sort((a, b) => Number(b.board === "side") - Number(a.board === "side"));
        const ops: ListOp[] = [];
        for (const e of entries) {
          if (left <= 0) break;
          const p = catalog.printingIndex.get(e.cardId);
          if (p == null || catalog.pOracle[p] !== c.oracle) continue;
          const n = Math.min(left, e.qty);
          ops.push({ card_id: e.cardId, board: e.board, finish: e.finish, delta: -n });
          left -= n;
        }
        if (ops.length) await editList(c.list.id, ops);
      }
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const confirm = () => {
    const c = findConflicts();
    if (c.length) setConflicts(c);
    else void run([]);
  };

  if (!catalog) {
    return (
      <Screen>
        <Bar title="Trade" onBack={onBack} />
        {catError ? <Notice tone="error">{catError}</Notice> : <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>}
      </Screen>
    );
  }

  const line = (side: "give" | "get", l: TradeLine) => {
    const p = catalog.printingIndex.get(l.card_id) ?? null;
    const name = p == null ? "Card" : catalog.oName[catalog.pOracle[p]];
    const printing = [p == null ? null : `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`, FINISH_LABEL[l.finish]].filter(Boolean).join(" · ");
    const state = [l.condition, usdText(usdPrice(l.card_id, l.finish))].filter(Boolean).join(" · ");
    const k = lineKey(l);
    const open = editing?.side === side && editing.k === k;
    const note = side === "get" ? wantNote(l) : null;
    const from = side === "give" ? binderById(l.binder_id)?.name : undefined;
    return (
      <div key={k} className="flex flex-col gap-px">
        <button type="button" onClick={confirmed ? undefined : () => setEditing(open ? null : { side, k })}
                className={`bg-t1-surface hover:bg-t1-surface-hover px-2 py-1.5 flex items-center gap-2 text-left w-full border-l-2 ${
                  note ? (note.over ? "border-t1-error" : "border-t1-accent") : "border-transparent"}`}>
          <CardArt c={catalog} p={p} width={28} />
          <span className="flex-1 min-w-0 flex flex-col gap-0.5">
            <span className="text-[12px] truncate">{name}</span>
            <span className="t1-label truncate">{printing}</span>
            <span className="t1-label truncate">{state}</span>
            {note && <span className={`t1-label truncate ${note.over ? "!text-t1-error" : "!text-t1-accent"}`}>{note.text}</span>}
            {from && <span className="t1-label truncate">{from}</span>}
          </span>
          <span className="shrink-0 text-[15px] tabular-nums">{l.qty}</span>
        </button>
        {open && (
          <div className="flex flex-col gap-px">
            <div className="flex gap-px">
              <GhostAction label="−" disabled={l.qty <= 1} onClick={() => update(side, k, { ...l, qty: l.qty - 1 })} />
              <GhostAction label="+" disabled={side === "give" && l.qty >= (col.items.get(k)?.qty ?? 0)}
                           onClick={() => update(side, k, { ...l, qty: l.qty + 1 })} />
            </div>
            <GhostAction label="Remove" onClick={() => update(side, k, null)} />
            {side === "get" && p != null && (
              <>
                {finishesOf(catalog, p).length > 1 && (
                  <Segmented options={finishesOf(catalog, p).map((f) => ({ value: f, label: FINISH_LABEL[f] }))} value={l.finish}
                             onChange={(f) => update(side, k, { ...l, finish: f })} />
                )}
                <Segmented columns={3} options={CONDITIONS.map((c) => ({ value: c, label: c }))} value={l.condition}
                           onChange={(c) => update(side, k, { ...l, condition: c })} />
              </>
            )}
          </div>
        )}
      </div>
    );
  };

  const sideBlock = (side: "give" | "get") => {
    const lines = side === "give" ? gives : gets;
    const n = lines.reduce((a, l) => a + l.qty, 0);
    const v = usdText(sum(lines));
    return (
      <div className="min-w-0 flex flex-col gap-px">
        <Section title={`${side === "give" ? "You give" : "You get"} · ${n}${v ? ` · ${v}` : ""}`} />
        {lines.map((l) => line(side, l))}
        {!confirmed && <GhostAction label="Add" onClick={() => setPicking(side)} />}
      </div>
    );
  };

  const g = sum(gives), r = sum(gets);
  return (
    <LibScreen>
      <Bar title={partner.trim() || "Trade"} subtitle={confirmed ? "Confirmed" : "Draft"} onBack={onBack}
           right={trade && !confirmed ? (
             <button type="button" className="t1-label hover:text-t1-text px-2 py-1 -my-1" onClick={() => setConfirmDelete(true)}>Delete</button>
           ) : undefined} />
      {(error || col.error) && <Notice tone="error">{error ?? col.error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {confirmed ? (partner && <Row title="With" detail={partner} />)
          : <Field label="Trading with" value={partner} onChange={setPartner} placeholder="Name" />}
        {/* Two columns: what you give | what you get. */}
        <div className="grid grid-cols-2 gap-px items-start">
          {sideBlock("give")}
          {sideBlock("get")}
        </div>
        <Row title="Market value" detail={`Give ${usdText(g) ?? "—"} · get ${usdText(r) ?? "—"} · TCGplayer market`}
             value={g != null && r != null ? `${r - g >= 0 ? "+" : "−"}${usdText(Math.abs(r - g))}` : undefined} />
      </div>
      {!confirmed && (
        <BigAction label="Confirm trade" tone="accent" busy={busy} disabled={!gives.length && !gets.length} onClick={confirm} />
      )}

      {picking && (
        <PickPanel catalog={catalog} give={picking === "give"} items={col.items}
                   onPick={(l) => add(picking, l)} onClose={() => setPicking(null)} />
      )}
      {conflicts && (
        <Modal title="Cards in your decks" onClose={() => setConflicts(null)}>
          <p className="text-[12px] leading-[18px] text-t1-muted">
            You're giving away copies these lists use:{" "}
            {conflicts.map((c) => `${catalog.oName[c.oracle]} in ${c.list.name}`).join(", ")}.
          </p>
          <div className="flex flex-col gap-px">
            <GhostAction label="Remove them from the lists" onClick={() => void run(conflicts)} />
            <GhostAction label="Keep them listed (shown as missing)" onClick={() => void run([])} />
            <GhostAction label="Cancel" onClick={() => setConflicts(null)} />
          </div>
        </Modal>
      )}
      {confirmDelete && trade && (
        <Modal title="Delete this trade?" onClose={() => setConfirmDelete(false)}>
          <div className="flex gap-px">
            <GhostAction label="Keep" onClick={() => setConfirmDelete(false)} />
            <GhostAction label="Delete" onClick={() => { void deleteTrade(trade); onBack(); }} />
          </div>
        </Modal>
      )}
    </LibScreen>
  );
}

/** Search for a card: giving, only copies you own; getting, any card (default printing, near mint). */
function PickPanel({ catalog, give, items, onPick, onClose }: {
  catalog: Catalog; give: boolean; items: Map<string, Item>;
  onPick: (l: TradeLine) => void; onClose: () => void;
}) {
  const [q, setQ] = useState("");
  const [added, setAdded] = useState<string | null>(null);
  const hits = useMemo(() => (give ? [] : searchCatalog(catalog, q, 30)), [catalog, q, give]);
  const owned = useMemo(() => {
    if (!give) return [];
    const n = normName(q);
    const out: { it: Item; p: number; name: string }[] = [];
    for (const it of items.values()) {
      const p = catalog.printingIndex.get(it.cardId);
      if (p == null) continue;
      const o = catalog.pOracle[p];
      if (n && !catalog.oNorm[o].includes(n)) continue;
      out.push({ it, p, name: catalog.oName[o] });
    }
    // Copies in for-trade binders first (contract/binders-wants-2026-10-17.md), then by name.
    const trade = (it: Item) => (forTrade(it.k).qty > 0 ? 0 : 1);
    return out.sort((a, b) => trade(a.it) - trade(b.it) || a.name.localeCompare(b.name) || a.it.k.localeCompare(b.it.k)).slice(0, 100);
  }, [catalog, items, q, give]);
  const take = (l: TradeLine, name: string) => {
    onPick(l);
    setAdded(`Added ${name}`);
  };
  return (
    <Modal title={give ? "Add what you give" : "Add what you get"} onClose={onClose}>
      <Field label={give ? "Search your collection" : "Card name"} value={q} onChange={setQ} placeholder="Lightning Bolt" autoFocus />
      {added && <p className="t1-label">{added}</p>}
      <div className="max-h-[50vh] overflow-y-auto flex flex-col gap-px">
        {give ? owned.map(({ it, p, name }) => {
          const t = forTrade(it.k);
          const where = t.binderId ? `${t.qty} in ${binderById(t.binderId)?.name}` : null;
          return (
            <div key={it.k} style={{ height: 60 }}>
              <CardRow c={catalog} p={p} title={name} value={it.qty}
                       detail={[`${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`, FINISH_LABEL[it.finish], it.condition, where].filter(Boolean).join(" · ")}
                       onClick={() => take({ card_id: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, qty: 1, binder_id: t.binderId }, name)} />
            </div>
          );
        }) : hits.map((o) => {
          const p: number | null = coverPrinting(catalog, o);
          return (
            <div key={o} style={{ height: 60 }}>
              <CardRow c={catalog} p={p} title={catalog.oName[o]} detail={catalog.oType[o]}
                       onClick={() => p != null && take({
                         card_id: catalog.pId[p], finish: finishesOf(catalog, p)[0] ?? "nonfoil", condition: "NM" as Condition, lang: "en", qty: 1,
                       }, catalog.oName[o])} />
            </div>
          );
        })}
      </div>
      <GhostAction label="Done" onClick={onClose} />
    </Modal>
  );
}
