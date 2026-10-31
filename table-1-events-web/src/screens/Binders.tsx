import { useEffect, useMemo, useRef, useState } from "react";
import { Bar, Dialog, Field, Menu, Modal, Notice, Row, Screen, Section, SwitchRow, type MenuItem } from "../components/kit";
import { errorMessage } from "../lib/api";
import { RARITY_NAME, basicCardIds, coverPrinting, normName, oracleIndexById, type Catalog } from "../lib/catalog";
import { DEMO_USER, applyOps, undoBatch, useCollection, type Finish, type Item } from "../lib/collection";
import { cardMatches, moveInSource, printingMatches, repointWant, type Place } from "../lib/librarySearch";
import { capture } from "../lib/telemetry";
import { GROUPING_KEY, groupLabel, groupSections, keysOf, useStoredGrouping } from "../lib/cardGrouping";
import { SORT_KEY, applySort, sortKeyOf, useStoredSort } from "../lib/cardSort";
import { loadDemoLists } from "../lib/libraryDemo";
import { useLists } from "../lib/lists";
import { usdPrice, usdText, usePrices } from "../lib/prices";
import { cartDirect, cartMenu, loadWantPrices, setWantAlerts, tcgplayerCart, tcgplayerEnabled, useWantPrices, wantDetail, wantPrice, wantTrend, type CartEntry, type CartItem } from "../lib/wantPrices";
import {
  applyWants, binderById, binderTotals, deleteBinder, itemsIn, liveWants, missingLines, moveCopies, placement, saveBinder, useBinders,
  type Binder, type Want,
} from "../lib/binders";
import {
  CardGroupRow, CardRow, CardTile, HeroListRow, LibScreen, StackRows, ViewButton, useBoxWidth, useCatalog, useLibraryHeroes, useLibrarySession,
  useStoredLayout, type StackCardItem,
} from "./Library";
import { langForNew, storeAddLang, storedAddLang } from "../lib/languages";
import { NewCopiesLanguageRow } from "./Languages";
import { COLLAPSED, addPart, isOpen, sortParts, toggleOne, type Disclosure, type Part } from "../lib/printings";
import { heroPrintings, heroesOf, isHero } from "../lib/heroes";
import { CardSearchBar, CardSearchStatus, useCardSearch } from "./CardSearch";
import { ShareRow } from "./Share";
import { WhoSeesRow } from "../components/PersonActions";
import { offerForTradeIfDue } from "../lib/friends";
import { cardOfCatalog } from "../lib/ownedByCard";

/* Binders and wants (contract/binders-wants-2026-10-17.md). Library → Binders: Unsorted and each binder; a binder
   lists its cards and can be renamed, flagged for trade or deleted. Library → Wants: the wishlist, then everything a
   deck or cube is missing. Card detail moves copies with `MoveCopies`. Same screens as the iOS app. */

export const UNSORTED = "unsorted";

/** Market value (USD) of the given copies; null when none has a price. */
const value = (items: Item[]) => {
  let any = false, sum = 0;
  for (const it of items) {
    const p = usdPrice(it.cardId, it.finish, it.condition);
    if (p != null) { any = true; sum += p * it.qty; }
  }
  return any ? sum : null;
};

function SignedOut({ title, onBack }: { title: string; onBack: () => void }) {
  return <Screen><Bar title={title} onBack={onBack} /><Notice tone="info">Sign in to sort your collection.</Notice></Screen>;
}

/** `library_searched` once per visit, when the screen's search is first used (never the text). */
export function useSearchUsed(q: string, screen: string) {
  const sent = useRef(false);
  if (q && !sent.current) {
    sent.current = true;
    queueMicrotask(() => capture("library_searched", { screen }));
  }
}

/** The card an item is a copy of: oracle id, or the printing id when the card is newer than the local catalog. */
const cardKey = (it: Item, c: Catalog) => {
  const p = c.printingIndex.get(it.cardId);
  return p == null ? it.cardId : c.oId[c.pOracle[p]];
};

/** Every place an item's copies are, Unsorted as a null binder. */
const placesOf = (items: Item[]): Place[] => items.flatMap((it) => {
  const p = placement(it);
  return [...p.binders.map((h) => ({ item: it, from: h.binder, qty: h.qty })), ...(p.unsorted ? [{ item: it, from: null, qty: p.unsorted }] : [])];
});

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
      // Marking a binder For trade while For trade reaches no one: offer once (contract § UX rules 8).
      if (trade && !binder?.for_trade) void offerForTradeIfDue();
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

export function BindersScreen({ onBack, onOpen, onCard }: { onBack: () => void; onOpen: (id: string) => void; onCard?: (oracleId: string) => void }) {
  const { session, ready, userId } = useLibrarySession();
  const col = useCollection(userId);
  const b = useBinders(userId);
  const [creating, setCreating] = useState(false);
  const ids = useMemo(() => [...new Set([...col.items.values()].map((it) => it.cardId))], [col.version]);
  usePrices(ids);
  const totals = useMemo(() => binderTotals(col.items), [col.version, b.version]);
  const { catalog } = useCatalog();
  const [q, setQ] = useState("");
  useSearchUsed(q, "binders");
  const heroes = useLibraryHeroes();
  /** Each binder's hero cards, as the printings it holds. */
  const heroArt = useMemo(() => {
    const m = new Map<string, number[]>();
    if (!catalog) return m;
    for (const x of b.binders) {
      const h = heroesOf({ kind: "binder", id: x.id }, heroes);
      if (h.length) m.set(x.id, heroPrintings(catalog, h, itemsIn(x.id, col.items).slice().sort((i, j) => j.qty - i.qty).map((it) => it.cardId)));
    }
    return m;
  }, [catalog, heroes, b.version, col.version]);
  // Owned cards matching the search, most copies first, each saying where its copies are.
  const found = useMemo(() => {
    if (!catalog || !normName(q)) return [];
    const items = [...col.items.values()];
    return group(items, catalog).filter((g) => cardMatches(q, g.name, g.type)).map((g) => {
      const where = new Map<string, number>();
      let un = 0;
      for (const it of items) {
        if (cardKey(it, catalog) !== g.key) continue;
        const p = placement(it);
        for (const h of p.binders) where.set(h.binder.name, (where.get(h.binder.name) ?? 0) + h.qty);
        un += p.unsorted;
      }
      const named = [...where].sort((x, y) => x[0].toLowerCase().localeCompare(y[0].toLowerCase())).map(([n, v]) => `${n} ${v}`);
      return { g, place: [...named, ...(un ? [`Unsorted ${un}`] : [])].join(" · ") };
    });
  }, [catalog, q, col.version, b.version]);
  if (!ready) return <Screen><div className="flex-1" /></Screen>;
  if (!session) return <SignedOut title="Binders" onBack={onBack} />;
  return (
    <Screen>
      <Bar title="Binders" subtitle={`${b.binders.length} · ${b.binders.filter((x) => x.for_trade).length} for trade`} onBack={onBack} />
      {(b.error || col.error) && <Notice tone="error">{b.error ?? col.error}</Notice>}
      {col.items.size > 0 && <Field label="Find a card in your binders" value={q} onChange={setQ} placeholder="Name or type" />}
      {normName(q) ? (
        <>
          <Section title="Cards" count={found.length} />
          {!found.length && <Row title="No cards you own match" />}
          {catalog && found.map(({ g, place }) => (
            <div key={g.key} style={{ height: 60 }}>
              <CardRow c={catalog} p={g.cover} title={g.name} detail={place} value={g.qty} onClick={() => g.oracle >= 0 && onCard?.(g.key)} />
            </div>
          ))}
        </>
      ) : <>
      <Row title="New binder" detail="A box, a deck box, a trade binder" onClick={() => setCreating(true)} />
      <Row title="Unsorted" detail="Copies not in a binder" value={totals.unsorted.toLocaleString()} onClick={() => onOpen(UNSORTED)} />
      {b.binders.some((x) => x.for_trade) && <ShareRow target={{ part: "for_trade", id: null, name: null }} from="binders" />}
      {b.binders.map((x) => (
        <HeroListRow key={x.id} c={catalog} heroes={heroArt.get(x.id) ?? []} title={x.name} accentValue={x.for_trade}
                     detail={[x.for_trade ? "For trade" : null, usdText(value(itemsIn(x.id, col.items)))].filter(Boolean).join(" · ") || undefined}
                     value={(totals.byBinder.get(x.id) ?? 0).toLocaleString()} onClick={() => onOpen(x.id)} />
      ))}
      {!b.binders.length && (
        <Notice tone="info">Binders say where your copies are. Flag one for trade and Trades offers its cards first when you give.</Notice>
      )}
      </>}
      {creating && <BinderEditor binder={null} onClose={() => setCreating(false)} onSaved={(x) => onOpen(x.id)} />}
    </Screen>
  );
}

interface CardGroup {
  key: string; oracle: number; cover: number | null; name: string; norm: string; type: string; qty: number; printings: number;
  coverFinish: Finish;
  /** Copies per printing and finish, oldest printing first: the rows a card opens into. */
  parts: Part[];
}

function group(items: Item[], c: Catalog): CardGroup[] {
  const by = new Map<string, CardGroup & { seen: Set<string>; coverQty: number }>();
  for (const it of items) {
    const p = c.printingIndex.get(it.cardId);
    const oi = p == null ? -1 : c.pOracle[p];
    const key = oi >= 0 ? c.oId[oi] : it.cardId;
    const g = by.get(key) ?? { key, oracle: oi, cover: null, coverQty: 0, name: oi >= 0 ? c.oName[oi] : "Card not in local data yet",
                               norm: oi >= 0 ? c.oNorm[oi] : "", type: oi >= 0 ? c.oType[oi] : "", qty: 0, printings: 0, seen: new Set<string>(),
                               coverFinish: "nonfoil" as Finish, parts: [] };
    g.qty += it.qty;
    if (!g.seen.has(it.cardId)) { g.seen.add(it.cardId); g.printings++; }
    if (p != null && it.qty > g.coverQty) { g.cover = p; g.coverQty = it.qty; g.coverFinish = it.finish; }
    addPart(g.parts, it.cardId, it.finish, it.qty, p ?? null, it.condition);
    by.set(key, g);
  }
  for (const g of by.values()) sortParts(c, g.parts);
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
  const [adding, setAdding] = useState(false);
  const [printings, setPrintings] = useState<Disclosure>(COLLAPSED);
  const [layout, setLayout] = useStoredLayout("table1.library.binder.layout", "table1.library.binder.grid");
  const [grouping, setGrouping] = useStoredGrouping(GROUPING_KEY.binder, "none", false);
  const [sort, setSort] = useStoredSort(SORT_KEY.binder, "binder");
  const [boxRef, boxWidth] = useBoxWidth();
  const heroes = useLibraryHeroes();
  useSearchUsed(q, "binder");
  const unsorted = id === UNSORTED;
  const binder = unsorted ? undefined : binderById(id);
  const items = useMemo(() => itemsIn(unsorted ? null : id, col.items), [id, col.version, b.version]);
  usePrices(useMemo(() => items.map((it) => it.cardId), [items]));
  const groups = useMemo(() => (catalog ? group(items, catalog) : []), [catalog, items]);
  // Built most copies first; Sort can reorder.
  const shown = useMemo(() => {
    const found = normName(q) ? groups.filter((g) => cardMatches(q, g.name, g.type)) : groups;
    return catalog ? applySort(found, sort, (g) => sortKeyOf(catalog, g.name, g.oracle, g.cover)) : found;
  }, [groups, q, sort, catalog]);
  const copies = items.reduce((s, it) => s + it.qty, 0);
  /** Group by: the sort kept inside each group. */
  const sections = catalog ? groupSections(shown, grouping, (g) => keysOf(catalog, g.oracle)) : [];
  const sectionTitle = (sec: { key: string; items: CardGroup[] }) => `${groupLabel(grouping, sec.key)} · ${sec.items.reduce((n, g) => n + g.qty, 0)}`;
  /** Grid and stacks: one card per Oracle card, or with every printing expanded, one per printing and finish. */
  const tiles = (shown: CardGroup[]): StackCardItem[] => shown.flatMap((g) => {
    const hero = !unsorted && isHero(g.key, { kind: "binder", id }, heroes);
    const onClick = () => g.oracle >= 0 && onCard(g.key);
    if (!printings.all || g.parts.length < 2) return [{ key: g.key, p: g.cover, name: g.name, qty: g.qty, finish: g.coverFinish, hero, onClick }];
    return g.parts.map((pt) => ({ key: `${g.key}|${pt.cardId}|${pt.finish}`, p: pt.p, name: g.name, qty: pt.qty, finish: pt.finish, hero, onClick }));
  });
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
    <LibScreen width={layout === "list" ? "column" : "wide"}>
      <Bar title={unsorted ? "Unsorted" : binder?.name ?? "Binder"} onBack={onBack}
           subtitle={[`${copies.toLocaleString()} cards`, binder?.for_trade ? "For trade" : null, usdText(value(items))].filter(Boolean).join(" · ")}
           right={<span className="flex gap-4">
             <ViewButton layout={layout} onChange={setLayout} screen="binder" printings={printings} onPrintings={setPrintings}
                         grouping={grouping} onGrouping={setGrouping} sort={sort} onSort={setSort} sorts="binder" />
             {binder && <button type="button" onClick={() => setMenu(true)} className="t1-label hover:text-t1-text px-2 py-1 -my-1">Edit</button>}
           </span>} />
      {!unsorted && !binder && <Notice tone="info">This binder was deleted.</Notice>}
      {(error || fail || b.error) && <Notice tone="error">{error ?? fail ?? b.error}</Notice>}
      <Field label="Search this binder" value={q} onChange={setQ} placeholder="Name or type" />
      {!catalog && !error && <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>}
      <div ref={boxRef} className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {binder && <WhoSeesRow kind="binder" id={binder.id} name={binder.name} forTrade={binder.for_trade} />}
        {binder && <ShareRow target={{ part: "binder", id: binder.id, name: binder.name, for_trade: binder.for_trade }} from="binder" />}
        {(unsorted || binder) && (
          <Row title="Add cards" detail={unsorted ? "New copies, or copies out of a binder" : "Move in copies you own, or add new ones"}
               onClick={() => setAdding(true)} />
        )}
        {catalog && !!groups.length && !shown.length && <Row title="No cards match" />}
        {catalog && !groups.length && (
          <Notice tone="info">{unsorted ? "Every copy is in a binder." : "No cards here yet. Add cards moves in copies you own or adds new ones; trades and imports can fill it too."}</Notice>
        )}
        {catalog && layout === "grid" && (() => {
          const cols = Math.max(3, Math.floor(boxWidth / 180));
          const tile = Math.floor((boxWidth - (cols - 1)) / cols);
          return sections.map((sec) => (
            <div key={sec.key} className="flex flex-col gap-px shrink-0">
              {grouping !== "none" && <Section title={sectionTitle(sec)} />}
              <div className="grid gap-px shrink-0" style={{ gridTemplateColumns: `repeat(${cols}, ${tile}px)` }}>
                {tiles(sec.items).map((t) => <CardTile key={t.key} c={catalog} p={t.p} name={t.name} qty={t.qty} width={tile} finish={t.finish} hero={t.hero} onClick={t.onClick} />)}
              </div>
            </div>
          ));
        })()}
        {/* Grouped: one stack per group; None: stacks of ten. */}
        {catalog && layout === "stacks" && (
          <StackRows c={catalog} boxWidth={boxWidth} stacks={grouping !== "none"
            ? sections.map((sec) => ({ key: `st|${sec.key}|${printings.all}`, title: sectionTitle(sec), cards: tiles(sec.items) }))
            : (() => {
              const all = tiles(shown);
              return Array.from({ length: Math.ceil(all.length / 10) }, (_, i) => ({ key: `st|${printings.all}|${i}`, cards: all.slice(i * 10, i * 10 + 10) }));
            })()} />
        )}
        {catalog && layout === "list" && sections.map((sec) => (
          <div key={sec.key} className="flex flex-col gap-px shrink-0">
            {grouping !== "none" && <Section title={sectionTitle(sec)} />}
            {sec.items.map((g) => {
              const hero = !unsorted && isHero(g.key, { kind: "binder", id }, heroes);
              const open = isOpen(printings, g.key);
              return (
                <div key={g.key} className="flex flex-col gap-px">
                  <div className="h-[60px] shrink-0">
                    <CardGroupRow open={open} parts={g.parts.length} hero={hero}
                                  onToggle={() => { setPrintings(toggleOne(printings, g.key)); capture("printings_toggled", { expanded: !open, all: false, screen: "binder" }); }}>
                      <CardRow c={catalog} p={g.cover} title={g.name} value={g.qty} finish={g.coverFinish} hero={hero}
                               detail={`${g.printings} printing${g.printings === 1 ? "" : "s"} · ${g.type}`}
                               onClick={() => g.oracle >= 0 && onCard(g.key)} />
                    </CardGroupRow>
                  </div>
                  {open && g.parts.length > 1 && g.parts.map((pt) => (
                    <div key={`${pt.cardId}|${pt.finish}`} className="h-[60px] shrink-0">
                      <CardRow c={catalog} p={pt.p} indent finish={pt.finish} value={pt.qty}
                               title={[pt.p == null ? null : `${catalog.pSet[pt.p].toUpperCase()} #${catalog.pCn[pt.p]}`, pt.finish === "nonfoil" ? null : FINISH_LABEL[pt.finish]].filter(Boolean).join(" · ")}
                               detail={usdText(usdPrice(pt.cardId, pt.finish, pt.condition)) || undefined}
                               onClick={() => g.oracle >= 0 && onCard(g.key)} />
                    </div>
                  ))}
                </div>
              );
            })}
          </div>
        ))}
      </div>
      {menu && binder && <Menu title={binder.name} items={menuItems} onClose={() => setMenu(false)} />}
      {adding && catalog && <BinderAdd catalog={catalog} binderId={unsorted ? null : id} items={col.items} onClose={() => setAdding(false)} />}
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
 * Binder → Add cards: search the catalog; Move in takes one copy you own from elsewhere (`moveInSource`), + New adds a
 * new copy of the card's original printing straight into the binder (`binderId` null = Unsorted).
 */
function BinderAdd({ catalog, binderId, items, onClose }: { catalog: Catalog; binderId: string | null; items: Map<string, Item>; onClose: () => void }) {
  const [q, setQ] = useState("");
  const [last, setLast] = useState<{ batch: string; label: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [fail, setFail] = useState<string | null>(null);
  const target = binderById(binderId)?.name ?? "Unsorted";
  const condition = (() => { try { return localStorage.getItem("table1.library.addCondition") ?? "NM"; } catch { return "NM"; } })() as Item["condition"];
  const [addLang, setAddLangState] = useState(storedAddLang);
  const setAddLang = (code: string) => { setAddLangState(code); storeAddLang(code); };
  const found = useCardSearch(catalog, q, 30);
  const hits = q.trim() ? found?.result.hits ?? [] : [];
  const byOracle = useMemo(() => {
    const m = new Map<number, Item[]>();
    for (const it of items.values()) {
      const p = catalog.printingIndex.get(it.cardId);
      if (p == null) continue;
      const oi = catalog.pOracle[p];
      m.set(oi, [...(m.get(oi) ?? []), it]);
    }
    return m;
  }, [catalog, items]);
  const run = async (label: string, work: () => Promise<string>) => {
    setBusy(true);
    setFail(null);
    try {
      const batch = await work();
      setLast(batch ? { batch, label } : null);
    } catch (e) {
      setFail(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <Modal title={`Add to ${target}`} onClose={onClose}>
      {fail && <Notice tone="error">{fail}</Notice>}
      {last && (
        <div className="bg-t1-surface px-4 py-3 flex items-center gap-3">
          <span className="t1-label flex-1">{last.label}</span>
          <button type="button" className="t1-label hover:text-t1-text" disabled={busy}
                  onClick={() => void run("", async () => { await undoBatch(last.batch); return ""; })}>Undo</button>
        </div>
      )}
      <CardSearchBar label="Card" value={q} onChange={setQ} placeholder="Name, or Scryfall syntax" autoFocus />
      <CardSearchStatus query={q} found={found} />
      <NewCopiesLanguageRow lang={addLang} onChange={setAddLang} />
      {!q && <p className="t1-label">Move in takes a copy you own from Unsorted or another binder. + New adds a new copy ({condition}, original printing) to your collection, in {target}.</p>}
      <div className="max-h-[50vh] overflow-y-auto flex flex-col gap-px">
        {hits.map((oi) => {
          const its = byOracle.get(oi) ?? [];
          const places = placesOf(its);
          const here = places.filter((pl) => (pl.from?.id ?? null) === binderId).reduce((n, pl) => n + pl.qty, 0);
          const where = new Map<string, number>();
          for (const pl of places) if ((pl.from?.id ?? null) !== binderId) where.set(pl.from?.name ?? "Unsorted", (where.get(pl.from?.name ?? "Unsorted") ?? 0) + pl.qty);
          const detail = !its.length ? "Not in your collection"
            : [here ? `${here} here` : null, ...[...where].sort((a, b) => a[0].localeCompare(b[0])).map(([n, v]) => `${n} ${v}`)].filter(Boolean).join(" · ");
          const source = moveInSource(places, binderId);
          const p = found?.result.covers.get(oi) ?? coverPrinting(catalog, oi);
          const finish = (["nonfoil", "foil", "etched"] as Finish[]).find((f) => catalog.pFinishes[p]?.includes(f[0])) ?? "nonfoil";
          const lang = langForNew(catalog.pLang[p], addLang);
          return (
            <div key={oi} className="flex items-stretch gap-px h-[60px]">
              <div className="flex-1 min-w-0"><CardRow c={catalog} p={p} title={catalog.oName[oi]} detail={detail} /></div>
              {source && (
                <button type="button" disabled={busy} className="px-3 bg-t1-surface-hover t1-label hover:text-t1-text"
                        onClick={() => void run(`Moved 1 ${catalog.oName[oi]} from ${binderById(source.from)?.name ?? "Unsorted"}`,
                                                () => moveCopies([{ item: source.item, from: source.from, to: binderId, qty: 1 }]))}>Move in</button>
              )}
              <button type="button" disabled={busy} className="px-3 bg-t1-surface-hover t1-label hover:text-t1-text"
                      onClick={() => void run(`Added 1 ${catalog.oName[oi]} · ${condition}${lang === "en" ? "" : ` · ${lang.toUpperCase()}`}`,
                                              async () => (await applyOps([{ card_id: catalog.pId[p], finish, condition, lang, delta: 1, binder_id: binderId }])).batch_id)}>+ New</button>
            </div>
          );
        })}
      </div>
    </Modal>
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

/** The card id of the printing a want's row shows for any printing (its cover). */
function coverOf(c: Catalog, oracleId: string): string | null {
  const oi = oracleIndexById(c, oracleId);
  return oi < 0 ? null : c.pId[coverPrinting(c, oi)];
}

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
  const [q, setQ] = useState("");
  const [repointing, setRepointing] = useState<Want | null>(null);
  useSearchUsed(q, "wants");
  const wants = useMemo(() => liveWants(), [b.version]);
  const missing = useMemo(() => {
    const owned = new Map<string, number>();
    for (const it of col.items.values()) owned.set(`${it.cardId}|${it.finish}`, (owned.get(`${it.cardId}|${it.finish}`) ?? 0) + it.qty);
    return missingLines(lists.lists, owned, basicCardIds(catalog), cardOfCatalog(catalog));
  }, [lists.lists, col.version, catalog]);
  const priceVersion = usePrices(useMemo(() => wants.flatMap((w) => {
    const p = w.cardId ?? (catalog ? coverOf(catalog, w.oracleId) : null);
    return p ? [p] : [];
  }), [wants, catalog]));
  const wp = useWantPrices();
  const [tcgplayer, setTcgplayer] = useState(false);
  const [parts, setParts] = useState<CartEntry[] | null>(null);
  useEffect(() => {
    if (session) void tcgplayerEnabled().then(setTcgplayer);
  }, [session]);
  // Buy on TCGplayer (contract/tcgplayer-cart-2026-10-26.md): one link opens in a new tab, several are a menu.
  const buy = (items: CartItem[], from: "wants" | "missing") => {
    tcgplayerCart(items).then((a) => {
      capture("tcgplayer_cart_opened", { from, lines: a.lines, parts: a.urls.length, products: a.products?.length ?? 0 });
      const direct = cartDirect(a);
      const menu = cartMenu(a);
      if (direct) window.open(direct, "_blank", "noopener");
      else if (!menu.length) setFail("Nothing to buy");
      else setParts(menu);
    }, (e) => setFail(errorMessage(e)));
  };
  // contract/want-prices-2026-10-26.md: now, a week back and the price alerts switch. The demo prices from the session.
  useEffect(() => {
    if (session) void loadWantPrices(wants, (w) => {
      const p = w.cardId ?? (catalog ? coverOf(catalog, w.oracleId) : null);
      return p ? usdPrice(p, w.finish ?? "nonfoil") : null;
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session, b.version, priceVersion]);
  if (!ready) return <Screen><div className="flex-1" /></Screen>;
  if (!session) return <SignedOut title="Wants" onBack={onBack} />;
  const wanted = wants.reduce((n, w) => n + w.qty, 0);
  const short = missing.reduce((n, m) => n + m.short, 0);
  const nameOf = (oi: number) => (catalog && oi >= 0 ? catalog.oName[oi] : "");
  const typeOf = (oi: number) => (catalog && oi >= 0 ? catalog.oType[oi] : "");
  const shownWants = !catalog || !normName(q) ? wants : wants.filter((w) => {
    const oi = oracleIndexById(catalog, w.oracleId);
    return cardMatches(q, nameOf(oi), typeOf(oi));
  });
  const shownMissing = !catalog || !normName(q) ? missing : missing.filter((m) => {
    const p = catalog.printingIndex.get(m.cardId);
    const oi = p == null ? -1 : catalog.pOracle[p];
    return cardMatches(q, nameOf(oi), typeOf(oi));
  });
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
    const now = wantPrice(w)?.now ?? (w.cardId ? usdPrice(w.cardId, w.finish ?? "nonfoil") : null);
    return wantDetail(which, w.maxUsd, now, w.cardId == null);
  };
  const editItems = (w: Want): MenuItem[] => {
    const base = { oracle_id: w.oracleId, card_id: w.cardId, finish: w.finish };
    const p = printingOf(w);
    return [
      { title: "One more", onClick: () => void run(applyWants([{ ...base, delta: 1 }], "want_changed")) },
      ...(w.qty > 1 ? [{ title: "One fewer", onClick: () => void run(applyWants([{ ...base, delta: -1 }], "want_changed")) }] : []),
      { title: "Max price", detail: w.maxUsd != null ? `$${w.maxUsd}` : "None", onClick: () => setPricing(w) },
      { title: "Change printing", detail: w.cardId == null ? "Any printing" : p != null && catalog ? `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}` : undefined,
        onClick: () => setRepointing(w) },
      { title: "Open card", onClick: () => onCard(w.oracleId) },
      { title: "Remove", onClick: () => void run(applyWants([{ ...base, qty: 0 }], "want_removed")) },
    ];
  };
  return (
    <LibScreen>
      <Bar title="Wants" subtitle={`${wanted} wanted · ${short} missing`} onBack={onBack} />
      {(error || fail || b.error) && <Notice tone="error">{error ?? fail ?? b.error}</Notice>}
      {(wants.length > 0 || missing.length > 0) && <Field label="Search wants" value={q} onChange={setQ} placeholder="Name or type" />}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <Row title="Add a want" detail="Any printing, or one in particular" onClick={() => setAdding(true)} />
        {wp.alerts != null && (
          <SwitchRow label="Price alerts" detail="A push when a want gets 15% cheaper or reaches your max" on={wp.alerts}
                     onChange={(on) => void setWantAlerts(on)} />
        )}
        {tcgplayer && wants.length > 0 && !q && (
          <Row title="Buy on TCGplayer" detail={`${wanted} cards into a cart, then Optimize`}
               onClick={() => buy(wants.map((w) => ({ oracle_id: w.oracleId, card_id: w.cardId, qty: w.qty })), "wants")} />
        )}
        {wants.length > 0 && !q && <ShareRow target={{ part: "wants", id: null, name: null }} from="wants" />}
        <Section title="Wanted" count={shownWants.length} />
        {!shownWants.length && !!q && <Row title="No wants match" />}
        {!wants.length && !q && <Notice tone="info">Cards you're after. Gets in a trade that match are marked, and confirming takes them off.</Notice>}
        {catalog && shownWants.map((w) => {
          const p = printingOf(w);
          const oi = oracleIndexById(catalog, w.oracleId);
          const t = wantTrend(w);
          return (
            <div key={`${w.oracleId}|${w.cardId}|${w.finish}`} style={{ height: 60 }}>
              <CardRow c={catalog} p={p} title={oi >= 0 ? catalog.oName[oi] : "Card not in local data yet"} detail={detail(w, p)}
                       note={t?.text} noteAccent={t?.dir === "down"} value={w.qty} onClick={() => setEditing(w)} />
            </div>
          );
        })}
        <Section title="Missing from decks and cubes" count={normName(q) ? shownMissing.length : short} />
        {tcgplayer && missing.length > 0 && !q && (
          <Row title="Buy missing on TCGplayer" detail={`${short} cards into a cart, then Optimize`}
               onClick={() => buy(missing.map((m) => ({ card_id: m.cardId, qty: m.short })), "missing")} />
        )}
        {catalog && !shownMissing.length && !!normName(q) && <Row title="Nothing missing matches" />}
        {catalog && !missing.length && <Notice tone="info">Your decks and cubes have every card they need.</Notice>}
        {catalog && (all ? shownMissing : shownMissing.slice(0, 60)).map((m) => {
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
                                                           { any_printing: true, finish: false, has_max: false, from: "missing" }))}>Want</button>
              )}
            </div>
          );
        })}
        {!all && shownMissing.length > 60 && <Row title={`Show all ${shownMissing.length}`} onClick={() => setAll(true)} />}
      </div>
      {adding && catalog && <WantPicker catalog={catalog} onClose={() => setAdding(false)} onFail={setFail} />}
      {editing && catalog && (
        <Menu title={catalog.oName[oracleIndexById(catalog, editing.oracleId)] ?? "Want"} items={editItems(editing)} onClose={() => setEditing(null)} />
      )}
      {pricing && <WantPrice want={pricing} onClose={() => setPricing(null)} onFail={setFail} />}
      {parts && (
        <Menu title="Buy on TCGplayer" onClose={() => setParts(null)}
              items={parts.map((e) => ({ title: e.title, detail: e.detail, onClick: () => { window.open(e.url, "_blank", "noopener"); } }))} />
      )}
      {repointing && catalog && (
        <WantPrinting catalog={catalog} oi={oracleIndexById(catalog, repointing.oracleId)} replacing={repointing}
                      onClose={() => setRepointing(null)} onFail={setFail} />
      )}
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

/** Search for a card to want: Want adds any printing; tapping the card picks one printing or finish. */
function WantPicker({ catalog, onClose, onFail }: { catalog: Catalog; onClose: () => void; onFail: (e: string) => void }) {
  const [q, setQ] = useState("");
  const [added, setAdded] = useState<string | null>(null);
  const [picking, setPicking] = useState<number | null>(null);
  const found = useCardSearch(catalog, q, 30);
  const hits = q.trim() ? found?.result.hits ?? [] : [];
  if (picking != null) {
    return <WantPrinting catalog={catalog} oi={picking} from="search" onFail={onFail}
                         onClose={(text) => { setPicking(null); if (text) setAdded(text); }} />;
  }
  return (
    <Dialog title="Add a want" cancelLabel="Done" confirmLabel="Done" onCancel={onClose} onConfirm={onClose}>
      <CardSearchBar label="Card" value={q} onChange={setQ} placeholder="Lightning Bolt, or Scryfall syntax" autoFocus />
      <CardSearchStatus query={q} found={found} />
      {added ? <p className="t1-label">{added}</p> : !q && <p className="t1-label">Want adds any printing. Pick a card to want one printing or finish.</p>}
      <div className="max-h-[50vh] overflow-y-auto flex flex-col gap-px">
        {hits.map((o) => (
          <div key={o} className="flex items-stretch gap-px" style={{ height: 60 }}>
            <div className="flex-1 min-w-0">
              <CardRow c={catalog} p={found?.result.covers.get(o) ?? coverPrinting(catalog, o)} title={catalog.oName[o]} detail={catalog.oType[o]} value="Printing"
                       onClick={() => setPicking(o)} />
            </div>
            <button type="button" className="bg-t1-surface-hover px-4 t1-label !text-t1-text"
                    onClick={() => void applyWants([{ oracle_id: catalog.oId[o], delta: 1 }], "want_added",
                                                   { any_printing: true, finish: false, has_max: false, from: "search" })
                      .then(() => setAdded(`Wanted ${catalog.oName[o]}`), (e) => onFail(errorMessage(e)))}>Want</button>
          </div>
        ))}
      </div>
    </Dialog>
  );
}

/**
 * Which printing of a card to want: any printing, one printing in any finish (pick the printing), or one printing in
 * one finish (its finish buttons). Adds one copy, or with `replacing` points that want at the pick, keeping its count
 * and max price.
 */
function WantPrinting({ catalog, oi, replacing, from = "search", onClose, onFail }: {
  catalog: Catalog; oi: number; replacing?: Want; from?: string; onClose: (text?: string) => void; onFail: (e: string) => void;
}) {
  const [q, setQ] = useState("");
  const [busy, setBusy] = useState(false);
  const orig = catalog.oOriginal[oi];
  const printings = useMemo(() => Array.from({ length: catalog.pCount[oi] }, (_, i) => catalog.pFirst[oi] + i)
    .sort((a, b) => Number(b === orig) - Number(a === orig)), [catalog, oi]);
  usePrices(useMemo(() => printings.map((p) => catalog.pId[p]), [printings]));
  const shown = q ? printings.filter((p) => printingMatches(q, catalog.pSet[p], catalog.pCn[p], catalog.pReleased[p] ?? "")) : printings;
  const label = (p: number) => `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`;
  const pick = async (p: number | null, finish: Finish | null) => {
    const cardId = p == null ? null : catalog.pId[p];
    const text = p == null ? catalog.oName[oi] : [label(p), finish ? FINISH_LABEL[finish] : null].filter(Boolean).join(" ");
    let ops, event, props: Record<string, string | number | boolean> = { any_printing: p == null, finish: finish != null };
    if (replacing) {
      ops = repointWant(replacing, cardId, finish);
      if (!ops) return onClose();
      event = "want_changed";
      props = { ...props, printing: true };
    } else {
      ops = [{ oracle_id: catalog.oId[oi], card_id: cardId, finish, delta: 1 }];
      event = "want_added";
      props = { ...props, has_max: false, from };
    }
    setBusy(true);
    try {
      await applyWants(ops, event, props);
      onClose(replacing ? `Now wanting ${text}` : `Wanted 1 ${text}`);
    } catch (e) {
      onFail(errorMessage(e));
      onClose();
    } finally {
      setBusy(false);
    }
  };
  const anyNow = replacing != null && replacing.cardId == null;
  return (
    <Modal title={`${replacing ? "Change printing" : "Want which printing"} · ${catalog.oName[oi]}`} onClose={() => onClose()}>
      {printings.length > 8 && <Field label="Set, number or year" value={q} onChange={setQ} autoFocus />}
      <div className="max-h-[60vh] overflow-y-auto flex flex-col gap-px">
        <Row title="Any printing" detail="A get of any printing meets it" value={anyNow ? "Current" : undefined}
             onClick={anyNow || busy ? undefined : () => void pick(null, null)} />
        <Section title="One printing" count={shown.length} />
        {!shown.length && <Row title="No printings match" />}
        {shown.map((p) => {
          const finishes = (["nonfoil", "foil", "etched"] as Finish[]).filter((f) => catalog.pFinishes[p].includes(f[0]));
          const samePrinting = replacing?.cardId === catalog.pId[p];
          const price = usdPrice(catalog.pId[p], finishes[0] ?? "nonfoil");
          const detail = [samePrinting && replacing?.finish == null ? "Current" : null, RARITY_NAME[catalog.pRarity[p]], catalog.pReleased[p]?.slice(0, 4),
                          p === orig ? "Original" : null, catalog.pLang[p] !== "en" ? catalog.pLang[p].toUpperCase() : null,
                          price != null ? usdText(price) : null].filter(Boolean).join(" · ");
          return (
            <div key={p} className="flex items-stretch gap-px h-[60px]">
              <div className="flex-1 min-w-0">
                <CardRow c={catalog} p={p} title={label(p)} detail={detail}
                         onClick={busy || (samePrinting && replacing?.finish == null) ? undefined : () => void pick(p, null)} />
              </div>
              {finishes.length > 1 && finishes.map((f) => {
                const same = samePrinting && replacing?.finish === f;
                return (
                  <button key={f} type="button" disabled={same || busy}
                          className="px-2 bg-t1-surface-hover t1-label hover:text-t1-text disabled:text-t1-disabled"
                          onClick={() => void pick(p, f)}>{same ? "Current" : FINISH_LABEL[f]}</button>
                );
              })}
            </div>
          );
        })}
      </div>
    </Modal>
  );
}

const FINISH_LABEL: Record<Finish, string> = { nonfoil: "Non-foil", foil: "Foil", etched: "Etched" };

/** "Add to wants" on card detail: any printing, the one shown, or a printing picked from all of them. */
export function WantCardRow({ catalog, oi, shown, onAdded }: { catalog: Catalog; oi: number; shown: number | null; onAdded: (t: string) => void }) {
  const { userId } = useLibrarySession();
  const b = useBinders(userId);
  const [open, setOpen] = useState(false);
  const [picking, setPicking] = useState(false);
  const mine = useMemo(() => liveWants().filter((w) => w.oracleId === catalog.oId[oi]), [b.version, catalog, oi]);
  const n = mine.reduce((s, w) => s + w.qty, 0);
  const want = (p: number | null) =>
    void applyWants([{ oracle_id: catalog.oId[oi], card_id: p == null ? null : catalog.pId[p], delta: 1 }], "want_added",
                    { any_printing: p == null, finish: false, has_max: false, from: "card" })
      .then(() => onAdded(`Wanted 1 ${p == null ? catalog.oName[oi] : `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`}`));
  return (
    <>
      <Row title={n ? `Wanted · ${n}` : "Add to wants"} detail={n ? "Want one more" : "Trades marks it when you get one"} onClick={() => setOpen(true)} />
      {open && (
        <Menu title={`Want ${catalog.oName[oi]}`} onClose={() => setOpen(false)} items={[
          { title: "Any printing", onClick: () => want(null) },
          ...(shown != null ? [{ title: `Only ${catalog.pSet[shown].toUpperCase()} #${catalog.pCn[shown]}`, onClick: () => want(shown) }] : []),
          { title: "Pick a printing…", detail: "One printing, or one finish", onClick: () => setPicking(true) },
        ]} />
      )}
      {picking && <WantPrinting catalog={catalog} oi={oi} from="card" onFail={onAdded} onClose={(t) => { setPicking(false); if (t) onAdded(t); }} />}
    </>
  );
}
