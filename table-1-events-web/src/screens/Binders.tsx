import { useMemo, useRef, useState } from "react";
import { Bar, Dialog, Field, Menu, Notice, Row, Screen, Section, SwitchRow, type MenuItem } from "../components/kit";
import { errorMessage } from "../lib/api";
import { coverPrinting, normName, oracleIndexById, searchCatalog, type Catalog } from "../lib/catalog";
import { DEMO_USER, useCollection, type Item } from "../lib/collection";
import { loadDemoLists } from "../lib/libraryDemo";
import { useLists } from "../lib/lists";
import { usdPrice, usdText, usePrices } from "../lib/prices";
import {
  applyWants, binderById, binderTotals, deleteBinder, itemsIn, liveWants, missingLines, moveCopies, placement, saveBinder, useBinders,
  type Binder, type Want,
} from "../lib/binders";
import { CardRow, LibScreen, useCatalog, useLibrarySession } from "./Library";

/* Binders and wants (contract/binders-wants-2026-10-17.md). Library → Binders: Unsorted and each binder; a binder
   lists its cards and can be renamed, flagged for trade or deleted. Library → Wants: the wishlist, then everything a
   deck or cube is missing. Card detail moves copies with `MoveCopies`. Same screens as the iOS app. */

export const UNSORTED = "unsorted";

/** Market value (USD) of the given copies; null when none has a price. */
const value = (items: Item[]) => {
  let any = false, sum = 0;
  for (const it of items) {
    const p = usdPrice(it.cardId, it.finish);
    if (p != null) { any = true; sum += p * it.qty; }
  }
  return any ? sum : null;
};

function SignedOut({ title, onBack }: { title: string; onBack: () => void }) {
  return <Screen><Bar title={title} onBack={onBack} /><Notice tone="info">Sign in to sort your collection.</Notice></Screen>;
}

/** Name and "for trade" for a new binder or an existing one. */
export function BinderEditor({ binder, onClose, onSaved }: { binder: Binder | null; onClose: () => void; onSaved?: (b: Binder) => void }) {
  const [name, setName] = useState(binder?.name ?? "");
  const [trade, setTrade] = useState(binder?.for_trade ?? false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const save = async () => {
    setBusy(true);
    setError(null);
    try {
      const b = await saveBinder(binder?.id ?? null, name.trim().slice(0, 60), trade);
      onClose();
      onSaved?.(b);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <Dialog title={binder ? "Edit binder" : "New binder"} cancelLabel="Cancel" confirmLabel={binder ? "Save" : "Create binder"}
            onCancel={onClose} onConfirm={() => name.trim() && void save()} busy={busy} error={error}>
      <div className="flex flex-col gap-px">
        <Field label="Name" value={name} onChange={setName} placeholder="Trade binder" autoFocus />
        <SwitchRow label="For trade" detail="Trades offers these copies first when you give" on={trade} onChange={setTrade} />
      </div>
    </Dialog>
  );
}

export function BindersScreen({ onBack, onOpen }: { onBack: () => void; onOpen: (id: string) => void }) {
  const { session, ready, userId } = useLibrarySession();
  const col = useCollection(userId);
  const b = useBinders(userId);
  const [creating, setCreating] = useState(false);
  const ids = useMemo(() => [...new Set([...col.items.values()].map((it) => it.cardId))], [col.version]);
  usePrices(ids);
  const totals = useMemo(() => binderTotals(col.items), [col.version, b.version]);
  if (!ready) return <Screen><div className="flex-1" /></Screen>;
  if (!session) return <SignedOut title="Binders" onBack={onBack} />;
  return (
    <Screen>
      <Bar title="Binders" subtitle={`${b.binders.length} · ${b.binders.filter((x) => x.for_trade).length} for trade`} onBack={onBack} />
      {(b.error || col.error) && <Notice tone="error">{b.error ?? col.error}</Notice>}
      <Row title="New binder" detail="A box, a deck box, a trade binder" onClick={() => setCreating(true)} />
      <Row title="Unsorted" detail="Copies not in a binder" value={totals.unsorted.toLocaleString()} onClick={() => onOpen(UNSORTED)} />
      {b.binders.map((x) => (
        <Row key={x.id} title={x.name} accentValue={x.for_trade}
             detail={[x.for_trade ? "For trade" : null, usdText(value(itemsIn(x.id, col.items)))].filter(Boolean).join(" · ") || undefined}
             value={(totals.byBinder.get(x.id) ?? 0).toLocaleString()} onClick={() => onOpen(x.id)} />
      ))}
      {!b.binders.length && (
        <Notice tone="info">Binders say where your copies are. Flag one for trade and Trades offers its cards first when you give.</Notice>
      )}
      {creating && <BinderEditor binder={null} onClose={() => setCreating(false)} onSaved={(x) => onOpen(x.id)} />}
    </Screen>
  );
}

interface CardGroup { key: string; oracle: number; cover: number | null; name: string; norm: string; type: string; qty: number; printings: number }

function group(items: Item[], c: Catalog): CardGroup[] {
  const by = new Map<string, CardGroup & { seen: Set<string>; coverQty: number }>();
  for (const it of items) {
    const p = c.printingIndex.get(it.cardId);
    const oi = p == null ? -1 : c.pOracle[p];
    const key = oi >= 0 ? c.oId[oi] : it.cardId;
    const g = by.get(key) ?? { key, oracle: oi, cover: null, coverQty: 0, name: oi >= 0 ? c.oName[oi] : "Card not in local data yet",
                               norm: oi >= 0 ? c.oNorm[oi] : "", type: oi >= 0 ? c.oType[oi] : "", qty: 0, printings: 0, seen: new Set<string>() };
    g.qty += it.qty;
    if (!g.seen.has(it.cardId)) { g.seen.add(it.cardId); g.printings++; }
    if (p != null && it.qty > g.coverQty) { g.cover = p; g.coverQty = it.qty; }
    by.set(key, g);
  }
  return [...by.values()].sort((a, b) => b.qty - a.qty || (a.norm < b.norm ? -1 : 1));
}

/** One binder's cards (or Unsorted's), grouped by card, most copies first. */
export function BinderScreen({ id, onBack, onCard }: { id: string; onBack: () => void; onCard: (oracleId: string) => void }) {
  const { session, ready, userId } = useLibrarySession();
  const col = useCollection(userId);
  const b = useBinders(userId);
  const { catalog, error } = useCatalog();
  const [q, setQ] = useState("");
  const [menu, setMenu] = useState(false);
  const [editing, setEditing] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [busy, setBusy] = useState(false);
  const [fail, setFail] = useState<string | null>(null);
  const unsorted = id === UNSORTED;
  const binder = unsorted ? undefined : binderById(id);
  const items = useMemo(() => itemsIn(unsorted ? null : id, col.items), [id, col.version, b.version]);
  usePrices(useMemo(() => items.map((it) => it.cardId), [items]));
  const groups = useMemo(() => (catalog ? group(items, catalog) : []), [catalog, items]);
  const n = normName(q);
  const shown = n ? groups.filter((g) => g.norm.includes(n) || normName(g.type).includes(n)) : groups;
  const copies = items.reduce((s, it) => s + it.qty, 0);
  if (!ready) return <Screen><div className="flex-1" /></Screen>;
  if (!session) return <SignedOut title="Binder" onBack={onBack} />;
  const menuItems: MenuItem[] = binder ? [
    { title: "Rename", onClick: () => setEditing(true) },
    { title: binder.for_trade ? "Not for trade" : "For trade",
      detail: binder.for_trade ? "Trades stops offering these first" : "Trades offers these first when you give",
      onClick: () => void saveBinder(binder.id, binder.name, !binder.for_trade).catch((e) => setFail(errorMessage(e))) },
    { title: "Delete binder", onClick: () => setConfirmDelete(true) },
  ] : [];
  return (
    <LibScreen>
      <Bar title={unsorted ? "Unsorted" : binder?.name ?? "Binder"} onBack={onBack}
           subtitle={[`${copies.toLocaleString()} cards`, binder?.for_trade ? "For trade" : null, usdText(value(items))].filter(Boolean).join(" · ")}
           right={binder ? <button type="button" onClick={() => setMenu(true)} className="t1-label hover:text-t1-text px-2 py-1 -my-1">Edit</button> : undefined} />
      {!unsorted && !binder && <Notice tone="info">This binder was deleted.</Notice>}
      {(error || fail || b.error) && <Notice tone="error">{error ?? fail ?? b.error}</Notice>}
      <Field label="Search this binder" value={q} onChange={setQ} placeholder="Name or type" />
      {!catalog && !error && <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {catalog && !groups.length && (
          <Notice tone="info">{unsorted ? "Every copy is in a binder." : "No cards here yet. Open a card and move copies here, or add copies straight into this binder from a trade or an import."}</Notice>
        )}
        {catalog && shown.map((g) => (
          <div key={g.key} style={{ height: 60 }}>
            <CardRow c={catalog} p={g.cover} title={g.name} value={g.qty}
                     detail={`${g.printings} printing${g.printings === 1 ? "" : "s"} · ${g.type}`}
                     onClick={() => g.oracle >= 0 && onCard(g.key)} />
          </div>
        ))}
      </div>
      {menu && binder && <Menu title={binder.name} items={menuItems} onClose={() => setMenu(false)} />}
      {editing && binder && <BinderEditor binder={binder} onClose={() => setEditing(false)} />}
      {confirmDelete && binder && (
        <Dialog title={`Delete ${binder.name}?`} tone="danger" cancelLabel="Cancel" confirmLabel="Delete" busy={busy} error={fail}
                message={`Its ${copies.toLocaleString()} cards stay in your collection, Unsorted. This can't be undone.`}
                onCancel={() => setConfirmDelete(false)}
                onConfirm={async () => {
                  setBusy(true);
                  try {
                    await deleteBinder(binder);
                    onBack();
                  } catch (e) {
                    setFail(errorMessage(e));
                  } finally {
                    setBusy(false);
                  }
                }} />
      )}
    </LibScreen>
  );
}

/**
 * Card detail → an owned item → Move: pick where from (when copies are in more than one place), how many, then where
 * to (a binder, Unsorted, or a new binder).
 */
export function MoveCopies({ item, label, onClose, onMoved }: {
  item: Item; label: string; onClose: () => void; onMoved: (text: string) => void;
}) {
  const { userId } = useLibrarySession();
  const { binders } = useBinders(userId);
  const p = placement(item);
  const sources = [...p.binders.map((h) => ({ id: h.binder.id as string | null, name: h.binder.name, qty: h.qty })),
                   ...(p.unsorted ? [{ id: null as string | null, name: "Unsorted", qty: p.unsorted }] : [])];
  const [from, setFrom] = useState(sources.length === 1 ? sources[0] : null);
  const [qty, setQty] = useState<number | null>(from && from.qty === 1 ? 1 : null);
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Menu closes itself before running the picked item, so a pick marks the step as moving on and the close that
  // came first is dropped; a close with no pick (Cancel, the scrim) ends the flow.
  const picked = useRef(false);
  const close = () => queueMicrotask(() => {
    if (!picked.current) onClose();
    picked.current = false;
  });
  const pick = (f: () => void) => () => {
    picked.current = true;
    f();
  };
  const run = async (to: string | null, toName: string) => {
    if (!from || !qty) return;
    try {
      await moveCopies([{ item, from: from.id, to, qty }]);
      onMoved(`Moved ${qty} ${label} to ${toName}`);
    } catch (e) {
      setError(errorMessage(e));
    }
  };
  if (error) return <Dialog title="Couldn't move them" message={error} cancelLabel="Close" confirmLabel="OK" onCancel={onClose} onConfirm={onClose} />;
  if (creating) return <BinderEditor binder={null} onClose={() => setCreating(false)} onSaved={(b) => void run(b.id, b.name)} />;
  if (!from) {
    return <Menu title={`Move ${label} from`} onClose={close}
                 items={sources.map((s) => ({ title: s.name, detail: `${s.qty} here`, onClick: pick(() => { setFrom(s); if (s.qty === 1) setQty(1); }) }))} />;
  }
  if (!qty) {
    const options = [...new Set([1, Math.floor(from.qty / 2), from.qty].filter((n) => n >= 1))].sort((a, b) => a - b);
    return <Menu title="How many?" onClose={close}
                 items={options.map((n) => ({ title: n === from.qty ? `All ${n}` : String(n), onClick: pick(() => setQty(n)) }))} />;
  }
  const items: MenuItem[] = [
    ...binders.filter((b) => b.id !== from.id).map((b) => ({ title: b.name, detail: b.for_trade ? "For trade" : undefined, onClick: pick(() => void run(b.id, b.name)) })),
    ...(from.id ? [{ title: "Unsorted", onClick: pick(() => void run(null, "Unsorted")) }] : []),
    { title: "New binder…", onClick: pick(() => setCreating(true)) },
  ];
  return <Menu title={`Move ${qty} to`} onClose={close} items={items} />;
}

/* ── wants ────────────────────────────────────────────────────────────── */

export function WantsScreen({ onBack, onCard }: { onBack: () => void; onCard: (oracleId: string) => void }) {
  const { session, ready, userId } = useLibrarySession();
  const col = useCollection(userId);
  const b = useBinders(userId);
  const lists = useLists(userId, userId === DEMO_USER ? loadDemoLists : undefined);
  const { catalog, error } = useCatalog();
  const [adding, setAdding] = useState(false);
  const [editing, setEditing] = useState<Want | null>(null);
  const [pricing, setPricing] = useState<Want | null>(null);
  const [fail, setFail] = useState<string | null>(null);
  const [all, setAll] = useState(false);
  const wants = useMemo(() => liveWants(), [b.version]);
  const missing = useMemo(() => {
    const owned = new Map<string, number>();
    for (const it of col.items.values()) owned.set(`${it.cardId}|${it.finish}`, (owned.get(`${it.cardId}|${it.finish}`) ?? 0) + it.qty);
    return missingLines(lists.lists, owned);
  }, [lists.lists, col.version]);
  usePrices(useMemo(() => wants.flatMap((w) => (w.cardId ? [w.cardId] : [])), [wants]));
  if (!ready) return <Screen><div className="flex-1" /></Screen>;
  if (!session) return <SignedOut title="Wants" onBack={onBack} />;
  const wanted = wants.reduce((n, w) => n + w.qty, 0);
  const short = missing.reduce((n, m) => n + m.short, 0);
  const run = (p: Promise<unknown>) => p.catch((e) => setFail(errorMessage(e)));
  const printingOf = (w: Want): number | null => {
    if (!catalog) return null;
    if (w.cardId) return catalog.printingIndex.get(w.cardId) ?? null;
    const oi = oracleIndexById(catalog, w.oracleId);
    return oi < 0 ? null : coverPrinting(catalog, oi);
  };
  const detail = (w: Want, p: number | null) => {
    const which = w.cardId == null ? "Any printing"
      : [p != null && catalog ? `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}` : null, w.finish ? w.finish[0].toUpperCase() + w.finish.slice(1) : null].filter(Boolean).join(" · ");
    const now = w.cardId ? usdPrice(w.cardId, w.finish ?? "nonfoil") : null;
    return [which, w.maxUsd != null ? `Max $${w.maxUsd}` : null, now != null ? `Now $${now}` : null].filter(Boolean).join(" · ");
  };
  const editItems = (w: Want): MenuItem[] => {
    const base = { oracle_id: w.oracleId, card_id: w.cardId, finish: w.finish };
    const p = printingOf(w);
    return [
      { title: "One more", onClick: () => void run(applyWants([{ ...base, delta: 1 }], "want_changed")) },
      ...(w.qty > 1 ? [{ title: "One fewer", onClick: () => void run(applyWants([{ ...base, delta: -1 }], "want_changed")) }] : []),
      { title: "Max price", detail: w.maxUsd != null ? `$${w.maxUsd}` : "None", onClick: () => setPricing(w) },
      ...(w.cardId == null && p != null && catalog ? [{
        title: `Only ${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`, detail: "Want that printing instead of any",
        onClick: () => void run(applyWants([{ oracle_id: w.oracleId, qty: 0 },
                                            { oracle_id: w.oracleId, card_id: catalog.pId[p], qty: w.qty, max_usd: w.maxUsd }])),
      }] : w.cardId != null ? [{
        title: "Any printing",
        onClick: () => void run(applyWants([{ ...base, qty: 0 }, { oracle_id: w.oracleId, delta: w.qty, max_usd: w.maxUsd }])),
      }] : []),
      { title: "Open card", onClick: () => onCard(w.oracleId) },
      { title: "Remove", onClick: () => void run(applyWants([{ ...base, qty: 0 }], "want_removed")) },
    ];
  };
  return (
    <LibScreen>
      <Bar title="Wants" subtitle={`${wanted} wanted · ${short} missing`} onBack={onBack} />
      {(error || fail || b.error) && <Notice tone="error">{error ?? fail ?? b.error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <Row title="Add a want" detail="Any printing, or one in particular" onClick={() => setAdding(true)} />
        <Section title="Wanted" count={wants.length} />
        {!wants.length && <Notice tone="info">Cards you're after. Gets in a trade that match are marked, and confirming takes them off.</Notice>}
        {catalog && wants.map((w) => {
          const p = printingOf(w);
          const oi = oracleIndexById(catalog, w.oracleId);
          return (
            <div key={`${w.oracleId}|${w.cardId}|${w.finish}`} style={{ height: 60 }}>
              <CardRow c={catalog} p={p} title={oi >= 0 ? catalog.oName[oi] : "Card not in local data yet"} detail={detail(w, p)}
                       value={w.qty} onClick={() => setEditing(w)} />
            </div>
          );
        })}
        <Section title="Missing from decks and cubes" count={short} />
        {catalog && !missing.length && <Notice tone="info">Your decks and cubes have every card they need.</Notice>}
        {catalog && (all ? missing : missing.slice(0, 60)).map((m) => {
          const p = catalog.printingIndex.get(m.cardId) ?? null;
          const oi = p == null ? -1 : catalog.pOracle[p];
          const wantedAlready = oi >= 0 && wants.some((w) => w.oracleId === catalog.oId[oi]);
          return (
            <div key={`${m.cardId}|${m.finish}`} className="flex gap-px" style={{ height: 60 }}>
              <div className="flex-1 min-w-0">
                <CardRow c={catalog} p={p} title={oi >= 0 ? catalog.oName[oi] : "Card not in local data yet"} value={m.short} warn
                         detail={[m.finish === "nonfoil" ? null : m.finish, m.lists.join(", ")].filter(Boolean).join(" · ")}
                         onClick={() => oi >= 0 && onCard(catalog.oId[oi])} />
              </div>
              {oi >= 0 && !wantedAlready && (
                <button type="button" className="bg-t1-surface-hover px-4 t1-label !text-t1-text"
                        onClick={() => void run(applyWants([{ oracle_id: catalog.oId[oi], delta: m.short }], "want_added",
                                                           { any_printing: true, has_max: false, from: "missing" }))}>Want</button>
              )}
            </div>
          );
        })}
        {!all && missing.length > 60 && <Row title={`Show all ${missing.length}`} onClick={() => setAll(true)} />}
      </div>
      {adding && catalog && <WantPicker catalog={catalog} onClose={() => setAdding(false)} onFail={setFail} />}
      {editing && catalog && (
        <Menu title={catalog.oName[oracleIndexById(catalog, editing.oracleId)] ?? "Want"} items={editItems(editing)} onClose={() => setEditing(null)} />
      )}
      {pricing && <WantPrice want={pricing} onClose={() => setPricing(null)} onFail={setFail} />}
    </LibScreen>
  );
}

function WantPrice({ want, onClose, onFail }: { want: Want; onClose: () => void; onFail: (e: string) => void }) {
  const [text, setText] = useState(want.maxUsd != null ? String(want.maxUsd) : "");
  const price = text.trim() === "" ? null : Number(text.replace(",", "."));
  const ok = price == null || (Number.isFinite(price) && price >= 0);
  return (
    <Dialog title="Max price" cancelLabel="Cancel" confirmLabel="Save" onCancel={onClose}
            onConfirm={() => {
              if (!ok) return;
              onClose();
              void applyWants([{ oracle_id: want.oracleId, card_id: want.cardId, finish: want.finish, max_usd: price }], "want_changed")
                .catch((e) => onFail(errorMessage(e)));
            }}>
      <Field label="Most you'd pay, USD (empty for none)" value={text} onChange={setText} type="text" autoFocus />
    </Dialog>
  );
}

/** Search for a card to want (any printing). */
function WantPicker({ catalog, onClose, onFail }: { catalog: Catalog; onClose: () => void; onFail: (e: string) => void }) {
  const [q, setQ] = useState("");
  const [added, setAdded] = useState<string | null>(null);
  const hits = useMemo(() => searchCatalog(catalog, q, 30), [catalog, q]);
  return (
    <Dialog title="Add a want" cancelLabel="Done" confirmLabel="Done" onCancel={onClose} onConfirm={onClose}>
      <Field label="Card name" value={q} onChange={setQ} placeholder="Lightning Bolt" autoFocus />
      {added && <p className="t1-label">{added}</p>}
      <div className="max-h-[50vh] overflow-y-auto flex flex-col gap-px">
        {hits.map((o) => (
          <div key={o} style={{ height: 60 }}>
            <CardRow c={catalog} p={coverPrinting(catalog, o)} title={catalog.oName[o]} detail={catalog.oType[o]} value="Want"
                     onClick={() => void applyWants([{ oracle_id: catalog.oId[o], delta: 1 }], "want_added",
                                                    { any_printing: true, has_max: false, from: "search" })
                       .then(() => setAdded(`Wanted ${catalog.oName[o]}`), (e) => onFail(errorMessage(e)))} />
          </div>
        ))}
      </div>
    </Dialog>
  );
}

/** "Add to wants" on card detail: any printing, or the one shown. */
export function WantCardRow({ catalog, oi, shown, onAdded }: { catalog: Catalog; oi: number; shown: number | null; onAdded: (t: string) => void }) {
  const { userId } = useLibrarySession();
  const b = useBinders(userId);
  const [open, setOpen] = useState(false);
  const mine = useMemo(() => liveWants().filter((w) => w.oracleId === catalog.oId[oi]), [b.version, catalog, oi]);
  const n = mine.reduce((s, w) => s + w.qty, 0);
  const want = (p: number | null) =>
    void applyWants([{ oracle_id: catalog.oId[oi], card_id: p == null ? null : catalog.pId[p], delta: 1 }], "want_added",
                    { any_printing: p == null, has_max: false, from: "card" })
      .then(() => onAdded(`Wanted 1 ${p == null ? catalog.oName[oi] : `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`}`));
  return (
    <>
      <Row title={n ? `Wanted · ${n}` : "Add to wants"} detail={n ? "Want one more" : "Trades marks it when you get one"} onClick={() => setOpen(true)} />
      {open && (
        <Menu title={`Want ${catalog.oName[oi]}`} onClose={() => setOpen(false)} items={[
          { title: "Any printing", onClick: () => want(null) },
          ...(shown != null ? [{ title: `Only ${catalog.pSet[shown].toUpperCase()} #${catalog.pCn[shown]}`, onClick: () => want(shown) }] : []),
        ]} />
      )}
    </>
  );
}
