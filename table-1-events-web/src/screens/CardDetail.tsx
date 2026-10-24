import { useEffect, useLayoutEffect, useMemo, useState, type ReactNode } from "react";
import { BackArrow, Dialog, Menu, Notice, Row, Section, type MenuItem } from "../components/kit";
import { ZoomImage } from "../components/ZoomImage";
import { capture } from "../lib/telemetry";
import { errorMessage } from "../lib/api";
import { RARITY_NAME, basicCardIds, cardImageUrl, formatName, oracleIndexById, type Catalog } from "../lib/catalog";
import { applyOps, fetchHistory, undoBatch, useCollection, DEMO_USER, type CollectionOp, type Condition, type Finish, type HistoryEntry } from "../lib/collection";
import { conditionPriceText, usdPrice, usdText, usePrices } from "../lib/prices";
import { applyWants, binderById, forTrade, placementText, useBinders } from "../lib/binders";
import { printingPlaces } from "../lib/changePrinting";
import { BOARD_ORDER, boardTitle, entriesOf, finishOf, sectionsFor, editList, useLists, type Board, type CardList, type ListOp } from "../lib/lists";
import { saveTrade, useTrades, type TradeLine } from "../lib/trades";
import { LANGUAGES, languageName, storedAddLang } from "../lib/languages";
import { cardAddDetail, copiesOf, listAddOps, toCollectionOps, type AddOp } from "../lib/listToCollection";
import { isHero, scopeOf, toggleHero, HERO_LIMIT } from "../lib/heroes";
import { loadDemoLists } from "../lib/libraryDemo";
import {
  editOps, factsOf, finishesOf, freshVersion, mainVersion, orderedVersions, repoint, shared, showsFinish, stepOp, versionId, versionKey,
  type CardAttribute, type CardVersion, type PrintingFacts,
} from "../lib/cardDetail";
import { CONDITIONS, CardArt, LibScreen, SignedOut, useAddCondition, useCatalog, useLibraryHeroes, useLibrarySession } from "./Library";
import { MoveCopies, UNSORTED, WantCardRow } from "./Binders";

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
  const [info, setInfo] = useState(false);
  const [back, setBack] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [last, setLast] = useState<Undo | null>(null);
  const [picker, setPicker] = useState<CardAttribute | null>(null);
  const [menu, setMenu] = useState<{ title: string; items: MenuItem[] } | null>(null);
  const [confirm, setConfirm] = useState<{ title: string; run: () => void } | null>(null);
  const [addTo, setAddTo] = useState<CardVersion | null>(null);
  const [zoom, setZoom] = useState<number | null>(null);
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
        .map((e) => ({ cardId: e.cardId, finish: finishOf(e), condition: "NM" as Condition, lang: "en", board: e.board, qty: e.qty })) : [];
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
    if (selected && !versions.some((v) => versionId(v) === selected)) setSelected(null);
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
  const chosen = versions.find((v) => versionId(v) === selected) ?? null;
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
          ops.push({ card_id: v.cardId, board, finish: v.finish, delta: -n }, { card_id: v.cardId, board: toBoard, finish: v.finish, delta: n });
          reverse.push({ card_id: v.cardId, board: toBoard, finish: v.finish, delta: -n }, { card_id: v.cardId, board, finish: v.finish, delta: n });
        } else {
          ops.push({ card_id: v.cardId, board, finish: v.finish, to_card_id: to.cardId, to_finish: to.finish, qty: n, swap: true });
          reverse.push({ card_id: to.cardId, board, finish: to.finish, to_card_id: v.cardId, to_finish: v.finish, qty: n, swap: true });
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

  const step = (delta: number) => {
    const v = versions.length ? mainVersion(versions)! : current;
    const label = `${delta > 0 ? "Added" : "Removed"} 1 ${setLabel(v.cardId)}`;
    const props = { scope: scopeName, delta };
    // At 0 the screen keeps this version, so + puts it back.
    if (delta < 0 && v.qty <= 1) setDraft({ ...v, qty: 0 });
    if (listId) {
      const board = v.board ?? "main";
      void listEdit([{ card_id: v.cardId, board, finish: v.finish, delta }], [{ card_id: v.cardId, board, finish: v.finish, delta: -delta }],
                    label, () => capture("card_stepped", props));
      return;
    }
    void write([stepOp(v, delta, binderId)], label, () => capture("card_stepped", props));
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

  const price = usdText(usdPrice(current.cardId, current.finish, current.condition));
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
  if (!list) {
    const lang = shared(shown, (v) => v.lang);
    cells.push({ a: "language", value: lang?.toUpperCase() ?? "Mix", opens: printingShown ? printingShown.lang === "en" : true });
    cells.push({ a: "condition", value: shared(shown, (v) => v.condition) ?? "Mix", opens: true });
  }
  if (showsFinish(shown, factsById)) {
    const f = shared(shown, (v) => v.finish);
    cells.push({ a: "finish", value: f ? finishCode(f) : "Mix", opens: printingShown ? finishesOf(printingShown).length > 1 : true });
  }
  if (list) cells.push({ a: "section", value: (() => { const b = shared(shown, (v) => v.board ?? "main"); return b ? sectionCode(b) : "Mix"; })(), opens: true });

  const count = inView.reduce((n, v) => n + v.qty, 0);
  const locked = !!chosen;
  const p = indexById.get(current.cardId);
  const flips = p != null && catalog.pFaces[p] > 1;

  // The card area: one image as large as fits, or a two-column grid of versions.
  const tileW = Math.floor((Math.min(area.w - 64, 376 * area.w / 440) - 1) / 2);
  const bigW = Math.floor(Math.min(area.w - 64, (area.h - 32 - (flips ? 44 : 0)) * ASPECT));

  return (
    <LibScreen>
      <CardBar name={name} price={price} onBack={onBack} info={info}
               onAdd={isSearch ? undefined : () => setAddTo(current)}
               onInfo={() => { setInfo(!info); if (!info) capture("card_info_opened", { scope: scopeName }); }} />
      {(error || col.error) && <Notice tone="error">{error ?? col.error}</Notice>}
      {info ? (
        <>
          {status}
          <CardInfo catalog={catalog} oi={oi} version={current} p={p ?? null} printings={oldest} list={list} context={context}
                    lists={lists.lists} report={report} onList={onList} />
        </>
      ) : (
        <>
          <div ref={areaRef} className="flex-1 min-h-0 bg-t1-bg overflow-y-auto">
            {area.w > 0 && (versions.length > 1 ? (
              <div className="min-h-full flex items-center justify-center py-4">
                <div className="grid gap-px" style={{ gridTemplateColumns: `${tileW}px ${tileW}px` }}>
                  {versions.map((v) => {
                    const on = versionId(v) === selected;
                    const vp = indexById.get(v.cardId) ?? null;
                    return (
                      <button key={versionId(v)} type="button" aria-pressed={on}
                              aria-label={[setLabel(v.cardId), FINISH_LABEL[v.finish], v.board && list ? boardTitle(list.kind, v.board) : null,
                                           list ? null : v.condition, String(v.qty)].filter(Boolean).join(", ")}
                              onClick={() => { setSelected(on ? null : versionId(v)); if (!on) capture("card_version_selected", { versions: versions.length }); }}
                              className={`relative block ${on ? "outline outline-1 outline-t1-accent" : ""}`}>
                        <CardArt c={catalog} p={vp} width={tileW} finish={v.finish} />
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
            <button type="button" onClick={() => setAddTo(current)}
                    className="shrink-0 h-[88px] lg:h-[64px] bg-t1-surface hover:bg-t1-surface-hover pt-6 lg:pt-0 flex lg:items-center justify-center text-[15px] font-semibold uppercase tracking-[4px] pb-[env(safe-area-inset-bottom)]">
              Add to
            </button>
          ) : (
            <div className="shrink-0 flex gap-px">
              <StepCell label="Remove one" enabled={!locked && !busy && count > 0} onClick={() => step(-1)}>
                <MinusIcon />
              </StepCell>
              <div className={`flex-1 h-[88px] lg:h-[64px] bg-t1-surface pt-6 lg:pt-0 flex lg:items-center justify-center text-[15px] font-semibold tracking-[4px] tabular-nums ${locked ? "text-t1-disabled" : ""}`}
                   aria-label={`${count} copies`}>{count}</div>
              <StepCell label="Add one" enabled={!locked && !busy} onClick={() => step(1)}>
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
                          : [...(list && entriesOf(list).some((e) => e.board === "commander") ? ["commander" as Board] : []), ...sectionsFor(list?.kind ?? "deck")]
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
        <AddToSheet catalog={catalog} oi={oi} version={addTo} p={indexById.get(addTo.cardId) ?? null} lists={lists.lists} scope={scopeName}
                    onClose={() => setAddTo(null)} onDone={(label, u) => { setAddTo(null); report(label, u); }} />
      )}
      {zoom != null && (
        <ZoomImage src={cardImageUrl(catalog, zoom, "large", back && catalog.pFaces[zoom] > 1)} alt={name} title={name}
                   subtitle={setLabel(catalog.pId[zoom])} onClose={() => setZoom(null)} />
      )}
    </LibScreen>
  );
}

/* ── pieces ───────────────────────────────────────────────────────────── */

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
function StepCell({ label, enabled, onClick, children }: { label: string; enabled: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <button type="button" aria-label={label} aria-disabled={!enabled} onClick={() => { if (enabled) onClick(); }}
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
 *  Drilldown). Adds one of the version on screen; condition and language go with collection, binder and trade adds. */
function AddToSheet({ catalog, oi, version, p, lists, scope, onClose, onDone }: {
  catalog: Catalog; oi: number; version: CardVersion; p: number | null; lists: CardList[]; scope: string;
  onClose: () => void; onDone: (label: string, undo: Undo | null) => void;
}) {
  const [step, setStep] = useState<Step>({ k: "root" });
  const [error, setError] = useState<string | null>(null);
  const trades = useTrades();
  const { userId } = useLibrarySession();
  const col = useCollection(userId);
  const b = useBinders(userId);
  const name = p == null ? catalog.oName[oi] : `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`;
  const owned = (col.items.get(versionKey(version))?.qty ?? 0) > 0;
  const finishes = p == null ? [] : finishesOf(factsOf(catalog, p));

  const finish = (destination: string, label: string, undo: Undo | null) => {
    capture("card_added_to", { destination, scope });
    onDone(label, undo);
  };
  const fail = (e: unknown) => setError(errorMessage(e));

  const toCollection = async (binderId: string | null, place: string) => {
    try {
      const res = await applyOps([stepOp(version, 1, binderId)]);
      const label = `Added 1 ${name} to ${place}`;
      finish(binderId ? "binder" : "collection", label, { label, run: () => undoBatch(res.batch_id) });
    } catch (e) { fail(e); }
  };
  const toList = async (id: string, board: Board) => {
    const l = lists.find((x) => x.id === id);
    if (!l || p == null) return;
    // A finish the printing lacks is saved in one it has (contract/lists-2026-10-15.md).
    const f = finishes.includes(version.finish) ? version.finish : finishes[0] ?? "nonfoil";
    try {
      await editList(id, [{ card_id: version.cardId, board, finish: f, delta: 1 }]);
      const label = `Added 1 ${name} to ${l.name} · ${boardTitle(l.kind, board)}`;
      finish(l.kind, label, { label, run: () => editList(id, [{ card_id: version.cardId, board, finish: f, delta: -1 }]) });
    } catch (e) { fail(e); }
  };
  const want = async (how: string) => {
    try {
      await applyWants([{ oracle_id: catalog.oId[oi], card_id: how === "any" ? null : version.cardId, finish: how === "finish" ? version.finish : null, delta: 1 }],
                       "want_added", { any_printing: how === "any", finish: how === "finish", has_max: false, from: "card" });
      finish("want", `Wanted 1 ${how === "any" ? catalog.oName[oi] : name}`, null);
    } catch (e) { fail(e); }
  };
  const toTrade = async (id: string | null, give: boolean) => {
    const t = id ? trades.trades.find((x) => x.id === id) ?? null : null;
    const line: TradeLine = { card_id: version.cardId, finish: version.finish, condition: version.condition, lang: version.lang, qty: 1,
                              ...(give && forTrade(versionKey(version)).binderId ? { binder_id: forTrade(versionKey(version)).binderId } : {}) };
    const put = (lines: TradeLine[]) => {
      const i = lines.findIndex((l) => l.card_id === line.card_id && l.finish === line.finish && l.condition === line.condition && l.lang === line.lang);
      return i >= 0 ? lines.map((l, j) => (j === i ? { ...l, qty: l.qty + 1 } : l)) : [...lines, line];
    };
    try {
      const saved = await saveTrade(t, t?.partner ?? null, give ? put(t?.gives ?? []) : t?.gives ?? [], give ? t?.gets ?? [] : put(t?.gets ?? []));
      finish("trade", `${give ? "Giving" : "Getting"} 1 ${name} in the trade${saved.partner ? ` with ${saved.partner}` : ""}`, null);
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
function CardInfo({ catalog, oi, version, p, printings, list, context, lists, report, onList }: {
  catalog: Catalog; oi: number; version: CardVersion; p: number | null; printings: number[]; list?: CardList; context?: CardContext;
  lists: CardList[]; report: (label: string, undo: Undo | null) => void; onList?: (id: string) => void;
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
    for (const it of col.items.values()) if (only.has(it.cardId)) ownedBy.set(`${it.cardId}|${it.finish}`, (ownedBy.get(`${it.cardId}|${it.finish}`) ?? 0) + it.qty);
    const entries = entriesOf(list);
    const basics = basicCardIds(catalog);
    const missing = listAddOps(entries, list.kind, ownedBy, "missing", true, only, basics);
    const all = listAddOps(entries, list.kind, ownedBy, "all", true, only);
    const m = copiesOf(missing), a = copiesOf(all);
    const add = async (ops: AddOp[], mode: string) => {
      const n = copiesOf(ops);
      setBusy(true);
      try {
        const res = await applyOps(toCollectionOps(ops, (id) => { const x = catalog.printingIndex.get(id); return x == null ? undefined : catalog.pLang[x]; },
                                                   addCondition, storedAddLang()));
        const text = `Added ${n} ${catalog.oName[oi]} to your collection`;
        report(text, { label: text, run: () => undoBatch(res.batch_id) });
        capture("list_added_to_collection", { kind: list.kind, mode, sideboard: true, copies: n, lines: ops.length, from: "card" });
      } catch (e) { report(errorMessage(e), null); } finally { setBusy(false); }
    };
    const items: MenuItem[] = [
      ...(m > 0 ? [{ title: `Add the ${m} missing`, detail: `As listed here · ${addCondition}`, onClick: () => void add(missing, "missing") }] : []),
      ...(a > 0 && a !== m ? [{ title: `Add all ${a}`, detail: `Every copy listed here · ${addCondition}`, onClick: () => void add(all, "all") }] : []),
      ...lines.slice(0, 4).map((e) => ({
        title: `Add 1 ${label(e.cardId)}${finishOf(e) === "nonfoil" ? "" : ` · ${FINISH_LABEL[finishOf(e)]}`}`, detail: boardTitle(list.kind, e.board),
        onClick: () => void add([{ card_id: e.cardId, finish: finishOf(e), delta: 1 }], "one"),
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
      {row("Price", conditionPriceText(usdPrice(version.cardId, version.finish), version.condition) ?? "—")}
      {row("Card type", details?.type ?? catalog.oType[oi])}
      {catalog.oCost[oi] && row("Mana cost", catalog.oCost[oi])}
      {row("Rarity", details?.rarity ?? (p != null ? RARITY_NAME[catalog.pRarity[p]]?.toLowerCase() : null) ?? "—")}
      {row("Artist", details?.artist ?? "—")}
      {p != null && row("Printing", [label(version.cardId), catalog.pLang[p] === "en" ? null : languageName(catalog.pLang[p])].filter(Boolean).join(" · "))}
      {listAdd}
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
