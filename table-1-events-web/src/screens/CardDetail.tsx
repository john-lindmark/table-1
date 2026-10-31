import { useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { BackArrow, Dialog, Menu, Notice, Row, Section, Segmented, type MenuItem } from "../components/kit";
import { ZoomImage } from "../components/ZoomImage";
import { capture } from "../lib/telemetry";
import { errorMessage } from "../lib/api";
import { RARITY_NAME, basicCardIds, cardImageUrl, formatName, oracleIndexById, type Catalog } from "../lib/catalog";
import { applyOps, fetchHistory, undoBatch, useCollection, DEMO_USER, type CollectionOp, type Condition, type Finish, type HistoryEntry } from "../lib/collection";
import { conditionPriceText, markConverted, usdConverted, usdPrice, usdText, usePrices } from "../lib/prices";
import { applyWants, binderById, forTrade, placementText, useBinders } from "../lib/binders";
import { printingPlaces } from "../lib/changePrinting";
import { ZONE_FORMATS } from "../lib/commandZone";
import { BOARD_ORDER, boardTitle, entriesOf, finishOf, langOf, needsOf, sectionsFor, editList, useLists, type Board, type CardList, type ListOp } from "../lib/lists";
import { saveTrade, useTrades, type TradeLine } from "../lib/trades";
import { LANGUAGES, langForNew, languageName, storedAddLang } from "../lib/languages";
import { cardAddDetail, copiesOf, listAddOps, toCollectionOps, type AddOp } from "../lib/listToCollection";
import { isHero, scopeOf, toggleHero, HERO_LIMIT } from "../lib/heroes";
import { loadDemoLists } from "../lib/libraryDemo";
import {
  addLines, editOps, factsOf, finishesOf, freshVersion, isNewEdition, mainVersion, newEdition, orderedVersions, repoint, shared, showsFinish,
  stepOp, versionId, versionKey,
  type CardAttribute, type CardVersion, type PrintingFacts,
} from "../lib/cardDetail";
import { CONDITIONS, CardArt, LibScreen, SignedOut, useAddCondition, useCatalog, useLibraryHeroes, useLibrarySession } from "./Library";
import { MoveCopies, UNSORTED, WantCardRow } from "./Binders";
import { autoMatch, cardOfCatalog, matchDetail, matchOps, matchSections, ownedVersions, tapPick, type Move, type Need, type Pick, type Version } from "../lib/ownedByCard";

/* Card detail (contract/card-detail-2026-10-23.md, Figma 318:10810): the card, one row of attributes and one bottom
   bar, in the scope it was opened from (the collection, a deck or cube, a binder, or search). The attribute row
   changes the copies in view, the stepper counts them, and Add to puts the version on screen anywhere else. The list
   icon flips to the info view. Same screen as iOS CardDetailViews.swift. */

/** The scope card detail was opened in (history state, so no id lands in the URL); none is the collection. */
export interface CardContext { list?: string; binder?: string; search?: boolean }

interface Undo { label: string; run: () => Promise<unknown> }

const FINISH_LABEL: Record<Finish, string> = { nonfoil: "Non-foil", foil: "Foil", etched: "Etched" };
const finishCode = (f: Finish) => (f === "foil" ? "F" : f === "etched" ? "E" : "NF");
const sectionCode = (b: Board) => (b === "side" ? "Side" : b === "maybe" ? "Maybe" : b === "commander" ? "Cmdr" : "Main");
const ASPECT = 488 / 680;
/** `selected` when the new edition (long press on +) is the picked tile. */
const EDITION = "new-edition";

/** The size of an element, kept up to date. A callback ref, so it starts measuring whenever the element mounts. */
function useSize<T extends HTMLElement>(): [(el: T | null) => void, { w: number; h: number }] {
  const [el, setEl] = useState<T | null>(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  useLayoutEffect(() => {
    if (!el) return;
    const ro = new ResizeObserver(() => setSize({ w: el.clientWidth, h: el.clientHeight }));
    ro.observe(el);
    setSize({ w: el.clientWidth, h: el.clientHeight });
    return () => ro.disconnect();
  }, [el]);
  return [setEl, size];
}

export function CardDetail({ oracleId, onBack, context, onList }: {
  oracleId: string; onBack: () => void; context?: CardContext; onList?: (id: string) => void;
}) {
  const { session, ready, userId } = useLibrarySession();
  const col = useCollection(userId);
  const lists = useLists(userId, userId === DEMO_USER ? loadDemoLists : undefined);
  const binders = useBinders(userId);
  const { catalog, error: catError } = useCatalog();
  const [addCondition] = useAddCondition();
  const addLang = storedAddLang();
  const [selected, setSelected] = useState<string | null>(null);
  const [draft, setDraft] = useState<CardVersion | null>(null);
  /** A new edition from a long press on +: shown dimmed and selected, written once a pick makes it different. */
  const [edition, setEdition] = useState<CardVersion | null>(null);
  const [info, setInfo] = useState(false);
  const [back, setBack] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [last, setLast] = useState<Undo | null>(null);
  const [picker, setPicker] = useState<CardAttribute | null>(null);
  const [menu, setMenu] = useState<{ title: string; items: MenuItem[] } | null>(null);
  const [confirm, setConfirm] = useState<{ title: string; run: () => void } | null>(null);
  const [addTo, setAddTo] = useState<CardVersion[] | null>(null);
  const [zoom, setZoom] = useState<number | null>(null);
  const [matching, setMatching] = useState(false);
  const [areaRef, area] = useSize<HTMLDivElement>();

  const listId = context?.list;
  const binderId = context?.binder;
  const isSearch = !!context?.search;
  const scopeName = listId ? "list" : binderId ? "binder" : isSearch ? "search" : "collection";
  const list = listId ? lists.lists.find((l) => l.id === listId) : undefined;

  const oi = catalog ? oracleIndexById(catalog, oracleId) : -1;
  const printings = useMemo(() => {
    if (!catalog || oi < 0) return [] as number[];
    return Array.from({ length: catalog.pCount[oi] }, (_, i) => catalog.pFirst[oi] + i);
  }, [catalog, oi]);
  const facts = useMemo(() => (catalog ? printings.map((p) => factsOf(catalog, p)) : []), [catalog, printings]);
  const factsById = useMemo(() => new Map(facts.map((f) => [f.cardId, f])), [facts]);
  const indexById = useMemo(() => new Map(printings.map((p) => [catalog!.pId[p], p])), [catalog, printings]);
  const oldest = useMemo(() => [...printings].sort((a, b) => {
    const fa = factsById.get(catalog!.pId[a])!, fb = factsById.get(catalog!.pId[b])!;
    return fa.released !== fb.released ? (fa.released < fb.released ? -1 : 1) : fb.ord - fa.ord;
  }), [printings, factsById, catalog]);
  usePrices(useMemo(() => facts.map((f) => f.cardId), [facts]));

  void binders.version;
  const versions = useMemo(() => {
    const ids = new Set(facts.map((f) => f.cardId));
    let raw: CardVersion[] = [];
    if (listId) {
      raw = list ? entriesOf(list).filter((e) => ids.has(e.cardId))
        .map((e) => ({ cardId: e.cardId, finish: finishOf(e), condition: "NM" as Condition, lang: langOf(e), board: e.board, qty: e.qty })) : [];
    } else if (binderId) {
      raw = [...col.items.values()].filter((it) => ids.has(it.cardId)).flatMap((it) => {
        const q = printingPlaces(it).find((pl) => pl.place === binderId)?.qty ?? 0;
        return q > 0 ? [{ cardId: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, qty: q }] : [];
      });
    } else if (!isSearch) {
      raw = [...col.items.values()].filter((it) => ids.has(it.cardId))
        .map((it) => ({ cardId: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, qty: it.qty }));
    }
    return orderedVersions(raw, facts);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [facts, col.version, binders.version, list, listId, binderId, isSearch]);

  useEffect(() => {
    if (selected && selected !== EDITION && !versions.some((v) => versionId(v) === selected)) setSelected(null);
  }, [versions, selected]);

  if (!ready) return <LibScreen><div className="flex-1" /></LibScreen>;
  if (!session) return <SignedOut title="Card" />;
  if (!catalog || oi < 0) {
    return (
      <LibScreen>
        <CardBar name="Card" onBack={onBack} />
        {catError ? <Notice tone="error">{catError}</Notice>
          : catalog ? <Notice tone="error">That card isn't in the card data.</Notice>
          : <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>}
      </LibScreen>
    );
  }

  const fresh = freshVersion(facts, addCondition, addLang, listId ? "main" : undefined);
  const chosen = (selected === EDITION ? edition : versions.find((v) => versionId(v) === selected)) ?? null;
  const inView = chosen ? [chosen] : versions;
  const current = chosen ?? mainVersion(versions) ?? draft ?? fresh;
  if (!current) return <LibScreen><CardBar name={catalog.oName[oi]} onBack={onBack} /></LibScreen>;
  const shown = inView.length ? inView : [current];
  const name = catalog.oName[oi];
  const setLabel = (cardId: string) => { const p = indexById.get(cardId); return p == null ? name : `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`; };

  const report = (label: string, undo: Undo | null) => {
    setError(null);
    if (undo) { setLast(undo); setNotice(null); } else { setLast(null); setNotice(label); }
  };

  const write = async (ops: CollectionOp[], label: string, then?: () => void) => {
    setBusy(true);
    setError(null);
    try {
      const res = await applyOps(ops);
      then?.();
      report(label, { label, run: () => undoBatch(res.batch_id) });
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const listEdit = async (ops: ListOp[], reverse: ListOp[], label: string, then?: () => void) => {
    if (!listId) return;
    setError(null);
    try {
      await editList(listId, ops);
      then?.();
      report(label, { label, run: () => editList(listId, reverse) });
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  const valueName = (a: CardAttribute, value: string) =>
    a === "set" ? setLabel(value) : a === "language" ? languageName(value) : a === "finish" ? FINISH_LABEL[value as Finish]
      : a === "section" ? (list ? boardTitle(list.kind, value as Board) : value) : value;

  /** A pick: changes the copies in view (asking first when more than one would change), or with nothing in view, the
   *  version on screen. */
  const pick = (a: CardAttribute, value: string) => {
    setPicker(null);
    const printing = a === "set" ? factsById.get(value) : undefined;
    // The new edition: written as soon as it is a version the scope doesn't hold, until then just redrawn.
    if (selected === EDITION && edition) {
      const to = repoint(edition, a, value, printing);
      if (isNewEdition(to, versions)) addEdition(to, a); else setEdition(to);
      return;
    }
    if (!versions.length) {
      setDraft(repoint(current, a, value, printing));
      return;
    }
    const targets = (chosen ? [chosen] : versions).filter((v) => versionId(repoint(v, a, value, printing)) !== versionId(v)
      || versionKey(repoint(v, a, value, printing)) !== versionKey(v));
    if (!targets.length) return;
    const total = targets.reduce((n, v) => n + v.qty, 0);
    const what = valueName(a, value);
    const run = (one: boolean) => apply(a, value, printing, targets, one, what);
    if (targets.length > 1) setConfirm({ title: `Change all ${total} to ${what}?`, run: () => run(false) });
    else if (total > 1) setMenu({ title: `Change to ${what}`, items: [
      { title: "One copy", onClick: () => run(true) },
      { title: `All ${total} copies`, onClick: () => run(false) },
    ] });
    else run(false);
  };

  const apply = (a: CardAttribute, value: string, printing: PrintingFacts | undefined, targets: CardVersion[], one: boolean, what: string) => {
    const copies = one ? 1 : targets.reduce((n, v) => n + v.qty, 0);
    const props = { attribute: a, scope: scopeName, copies, mix: targets.length > 1, selected: !!chosen };
    const label = `Changed ${copies} to ${what}`;
    const follow = (to: CardVersion, v: CardVersion) => { if (chosen && (!one || v.qty === 1)) setSelected(versionId(to)); };
    if (listId) {
      const ops: ListOp[] = [], reverse: ListOp[] = [];
      for (const v of targets) {
        const to = repoint(v, a, value, printing);
        const board = v.board ?? "main", n = one ? 1 : v.qty;
        if (a === "section") {
          const toBoard = to.board ?? "main";
          ops.push({ card_id: v.cardId, board, finish: v.finish, lang: v.lang, delta: -n }, { card_id: v.cardId, board: toBoard, finish: v.finish, lang: v.lang, delta: n });
          reverse.push({ card_id: v.cardId, board: toBoard, finish: v.finish, lang: v.lang, delta: -n }, { card_id: v.cardId, board, finish: v.finish, lang: v.lang, delta: n });
        } else {
          ops.push({ card_id: v.cardId, board, finish: v.finish, lang: v.lang, to_card_id: to.cardId, to_finish: to.finish, to_lang: to.lang, qty: n, swap: true });
          reverse.push({ card_id: to.cardId, board, finish: to.finish, lang: to.lang, to_card_id: v.cardId, to_finish: v.finish, to_lang: v.lang, qty: n, swap: true });
        }
        follow(to, v);
      }
      void listEdit(ops, reverse, label, () => capture("card_attribute_changed", props));
      return;
    }
    const ops: CollectionOp[] = [];
    for (const v of targets) {
      const item = col.items.get(versionKey(v));
      if (!item) continue;
      const to = repoint(v, a, value, printing);
      const o = editOps(item, printingPlaces(item).map((p) => ({ place: p.place, qty: p.qty })), to, one ? 1 : v.qty, binderId);
      if (o) { ops.push(...o); follow(to, v); }
    }
    if (ops.length) void write(ops, label, () => capture("card_attribute_changed", props));
  };

  /** − / + on the selected version (the new edition's count before it's written), else the one held most of. */
  const step = (delta: number) => {
    if (selected === EDITION && edition) {
      const qty = edition.qty + delta;
      if (qty > 0) { setEdition({ ...edition, qty }); return; }
      setEdition(null);
      setSelected(null);
      setNotice(null);
      return;
    }
    const v = chosen ?? (versions.length ? mainVersion(versions)! : current);
    const label = `${delta > 0 ? "Added" : "Removed"} 1 ${setLabel(v.cardId)}`;
    const props = { scope: scopeName, delta };
    // At 0 the screen keeps this version, so + puts it back.
    if (delta < 0 && v.qty <= 1) setDraft({ ...v, qty: 0 });
    if (listId) {
      const board = v.board ?? "main";
      void listEdit([{ card_id: v.cardId, board, finish: v.finish, lang: v.lang, delta }], [{ card_id: v.cardId, board, finish: v.finish, lang: v.lang, delta: -delta }],
                    label, () => capture("card_stepped", props));
      return;
    }
    void write([stepOp(v, delta, binderId)], label, () => capture("card_stepped", props));
  };

  /** Long press on +: a copy of the version in view to change into another, selected and dimmed until it differs. */
  const startEdition = () => {
    if (!versions.length || edition || busy) return;
    setEdition(newEdition(chosen ?? mainVersion(versions)!));
    setSelected(EDITION);
    setLast(null);
    setNotice(listId ? "Change its set, language, finish or section to add it." : "Change its set, language, condition or finish to add it.");
    capture("card_edition_started", { scope: scopeName, versions: versions.length });
  };

  /** "MB2 #218 · Foil · LP": what sets a version apart, for the Undo strip. */
  const versionName = (v: CardVersion) => [setLabel(v.cardId), v.finish !== "nonfoil" ? FINISH_LABEL[v.finish] : null,
    list ? (v.board && v.board !== "main" ? boardTitle(list.kind, v.board) : null) : v.condition !== "NM" ? v.condition : null,
    v.lang !== "en" && factsById.get(v.cardId)?.lang === "en" ? languageName(v.lang) : null].filter(Boolean).join(" · ");

  /** The edition now differs from every version in view: add its copies (into the binder or the line's section in those
   *  scopes) and select the version it became. */
  const addEdition = (v: CardVersion, a: CardAttribute) => {
    setEdition(null);
    setSelected(versionId(v));
    setNotice(null);
    const label = `Added ${v.qty} ${versionName(v)}`;
    const props = { scope: scopeName, attribute: a, copies: v.qty };
    if (listId) {
      const board = v.board ?? "main";
      void listEdit([{ card_id: v.cardId, board, finish: v.finish, lang: v.lang, delta: v.qty }], [{ card_id: v.cardId, board, finish: v.finish, lang: v.lang, delta: -v.qty }],
                    label, () => capture("card_edition_added", props));
      return;
    }
    void write([stepOp(v, v.qty, binderId)], label, () => capture("card_edition_added", props));
  };

  /** The bar's +: asks one copy or all of them first when more than one is in view (the selected version's copies when one
   *  is selected). */
  const openAddTo = () => {
    const total = inView.reduce((n, v) => n + v.qty, 0);
    if (total <= 1) { setAddTo(addLines(inView, current, false)); return; }
    setMenu({ title: chosen ? "Add to · this version only" : "Add to", items: [
      { title: "One copy", onClick: () => setAddTo(addLines(inView, current, false)) },
      { title: `All ${total} copies`, onClick: () => setAddTo(addLines(inView, current, true)) },
    ] });
  };

  const undo = async () => {
    if (!last || busy) return;
    setBusy(true);
    try {
      await last.run();
      setLast(null);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  // Match collection (contract/owned-by-card-2026-10-31.md § 2): the list's lines of this card and the versions you own.
  const match = (() => {
    if (!list || list.eventId) return null;
    const ids = new Set(facts.map((f) => f.cardId));
    const lines = needsOf(list).filter((l) => ids.has(l.cardId));
    const owned = ownedVersions(oldest.map((x) => catalog.pId[x]), col.items.values());
    const boards = matchSections(lines, owned);
    return boards.length ? { lines, owned, boards, detail: matchDetail(lines, owned) } : null;
  })();
  const openMatch = () => {
    if (!match || !list) return;
    capture("match_collection_opened", { kind: list.kind, versions: match.owned.length,
                                         copies: match.lines.filter((l) => match.boards.includes(l.board)).reduce((n, l) => n + l.qty, 0) });
    setMatching(true);
  };
  const matchStrip = match && !last ? (
    <div className="shrink-0 bg-t1-surface px-4 py-3 flex items-center justify-between gap-3">
      <span className="t1-label truncate">{match.detail}</span>
      <button type="button" onClick={openMatch} className="t1-label !text-t1-text hover:!text-t1-accent shrink-0">Match collection</button>
    </div>
  ) : null;

  const price = markConverted(usdText(usdPrice(current.cardId, current.finish, current.condition)), usdConverted(current.cardId, current.finish));
  const status = last ? (
    <div className="shrink-0 bg-t1-surface px-4 py-3 flex items-center justify-between gap-3">
      <span className="t1-label truncate">{last.label}</span>
      <button type="button" onClick={undo} disabled={busy} className="t1-label !text-t1-text hover:!text-t1-accent">{busy ? "Undoing…" : "Undo"}</button>
    </div>
  ) : notice ? <Notice tone="info">{notice}</Notice> : null;

  // The attribute row: the value the copies in view share, or MIX.
  const setValue = shared(shown, (v) => v.cardId);
  const printingShown = setValue ? factsById.get(setValue) : undefined;
  const cells: { a: CardAttribute; value: string; opens: boolean }[] = [
    { a: "set", value: setValue ? catalog.pSet[indexById.get(setValue)!].toUpperCase() : "Mix", opens: true },
  ];
  // A non-English printing's language is its own. Deck and cube lines name a language too, but no condition.
  const lang = shared(shown, (v) => v.lang);
  cells.push({ a: "language", value: lang?.toUpperCase() ?? "Mix", opens: printingShown ? printingShown.lang === "en" : true });
  if (!list) cells.push({ a: "condition", value: shared(shown, (v) => v.condition) ?? "Mix", opens: true });
  if (showsFinish(shown, factsById)) {
    const f = shared(shown, (v) => v.finish);
    cells.push({ a: "finish", value: f ? finishCode(f) : "Mix", opens: printingShown ? finishesOf(printingShown).length > 1 : true });
  }
  if (list) cells.push({ a: "section", value: (() => { const b = shared(shown, (v) => v.board ?? "main"); return b ? sectionCode(b) : "Mix"; })(), opens: true });

  const count = inView.reduce((n, v) => n + v.qty, 0);
  const tiles: { v: CardVersion; id: string; dim: boolean }[] = [
    ...versions.map((v) => ({ v, id: versionId(v), dim: false })), ...(edition ? [{ v: edition, id: EDITION, dim: true }] : []),
  ];
  const p = indexById.get(current.cardId);
  const flips = p != null && catalog.pFaces[p] > 1;

  // The card area: one image as large as fits, or a two-column grid of versions.
  const tileW = Math.floor((Math.min(area.w - 64, 376 * area.w / 440) - 1) / 2);
  const bigW = Math.floor(Math.min(area.w - 64, (area.h - 32 - (flips ? 44 : 0)) * ASPECT));

  return (
    <LibScreen>
      <CardBar name={name} price={price} onBack={onBack} info={info}
               onAdd={isSearch ? undefined : openAddTo}
               onInfo={() => { setInfo(!info); if (!info) capture("card_info_opened", { scope: scopeName }); }} />
      {(error || col.error) && <Notice tone="error">{error ?? col.error}</Notice>}
      {info ? (
        <>
          {status}
          <CardInfo catalog={catalog} oi={oi} version={current} p={p ?? null} printings={oldest} list={list} context={context}
                    lists={lists.lists} report={report} onList={onList} match={match ? { detail: match.detail, open: openMatch } : null} />
        </>
      ) : (
        <>
          <div ref={areaRef} className="flex-1 min-h-0 bg-t1-bg overflow-y-auto">
            {area.w > 0 && (tiles.length > 1 ? (
              <div className="min-h-full flex items-center justify-center py-4">
                <div className="grid gap-px" style={{ gridTemplateColumns: `${tileW}px ${tileW}px` }}>
                  {tiles.map(({ v, id, dim }) => {
                    const on = id === selected;
                    const vp = indexById.get(v.cardId) ?? null;
                    return (
                      <button key={id} type="button" aria-pressed={on}
                              aria-label={[setLabel(v.cardId), FINISH_LABEL[v.finish], v.board && list ? boardTitle(list.kind, v.board) : null,
                                           list ? null : v.condition, String(v.qty), dim ? "new, not added yet" : null].filter(Boolean).join(", ")}
                              onClick={() => { setSelected(on ? null : id); if (!on) capture("card_version_selected", { versions: versions.length }); }}
                              className={`relative block ${on ? "outline outline-1 outline-t1-accent" : ""}`}>
                        <CardArt c={catalog} p={vp} width={tileW} finish={v.finish} />
                        {/* The new edition is dimmed: it isn't written until it differs. */}
                        {dim && <span className="absolute inset-0 bg-t1-bg/60" />}
                        {v.qty > 1 && (
                          <span className="absolute bg-t1-bg px-1.5 py-0.5 text-[13px] tabular-nums" style={{ right: tileW * 0.05, bottom: tileW * 0.05 }}>{v.qty}</span>
                        )}
                      </button>
                    );
                  })}
                </div>
              </div>
            ) : (
              <div className="h-full flex flex-col items-center justify-center">
                <button type="button" onClick={() => { if (p != null) { setZoom(p); capture("image_zoomed", { screen: "card_detail" }); } }}
                        className="block cursor-zoom-in" aria-label={`${name}, ${setLabel(current.cardId)}. Zoom`}>
                  <CardArt key={`${p}|${back}`} c={catalog} p={p ?? null} width={Math.max(bigW, 60)} finish={current.finish} back={back} alt={name} />
                </button>
                {flips && (
                  <button type="button" onClick={() => { setBack(!back); capture("card_flipped"); }}
                          className="w-[120px] h-[44px] t1-label !text-t1-text hover:!text-t1-accent">{back ? "Front" : "Flip"}</button>
                )}
              </div>
            ))}
          </div>
          {status}
          {matchStrip}
          <div className="shrink-0 flex gap-px bg-t1-bg">
            {cells.map(({ a, value, opens }) => (
              <button key={a} type="button" aria-label={`${a}: ${value}`}
                      onClick={() => { if (opens && !busy) setPicker(a); }}
                      className={`flex-1 h-[50px] text-[12px] uppercase tracking-[1.5px] text-t1-muted truncate ${opens ? "hover:text-t1-text" : "cursor-default"}`}>
                {value}
              </button>
            ))}
          </div>
          {isSearch ? (
            <button type="button" onClick={() => setAddTo([current])}
                    className="shrink-0 h-[88px] lg:h-[64px] bg-t1-surface hover:bg-t1-surface-hover pt-6 lg:pt-0 flex lg:items-center justify-center text-[15px] font-semibold uppercase tracking-[4px] pb-[env(safe-area-inset-bottom)]">
              Add to
            </button>
          ) : (
            <div className="shrink-0 flex gap-px">
              <StepCell label="Remove one" enabled={!busy && count > 0} onClick={() => step(-1)}>
                <MinusIcon />
              </StepCell>
              <div className="flex-1 h-[88px] lg:h-[64px] bg-t1-surface pt-6 lg:pt-0 flex lg:items-center justify-center text-[15px] font-semibold tracking-[4px] tabular-nums"
                   aria-label={`${count} copies`}>{count}</div>
              <StepCell label="Add one" enabled={!busy} onClick={() => step(1)}
                        onLongPress={versions.length && !edition ? startEdition : undefined} longPressLabel="Add a different version">
                <PlusIcon />
              </StepCell>
            </div>
          )}
        </>
      )}

      {picker === "set" && (
        <Sheet onClose={() => setPicker(null)} label="Printing">
          <div className="max-h-[490px] overflow-y-auto grid grid-cols-4 gap-px p-px">
            {oldest.map((x) => {
              const on = catalog.pId[x] === setValue;
              return (
                <button key={x} type="button" aria-pressed={on} onClick={() => pick("set", catalog.pId[x])}
                        aria-label={`${catalog.pSet[x].toUpperCase()} #${catalog.pCn[x]}${catalog.pLang[x] === "en" ? "" : `, ${languageName(catalog.pLang[x])}`}`}
                        className={`block ${on ? "outline outline-1 -outline-offset-1 outline-t1-accent" : ""}`}>
                  <PrintingThumb c={catalog} p={x} />
                </button>
              );
            })}
          </div>
        </Sheet>
      )}
      {picker && picker !== "set" && (
        <Sheet onClose={() => setPicker(null)} label={picker}>
          <SelectorRows current={picker === "language" ? shared(shown, (v) => v.lang) : picker === "condition" ? shared(shown, (v) => v.condition)
                                  : picker === "finish" ? shared(shown, (v) => v.finish) : shared(shown, (v) => v.board ?? "main")}
                        options={picker === "language" ? LANGUAGES.map((l) => ({ value: l.code, label: l.name }))
                          : picker === "condition" ? CONDITIONS.map((c) => ({ value: c, label: c }))
                          : picker === "finish" ? (["nonfoil", "foil", "etched"] as Finish[])
                            .filter((f) => shown.some((v) => { const pf = factsById.get(v.cardId); return pf && finishesOf(pf).includes(f); }))
                            .map((f) => ({ value: f, label: FINISH_LABEL[f] }))
                          : [...(list && (entriesOf(list).some((e) => e.board === "commander") || (list.kind === "deck" && ZONE_FORMATS.has(list.format))) ? ["commander" as Board] : []), ...sectionsFor(list?.kind ?? "deck")]
                            .map((b) => ({ value: b, label: list ? boardTitle(list.kind, b) : b }))}
                        onPick={(v) => pick(picker, v)} />
        </Sheet>
      )}
      {menu && <Menu title={menu.title} items={menu.items} onClose={() => setMenu(null)} />}
      {confirm && (
        <Dialog title={confirm.title} message="Every copy in view changes. Undo puts them back." cancelLabel="Cancel" confirmLabel="Change all"
                onCancel={() => setConfirm(null)} onConfirm={() => { const r = confirm.run; setConfirm(null); r(); }} />
      )}
      {addTo && (
        <AddToSheet catalog={catalog} oi={oi} lines={addTo} indexById={indexById} lists={lists.lists} scope={scopeName}
                    onClose={() => setAddTo(null)} onDone={(label, u) => { setAddTo(null); report(label, u); }} />
      )}
      {matching && match && list && (
        <MatchSheet catalog={catalog} list={list} lines={match.lines} versions={match.owned} boards={match.boards} indexById={indexById}
                    onClose={() => setMatching(false)} onDone={(label, u) => { setMatching(false); report(label, u); }} />
      )}
      {zoom != null && (
        <ZoomImage src={cardImageUrl(catalog, zoom, "large", back && catalog.pFaces[zoom] > 1)} alt={name} title={name}
                   subtitle={setLabel(catalog.pId[zoom])} onClose={() => setZoom(null)} />
      )}
    </LibScreen>
  );
}

/* ── pieces ───────────────────────────────────────────────────────────── */

/** Match collection: a section's copies of the card take the printings you own (contract/owned-by-card-2026-10-31.md § 2).
 *  Opens filled in by Auto; a tap on a tile picks one more of it, or back to none. */
function MatchSheet({ catalog, list, lines, versions, boards, indexById, onClose, onDone }: {
  catalog: Catalog; list: CardList; lines: Need[]; versions: Version[]; boards: string[]; indexById: Map<string, number>;
  onClose: () => void; onDone: (label: string, undo: Undo | null) => void;
}) {
  const [board, setBoard] = useState(boards[0]);
  const section = lines.filter((l) => l.board === board);
  const [picks, setPicks] = useState<Pick[]>(() => autoMatch(section, versions));
  const [auto, setAuto] = useState(true);
  const [fail, setFail] = useState<string | null>(null);
  const total = section.reduce((n, l) => n + l.qty, 0);
  const used = picks.reduce((n, p) => n + p.qty, 0);
  const ops = matchOps(section, picks);
  const w = 200;
  const pickBoard = (b: string) => { setBoard(b); setPicks(autoMatch(lines.filter((l) => l.board === b), versions)); setAuto(true); };
  const toOps = (ms: Move[]): ListOp[] => ms.map((m) => ({ card_id: m.cardId, board: board as Board, finish: m.finish as ListOp["finish"], lang: m.lang ?? "en",
    to_card_id: m.toCardId, to_finish: m.toFinish as ListOp["finish"], to_lang: m.lang ?? "en", qty: m.qty, swap: true }));
  const save = async () => {
    if (!ops.length) return;
    const back = [...ops].reverse().map((m) => ({ cardId: m.toCardId, finish: m.toFinish, lang: m.lang, toCardId: m.cardId, toFinish: m.finish, qty: m.qty }));
    const moved = ops.reduce((n, m) => n + m.qty, 0);
    try {
      await editList(list.id, toOps(ops));
      capture("match_collection_saved", { kind: list.kind, moved, versions: new Set(ops.map((m) => `${m.toCardId}|${m.toFinish}`)).size, auto });
      const label = `${moved} ${moved === 1 ? "copy" : "copies"} now your printings`;
      onDone(label, { label, run: () => editList(list.id, toOps(back)) });
    } catch (e) { setFail(errorMessage(e)); }
  };
  return (
    <Sheet onClose={onClose} label="Match collection">
      <div className="p-4 flex flex-col gap-3">
        <div className="t1-label">Match collection</div>
        {boards.length > 1 && <Segmented options={boards.map((b) => ({ value: b, label: boardTitle(list.kind, b as Board) }))} value={board} onChange={pickBoard} />}
        <div className="flex items-center gap-4">
          <span className="t1-label flex-1 truncate">{used} of {total} picked · tap to pick</span>
          <button type="button" className="t1-label hover:!text-t1-text" onClick={() => { setPicks([]); setAuto(false); }}>Clear</button>
          <button type="button" className="t1-label hover:!text-t1-text" onClick={() => { setPicks(autoMatch(section, versions)); setAuto(true); }}>Auto</button>
        </div>
        <div className="grid grid-cols-2 gap-px max-h-[440px] overflow-y-auto">
          {versions.map((v) => {
            const n = picks.find((x) => x.cardId === v.cardId && x.finish === v.finish)?.qty ?? 0;
            const p = indexById.get(v.cardId) ?? null;
            const set = p == null ? "" : `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`;
            return (
              <button key={`${v.cardId}|${v.finish}`} type="button" aria-label={`${set}, own ${v.owned}, ${n} picked`}
                      onClick={() => { setPicks(tapPick(picks, versions, total, v.cardId, v.finish)); setAuto(false); }}
                      className="flex flex-col items-center gap-1 pb-2">
                <span className={`relative block ${n ? "outline outline-1 outline-t1-accent" : ""}`}>
                  <CardArt c={catalog} p={p} width={w} finish={v.finish as Finish} />
                  {n > 0 && <span className="absolute bg-t1-accent text-t1-ink px-2 py-0.5 text-[15px] font-semibold tabular-nums" style={{ right: w * 0.05, bottom: w * 0.05 }}>{n}</span>}
                </span>
                <span className="t1-label truncate max-w-full">{[set, v.finish === "nonfoil" ? null : FINISH_LABEL[v.finish as Finish], `Own ${v.owned}`].filter(Boolean).join(" · ")}</span>
              </button>
            );
          })}
        </div>
        {total > used && <span className="t1-label">{total - used} not picked stay as listed</span>}
        {fail && <Notice tone="error">{fail}</Notice>}
        <button type="button" disabled={!ops.length} onClick={() => void save()}
                className="h-[54px] bg-t1-surface hover:bg-t1-surface-hover disabled:hover:bg-t1-surface text-[15px] font-semibold uppercase tracking-[4px] disabled:text-t1-muted">
          {ops.length ? "Use these printings" : "Already matches"}
        </button>
      </div>
    </Sheet>
  );
}

/** Figma Bar: back arrow, name, price, then + (owned scopes) and the list / tune icon. */
function CardBar({ name, price, onBack, onAdd, onInfo, info }: {
  name: string; price?: string | null; onBack: () => void; onAdd?: () => void; onInfo?: () => void; info?: boolean;
}) {
  const icon = "shrink-0 w-[50px] h-[50px] flex items-center justify-center hover:text-t1-accent";
  return (
    <div className="shrink-0 h-[50px] bg-t1-bg flex items-center">
      <button type="button" onClick={onBack} aria-label="Back" className={icon}><BackArrow /></button>
      <div className="flex-1 min-w-0 px-1 flex items-center justify-between gap-2">
        <span className="text-[12px] truncate">{name}</span>
        {price && <span className="shrink-0 text-[12px] tracking-[1.5px] text-t1-muted">{price}</span>}
      </div>
      {onAdd && <button type="button" onClick={onAdd} aria-label="Add to" className={icon}><PlusIcon /></button>}
      {onInfo && <button type="button" onClick={onInfo} aria-label={info ? "Card" : "Details"} className={icon}>{info ? <TuneIcon /> : <ListIcon />}</button>}
    </div>
  );
}

/** One third of the stepper: 88 px on a phone (the home indicator under it), the glyph 24 px from the top. Disabled is
 *  the flat disabled colour, never dimmed. */
function StepCell({ label, enabled, onClick, onLongPress, longPressLabel, children }: {
  label: string; enabled: boolean; onClick: () => void; onLongPress?: () => void; longPressLabel?: string; children: ReactNode;
}) {
  // A held press (or right-click on a desktop) runs onLongPress instead of the tap.
  const timer = useRef<number | null>(null);
  const held = useRef(false);
  const cancel = () => { if (timer.current != null) { window.clearTimeout(timer.current); timer.current = null; } };
  useEffect(() => cancel, []);
  return (
    <button type="button" aria-label={label} aria-disabled={!enabled} title={onLongPress ? `Hold: ${longPressLabel}` : undefined}
            onPointerDown={() => {
              held.current = false;
              if (!onLongPress || !enabled) return;
              timer.current = window.setTimeout(() => { held.current = true; timer.current = null; onLongPress(); }, 450);
            }}
            onPointerUp={cancel} onPointerLeave={cancel} onPointerCancel={cancel}
            onContextMenu={(e) => { if (!onLongPress) return; e.preventDefault(); cancel(); if (!held.current && enabled) onLongPress(); held.current = true; }}
            onClick={() => { if (held.current) { held.current = false; return; } if (enabled) onClick(); }}
            className={`flex-1 h-[88px] lg:h-[64px] bg-t1-surface pt-6 lg:pt-0 flex lg:items-center justify-center ${enabled ? "hover:bg-t1-surface-hover" : "text-t1-disabled cursor-default"}`}>
      {children}
    </button>
  );
}

/** A bottom panel over a scrim (Figma Selector panels); centred on a desktop window. Esc or the scrim closes it. */
function Sheet({ children, onClose, label }: { children: ReactNode; onClose: () => void; label: string }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  return (
    <div className="fixed inset-0 z-50 flex flex-col justify-end lg:justify-center" role="dialog" aria-modal="true" aria-label={label}>
      <div className="absolute inset-0 bg-black/60" onClick={onClose} />
      <div className="relative bg-t1-bg w-full max-w-[480px] mx-auto pb-[env(safe-area-inset-bottom)]">{children}</div>
    </div>
  );
}

interface Option { value: string; label: string; detail?: string }

/** Selector rows: centred uppercase labels; pressed rows fill with surface; the current value is outlined in accent. */
function SelectorRows({ options, current, onPick, title, onBack }: {
  options: Option[]; current?: string | null; onPick: (v: string) => void; title?: string; onBack?: () => void;
}) {
  return (
    <div className="p-4 flex flex-col gap-2.5">
      {(title || onBack) && (
        <div className="h-[18px] flex items-center gap-2.5">
          {onBack && <button type="button" onClick={onBack} aria-label="Back" className="hover:text-t1-accent"><BackArrow /></button>}
          <span className="text-[12px] uppercase tracking-[1.5px] text-t1-muted">{title}</span>
        </div>
      )}
      <div className="max-h-[400px] overflow-y-auto flex flex-col">
        {options.map((o) => {
          const on = o.value === current;
          return (
            <button key={o.value || o.label} type="button" aria-pressed={on} onClick={() => onPick(o.value)}
                    className={`shrink-0 flex flex-col items-center justify-center gap-0.5 active:bg-t1-surface hover:bg-t1-surface ${o.detail ? "h-[62px]" : "h-[50px]"} ${on ? "outline outline-1 -outline-offset-1 outline-t1-accent" : ""}`}>
              <span className={`text-[12px] uppercase tracking-[1.5px] truncate ${on ? "text-t1-text" : "text-t1-muted"}`}>{o.label}</span>
              {o.detail && <span className="text-[8px] uppercase tracking-[1.5px] text-t1-disabled truncate">{o.detail}</span>}
            </button>
          );
        })}
      </div>
    </div>
  );
}

/** A printing in the Set picker: fills a quarter of the panel. */
function PrintingThumb({ c, p }: { c: Catalog; p: number }) {
  if (c.pFaces[p] === 0) return <div className="w-full bg-t1-surface" style={{ aspectRatio: `${488} / ${680}` }} />;
  return <img src={cardImageUrl(c, p, "small")} alt="" loading="lazy" decoding="async" draggable={false}
              className="w-full h-auto block bg-t1-bg" style={{ aspectRatio: `${488} / ${680}` }} />;
}

/* Material icons, weight 300 (Figma bar and stepper). */
function PlusIcon() {
  return <svg viewBox="0 0 18 18" width={18} height={18} fill="currentColor" aria-hidden="true"><path d="M4.125 8.4375h9.75v1.125h-9.75zM8.4375 4.125h1.125v9.75h-1.125z" /></svg>;
}
function MinusIcon() {
  return <svg viewBox="0 0 18 18" width={18} height={18} fill="currentColor" aria-hidden="true"><path d="M4.125 8.4375h9.75v1.125h-9.75z" /></svg>;
}
function ListIcon() {
  return (
    <svg viewBox="0 0 18 18" width={18} height={18} fill="currentColor" aria-hidden="true">
      {[5.668, 8.4375, 11.207].map((y) => <g key={y}><rect x={5.495} y={y} width={9.88} height={1.125} /><circle cx={3.231} cy={y + 0.563} r={0.606} /></g>)}
    </svg>
  );
}
function TuneIcon() {
  const r = (x: number, y: number, w: number, h: number) => <rect key={`${x},${y}`} x={2.4375 + x} y={2.4375 + y} width={w} height={h} />;
  return (
    <svg viewBox="0 0 18 18" width={18} height={18} fill="currentColor" aria-hidden="true">
      {r(0, 1.5, 7.125, 1.125)}{r(9, 0, 1.125, 4.125)}{r(10.125, 1.5, 3, 1.125)}
      {r(0, 6, 3, 1.125)}{r(3, 4.5, 1.125, 4.125)}{r(6, 6, 7.125, 1.125)}
      {r(0, 10.5, 4.125, 1.125)}{r(6, 9, 1.125, 4.125)}{r(7.125, 10.5, 6, 1.125)}
    </svg>
  );
}

/* ── Add to ───────────────────────────────────────────────────────────── */

type Step = { k: "root" } | { k: "decks" } | { k: "section"; id: string } | { k: "cubes" } | { k: "binders" } | { k: "want" } | { k: "trades" } | { k: "side"; id: string | null };

/** Collection / Deck / Cube / Binder / Want / Trade, each drilling down in place (Figma Add To Selection and Add to
 *  Drilldown). Adds `lines` (one copy, or every copy in view, each version with its count); condition and language go
 *  with collection, binder and trade adds. */
function AddToSheet({ catalog, oi, lines, indexById, lists, scope, onClose, onDone }: {
  catalog: Catalog; oi: number; lines: CardVersion[]; indexById: Map<string, number>; lists: CardList[]; scope: string;
  onClose: () => void; onDone: (label: string, undo: Undo | null) => void;
}) {
  const [step, setStep] = useState<Step>({ k: "root" });
  const [error, setError] = useState<string | null>(null);
  const trades = useTrades();
  const { userId } = useLibrarySession();
  const col = useCollection(userId);
  const b = useBinders(userId);
  const version = lines[0];
  const pIndex = (cardId: string) => indexById.get(cardId) ?? null;
  const printingIds = [...new Set(lines.map((l) => l.cardId))];
  // The printing when every line shares one.
  const p = printingIds.length === 1 ? pIndex(version.cardId) : null;
  const name = p == null ? catalog.oName[oi] : `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`;
  const count = lines.reduce((n, l) => n + l.qty, 0);
  const owned = lines.every((l) => (col.items.get(versionKey(l))?.qty ?? 0) > 0);
  const finishes = p == null ? [] : finishesOf(factsOf(catalog, p));

  const finish = (destination: string, label: string, undo: Undo | null) => {
    capture("card_added_to", { destination, scope, copies: count });
    onDone(label, undo);
  };
  const fail = (e: unknown) => setError(errorMessage(e));

  const toCollection = async (binderId: string | null, place: string) => {
    try {
      const res = await applyOps(lines.map((l) => stepOp(l, l.qty, binderId)));
      const label = `Added ${count} ${name} to ${place}`;
      finish(binderId ? "binder" : "collection", label, { label, run: () => undoBatch(res.batch_id) });
    } catch (e) { fail(e); }
  };
  const toList = async (id: string, board: Board) => {
    const l = lists.find((x) => x.id === id);
    if (!l) return;
    const ops: { card_id: string; board: Board; finish: Finish; lang: string; delta: number }[] = lines.flatMap((line) => {
      const lp = pIndex(line.cardId);
      if (lp == null) return [];
      // A finish the printing lacks is saved in one it has (contract/lists-2026-10-15.md).
      const fs = finishesOf(factsOf(catalog, lp));
      // The copy keeps the language on screen (a Japanese copy you own goes in as Japanese).
      return [{ card_id: line.cardId, board, finish: fs.includes(line.finish) ? line.finish : fs[0] ?? "nonfoil",
                lang: langForNew(catalog.pLang[lp], line.lang), delta: line.qty }];
    });
    if (!ops.length) return;
    try {
      await editList(id, ops);
      const label = `Added ${count} ${name} to ${l.name} · ${boardTitle(l.kind, board)}`;
      finish(l.kind, label, { label, run: () => editList(id, ops.map((o) => ({ ...o, delta: -o.delta }))) });
    } catch (e) { fail(e); }
  };
  const want = async (how: string) => {
    try {
      // One want per printing (and finish), counting the copies of each.
      const wants = new Map<string, { card_id: string | null; finish: Finish | null; delta: number }>();
      for (const l of lines) {
        const card_id = how === "any" ? null : l.cardId, f = how === "finish" ? l.finish : null;
        const key = `${card_id ?? ""}|${f ?? ""}`;
        const w = wants.get(key);
        if (w) w.delta += l.qty; else wants.set(key, { card_id, finish: f, delta: l.qty });
      }
      await applyWants([...wants.values()].map((w) => ({ oracle_id: catalog.oId[oi], ...w })),
                       "want_added", { any_printing: how === "any", finish: how === "finish", has_max: false, from: "card" });
      finish("want", `Wanted ${count} ${how === "any" ? catalog.oName[oi] : name}`, null);
    } catch (e) { fail(e); }
  };
  const toTrade = async (id: string | null, give: boolean) => {
    const t = id ? trades.trades.find((x) => x.id === id) ?? null : null;
    const put = (side: TradeLine[]) => lines.reduce((out, v) => {
      const binderId = give ? forTrade(versionKey(v)).binderId : null;
      const line: TradeLine = { card_id: v.cardId, finish: v.finish, condition: v.condition, lang: v.lang, qty: v.qty, ...(binderId ? { binder_id: binderId } : {}) };
      const i = out.findIndex((l) => l.card_id === line.card_id && l.finish === line.finish && l.condition === line.condition && l.lang === line.lang);
      return i >= 0 ? out.map((l, j) => (j === i ? { ...l, qty: l.qty + v.qty } : l)) : [...out, line];
    }, side);
    try {
      const saved = await saveTrade(t, t?.partner ?? null, give ? put(t?.gives ?? []) : t?.gives ?? [], give ? t?.gets ?? [] : put(t?.gets ?? []));
      finish("trade", `${give ? "Giving" : "Getting"} ${count} ${name} in the trade${saved.partner ? ` with ${saved.partner}` : ""}`, null);
    } catch (e) { fail(e); }
  };

  void b.version;
  let title: string | undefined;
  let options: Option[] = [];
  let onPick: (v: string) => void = () => {};
  switch (step.k) {
    case "root":
      options = [["collection", "Collection"], ["deck", "Deck"], ["cube", "Cube"], ["binder", "Binder"], ["want", "Want"], ["trade", "Trade"]]
        .map(([value, label]) => ({ value, label }));
      onPick = (v) => {
        if (v === "collection") void toCollection(null, "your collection");
        else setStep(v === "deck" ? { k: "decks" } : v === "cube" ? { k: "cubes" } : v === "binder" ? { k: "binders" } : v === "want" ? { k: "want" } : { k: "trades" });
      };
      break;
    case "decks": {
      title = "Deck";
      const decks = lists.filter((l) => l.kind === "deck" && !l.eventId);
      options = decks.length ? decks.map((l) => ({ value: l.id, label: l.name, detail: formatName(l.format) })) : [{ value: "", label: "No decks yet" }];
      onPick = (v) => { if (v) setStep({ k: "section", id: v }); };
      break;
    }
    case "section": {
      const l = lists.find((x) => x.id === step.id);
      title = l?.name ?? "Deck";
      options = sectionsFor("deck").map((s) => ({ value: s, label: boardTitle("deck", s) }));
      onPick = (v) => void toList(step.id, v as Board);
      break;
    }
    case "cubes": {
      title = "Cube";
      const cubes = lists.filter((l) => l.kind === "cube");
      options = cubes.length ? cubes.map((l) => ({ value: l.id, label: l.name, detail: `${entriesOf(l).filter((e) => e.board === "main").reduce((n, e) => n + e.qty, 0)} cards` }))
        : [{ value: "", label: "No cubes yet" }];
      onPick = (v) => { if (v) void toList(v, "main"); };
      break;
    }
    case "binders": {
      title = "Binder";
      const all = [...b.binders].sort((x, y) => x.name.localeCompare(y.name));
      options = all.length ? all.map((x) => ({ value: x.id, label: x.name, detail: x.for_trade ? "For trade" : undefined })) : [{ value: "", label: "No binders yet" }];
      onPick = (v) => { if (v) void toCollection(v, binderById(v)?.name ?? "the binder"); };
      break;
    }
    case "want":
      title = "Want";
      options = [{ value: "any", label: "Any printing" },
                 ...(p == null && printingIds.length > 1 ? [{ value: "printing", label: "Each printing", detail: `${printingIds.length} printings` },
                                                            { value: "finish", label: "Each printing and finish" }] : []),
                 ...(p != null ? [{ value: "printing", label: "This printing", detail: name }] : []),
                 ...(p != null && finishes.length > 1 ? [{ value: "finish", label: "This printing and finish", detail: `${name} · ${FINISH_LABEL[version.finish]}` }] : [])];
      onPick = (v) => void want(v);
      break;
    case "trades":
      title = "Trade";
      options = [{ value: "new", label: "New trade" }, ...trades.trades.filter((t) => t.status !== "confirmed").map((t) => ({
        value: t.id, label: t.partner ?? "Trade",
        detail: `Give ${t.gives.reduce((n, l) => n + l.qty, 0)} · get ${t.gets.reduce((n, l) => n + l.qty, 0)}`,
      }))];
      onPick = (v) => { const id = v === "new" ? null : v; if (owned) setStep({ k: "side", id }); else void toTrade(id, false); };
      break;
    case "side":
      title = "Get or give";
      options = [{ value: "get", label: "Get" }, { value: "give", label: "Give", detail: "From your copies" }];
      onPick = (v) => void toTrade(step.id, v === "give");
      break;
  }
  const parent: Step = step.k === "section" ? { k: "decks" } : step.k === "side" ? { k: "trades" } : { k: "root" };
  return (
    <Sheet onClose={onClose} label="Add to">
      {error && <Notice tone="error">{error}</Notice>}
      <SelectorRows title={title} onBack={step.k === "root" ? undefined : () => setStep(parent)} options={options} onPick={onPick} />
    </Sheet>
  );
}

/* ── info view ────────────────────────────────────────────────────────── */

interface Details { text: string; type?: string; rarity?: string; artist?: string }
const detailsCache = new Map<string, Details>();

/** Rules text and details from Scryfall's API for one printing, asked once per printing per page load. */
async function fetchDetails(cardId: string): Promise<Details> {
  const hit = detailsCache.get(cardId);
  if (hit) return hit;
  const res = await fetch(`https://api.scryfall.com/cards/${cardId}`, { headers: { Accept: "application/json" } });
  if (!res.ok) throw new Error(`Scryfall ${res.status}`);
  const c = await res.json() as { oracle_text?: string; type_line?: string; rarity?: string; artist?: string;
                                  card_faces?: { name?: string; oracle_text?: string; type_line?: string; artist?: string }[] };
  const faces = c.card_faces ?? [];
  const text = c.oracle_text || faces.flatMap((f) => (f.oracle_text ? [faces.length > 1 ? `${f.name ?? ""}\n${f.oracle_text}` : f.oracle_text] : [])).join("\n\n");
  const out = { text, type: c.type_line ?? faces[0]?.type_line, rarity: c.rarity, artist: c.artist ?? faces[0]?.artist };
  detailsCache.set(cardId, out);
  return out;
}

/** The list icon's view (Figma 231:9241): a smaller image, the rules text, Price / Card type / Rarity / Artist, then
 *  where the card is used, your copies, wants, hero and history. */
function CardInfo({ catalog, oi, version, p, printings, list, context, lists, report, onList, match }: {
  catalog: Catalog; oi: number; version: CardVersion; p: number | null; printings: number[]; list?: CardList; context?: CardContext;
  lists: CardList[]; report: (label: string, undo: Undo | null) => void; onList?: (id: string) => void;
  /** Match collection, when the list could use the printings you own. */
  match?: { detail: string; open: () => void } | null;
}) {
  const { userId } = useLibrarySession();
  const col = useCollection(userId);
  const b = useBinders(userId);
  const heroes = useLibraryHeroes();
  const [addCondition] = useAddCondition();
  const [details, setDetails] = useState<Details | null>(null);
  const [failed, setFailed] = useState(false);
  const [history, setHistory] = useState<HistoryEntry[] | null>(null);
  const [moving, setMoving] = useState<string | null>(null);
  const [menu, setMenu] = useState<{ title: string; items: MenuItem[] } | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let live = true;
    setFailed(false);
    fetchDetails(version.cardId).then((d) => live && setDetails(d), () => live && setFailed(true));
    return () => { live = false; };
  }, [version.cardId]);
  useEffect(() => {
    setHistory(null);
    fetchHistory(version.cardId).then(setHistory, () => setHistory([]));
  }, [version.cardId, col.version]);

  const label = (cardId: string) => { const x = catalog.printingIndex.get(cardId); return x == null ? "?" : `${catalog.pSet[x].toUpperCase()} #${catalog.pCn[x]}`; };
  const ids = new Set(printings.map((x) => catalog.pId[x]));
  void b.version;
  const owned = [...col.items.values()].filter((it) => ids.has(it.cardId)).sort((a, c) => a.k.localeCompare(c.k));
  const total = owned.reduce((n, it) => n + it.qty, 0);
  const uses = lists.filter((l) => !l.eventId).flatMap((l) => {
    const es = entriesOf(l).filter((e) => ids.has(e.cardId));
    const qty = es.filter((e) => e.board !== "maybe").reduce((n, e) => n + e.qty, 0);
    const considering = es.filter((e) => e.board === "maybe").reduce((n, e) => n + e.qty, 0);
    return qty + considering > 0 ? [{ l, qty, considering }] : [];
  });
  const used = uses.reduce((n, u) => n + u.qty, 0);
  const row = (k: string, v: string) => (
    <div className="shrink-0 bg-t1-bg px-4 py-2 min-h-[34px] flex items-center justify-between gap-3 text-[11px] tracking-[1.5px]">
      <span className="uppercase text-t1-muted shrink-0">{k}</span><span className="text-right">{v}</span>
    </div>
  );
  const heroScope = scopeOf(context?.search ? undefined : context, UNSORTED);

  // Add to collection from a deck or cube: what this card lacks there, every copy listed, or one of a listed printing.
  const listAdd = (() => {
    if (!list || list.eventId) return null;
    const lines = entriesOf(list).filter((e) => ids.has(e.cardId)).sort((a, c) => BOARD_ORDER.indexOf(a.board) - BOARD_ORDER.indexOf(c.board));
    if (!lines.length) return null;
    const only = new Set(lines.map((e) => e.cardId));
    const ownedBy = new Map<string, number>();
    for (const it of col.items.values()) {
      const k = `${it.cardId}|${it.finish}|${it.lang}`;
      // Every printing of the card: any of them covers a line (contract/owned-by-card-2026-10-31.md).
      if (ids.has(it.cardId)) ownedBy.set(k, (ownedBy.get(k) ?? 0) + it.qty);
    }
    const entries = entriesOf(list);
    const basics = basicCardIds(catalog);
    const missing = listAddOps(entries, list.kind, ownedBy, "missing", true, only, basics, cardOfCatalog(catalog));
    const all = listAddOps(entries, list.kind, ownedBy, "all", true, only);
    const m = copiesOf(missing), a = copiesOf(all);
    const add = async (ops: AddOp[], mode: string) => {
      const n = copiesOf(ops);
      setBusy(true);
      try {
        const res = await applyOps(toCollectionOps(ops, (id) => { const x = catalog.printingIndex.get(id); return x == null ? undefined : catalog.pLang[x]; },
                                                   addCondition));
        const text = `Added ${n} ${catalog.oName[oi]} to your collection`;
        report(text, { label: text, run: () => undoBatch(res.batch_id) });
        capture("list_added_to_collection", { kind: list.kind, mode, sideboard: true, copies: n, lines: ops.length, from: "card" });
      } catch (e) { report(errorMessage(e), null); } finally { setBusy(false); }
    };
    const items: MenuItem[] = [
      ...(m > 0 ? [{ title: `Add the ${m} missing`, detail: `As listed here · ${addCondition}`, onClick: () => void add(missing, "missing") }] : []),
      ...(a > 0 && a !== m ? [{ title: `Add all ${a}`, detail: `Every copy listed here · ${addCondition}`, onClick: () => void add(all, "all") }] : []),
      ...lines.slice(0, 4).map((e) => ({
        title: `Add 1 ${label(e.cardId)}${finishOf(e) === "nonfoil" ? "" : ` · ${FINISH_LABEL[finishOf(e)]}`}${langOf(e) === "en" ? "" : ` · ${langOf(e).toUpperCase()}`}`,
        detail: boardTitle(list.kind, e.board),
        onClick: () => void add([{ card_id: e.cardId, finish: finishOf(e), delta: 1, lang: langOf(e) }], "one"),
      })),
    ];
    return <Row title="Add to collection" detail={cardAddDetail(m, [...only].some((id) => basics.has(id)))}
                value={busy ? "Adding…" : "Add"} onClick={() => { if (!busy) setMenu({ title: `Add ${catalog.oName[oi]} to your collection`, items }); }} />;
  })();

  const movingItem = moving ? col.items.get(moving) : undefined;
  return (
    <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px bg-t1-bg">
      {p != null && <div className="shrink-0 py-4 flex justify-center"><CardArt c={catalog} p={p} width={Math.round(259 * ASPECT)} finish={version.finish} /></div>}
      <div className="shrink-0 p-4">
        {details ? <p className="text-[16px] tracking-[0.5px] leading-[1.45] whitespace-pre-line">{details.text || "No rules text."}</p>
          : <p className="text-[12px] text-t1-muted">{failed ? "Rules text needs a connection." : "Loading rules text…"}</p>}
      </div>
      {row("Price", markConverted(conditionPriceText(usdPrice(version.cardId, version.finish), version.condition),
                               usdConverted(version.cardId, version.finish), true) ?? "—")}
      {row("Card type", details?.type ?? catalog.oType[oi])}
      {catalog.oCost[oi] && row("Mana cost", catalog.oCost[oi])}
      {row("Rarity", details?.rarity ?? (p != null ? RARITY_NAME[catalog.pRarity[p]]?.toLowerCase() : null) ?? "—")}
      {row("Artist", details?.artist ?? "—")}
      {p != null && row("Printing", [label(version.cardId), catalog.pLang[p] === "en" ? null : languageName(catalog.pLang[p])].filter(Boolean).join(" · "))}
      {listAdd}
      {match && <Row title="Match collection" detail={match.detail} onClick={match.open} />}
      {uses.length > 0 && (
        <>
          <Section title={used > total ? `In decks and cubes · ${used} used · own ${total}` : `In decks and cubes · ${used}`} />
          {uses.map(({ l, qty, considering }) => {
            const kind = l.kind === "deck" ? `${formatName(l.format)} deck` : "Cube";
            return <Row key={l.id} title={l.name} detail={considering ? `${kind} · ${considering} considering` : kind} value={qty}
                        onClick={onList ? () => onList(l.id) : undefined} />;
          })}
        </>
      )}
      {owned.length > 0 && (
        <>
          <Section title="Your copies" count={total} />
          {owned.map((it) => (
            <Row key={it.k} title={`${label(it.cardId)} · ${FINISH_LABEL[it.finish]}`}
                 detail={[it.condition, it.lang === "en" ? null : it.lang.toUpperCase(), placementText(it)].filter(Boolean).join(" · ")}
                 value={<span className="flex items-center gap-3"><span className="t1-label !text-t1-text">Move</span><span>{it.qty}</span></span>}
                 onClick={() => setMoving(it.k)} />
          ))}
        </>
      )}
      <WantCardRow catalog={catalog} oi={oi} shown={p} onAdded={(t) => report(t, null)} />
      {heroScope && (() => {
        const on = isHero(catalog.oId[oi], heroScope, heroes);
        const place = heroScope.kind === "collection" ? "your collection"
          : heroScope.kind === "list" ? lists.find((l) => l.id === heroScope.id)?.name ?? "this list" : binderById(heroScope.id)?.name ?? "this binder";
        return <Row title={on ? `Hero of ${place}` : "Make it a hero"} detail={on ? "Tap to stop highlighting it" : `Highlighted in ${place} and where it's listed`}
                    value={on ? <span className="t1-label !text-t1-text">Hero</span> : undefined}
                    onClick={() => { if (!toggleHero(catalog.oId[oi], heroScope)) report(`${place.charAt(0).toUpperCase()}${place.slice(1)} has ${HERO_LIMIT} hero cards already.`, null); }} />;
      })()}
      <Section title={`History · ${label(version.cardId)}`} />
      <div className="shrink-0 bg-t1-surface px-4 py-3 flex flex-col gap-1">
        {history === null && <span className="t1-label">Loading…</span>}
        {history?.length === 0 && <span className="t1-label">No changes yet</span>}
        {history?.map((h, i) => (
          <span key={i} className={`text-[12px] tabular-nums ${h.undone ? "text-t1-disabled line-through" : ""}`}>
            {new Date(h.at).toLocaleDateString()} · {h.delta > 0 ? `+${h.delta}` : h.delta} {FINISH_LABEL[h.finish]} · {h.source} → {h.qty_after}
          </span>
        ))}
      </div>
      {movingItem && (
        <MoveCopies item={movingItem} label={label(movingItem.cardId)} onClose={() => setMoving(null)}
                    onMoved={(t) => { setMoving(null); report(t, null); }} />
      )}
      {menu && <Menu title={menu.title} items={menu.items} onClose={() => setMenu(null)} />}
    </div>
  );
}
