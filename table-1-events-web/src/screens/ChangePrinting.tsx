import { useEffect, useMemo, useState } from "react";
import { Bar, Field, Notice, Row, Section } from "../components/kit";
import { errorMessage } from "../lib/api";
import { RARITY_NAME } from "../lib/catalog";
import { applyOps, DEMO_USER, useCollection, type Finish, type Item } from "../lib/collection";
import { useBinders } from "../lib/binders";
import { pickPlace, printingChangeOps, printingPlaces } from "../lib/changePrinting";
import { loadDemoLists } from "../lib/libraryDemo";
import { boardTitle, editList, entriesOf, finishOf, langOf, useLists, type Board } from "../lib/lists";
import { printingMatches } from "../lib/librarySearch";
import { usdPrice, usdText, usePrices } from "../lib/prices";
import { capture, screen } from "../lib/telemetry";
import type { TradeLine } from "../lib/trades";
import { useSearchUsed } from "./Binders";
import { CardArt, CardRow, LibScreen, useCatalog, useLibrarySession } from "./Library";
import { LanguagePicker, LanguageRow } from "./Languages";
import { langForNew, languageChangeOps, languageName } from "../lib/languages";

/* Change printing (contract/change-printing-2026-10-18.md): every card line that names a printing can point some or
   all of its copies at another printing or finish, from this one screen: a deck or cube line, owned copies (from the
   collection or a binder) and a trade's gets. Wants keep their own picker (it also offers Any printing). Same screen
   as iOS ChangePrintingView. */

/** Where a printing change applies. */
export type PrintingTarget =
  /** A deck or cube line (one list_edit swap op, so the version history shows it). */
  | { kind: "list"; listId: string; cardId: string; board: Board; finish: Finish; lang: string }
  /** Owned copies. `place`: the binder id (or Unsorted) card detail was opened from; null = the collection. */
  | { kind: "owned"; item: Item; place: string | null }
  /** A get in a trade draft: the whole line moves; `apply` gets the new card id and finish. */
  | { kind: "trade"; line: TradeLine; apply: (cardId: string, finish: Finish) => void };

const FINISHES: Finish[] = ["nonfoil", "foil", "etched"];
const FINISH_LABEL: Record<Finish, string> = { nonfoil: "Non-foil", foil: "Foil", etched: "Etched" };

const targetCard = (t: PrintingTarget) => (t.kind === "owned" ? t.item.cardId : t.kind === "trade" ? t.line.card_id : t.cardId);
const targetFinish = (t: PrintingTarget): Finish => (t.kind === "owned" ? t.item.finish : t.kind === "trade" ? t.line.finish : t.finish);

/**
 * The one Change printing screen: the line as it is, where from (owned copies in several places), how many, then
 * every printing of the card with a button per finish. `screenName` sends the screen view when it isn't a route of its
 * own; `onChanged` gets an owned change's batch and a label, for Undo on the screen underneath.
 */
export function ChangePrintingScreen({ target, onClose, onChanged, screenName }: {
  target: PrintingTarget; onClose: () => void; onChanged?: (batchId: string, label: string) => void; screenName?: string;
}) {
  const { userId } = useLibrarySession();
  const col = useCollection(userId);
  const binders = useBinders(userId);
  const lists = useLists(userId, userId === DEMO_USER ? loadDemoLists : undefined);
  const { catalog, error: catError } = useCatalog();
  const [count, setCount] = useState(0);
  const [place, setPlace] = useState<string | null>(null);
  const [pickingLang, setPickingLang] = useState(false);
  const [q, setQ] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useSearchUsed(q, "change_printing");
  useEffect(() => {
    if (screenName) screen(screenName);
  }, [screenName]);

  const cardId = targetCard(target);
  const finish = targetFinish(target);
  /** The copies' condition prices each printing (a deck or cube line has none: near mint). */
  const condition = target.kind === "owned" ? target.item.condition : target.kind === "list" ? "NM" : target.line.condition;
  const p0 = catalog?.printingIndex.get(cardId);
  const oi = catalog && p0 != null ? catalog.pOracle[p0] : -1;
  const printings = useMemo(() => {
    if (!catalog || oi < 0) return [];
    const orig = catalog.oOriginal[oi];
    return Array.from({ length: catalog.pCount[oi] }, (_, i) => catalog.pFirst[oi] + i).sort((a, b) => Number(b === orig) - Number(a === orig));
  }, [catalog, oi]);
  usePrices(useMemo(() => (catalog ? printings.map((p) => catalog.pId[p]) : null), [catalog, printings]));

  // Owned copies: the item as it is now, and the places its copies sit.
  void binders.version;
  const live = target.kind === "owned" ? col.items.get(target.item.k) ?? target.item : null;
  const places = live ? printingPlaces(live) : [];
  const selected = target.kind === "owned" ? pickPlace(places, place, target.place) : null;
  const list = target.kind === "list" ? lists.lists.find((l) => l.id === target.listId) : undefined;
  const have = target.kind === "list"
    ? (list ? entriesOf(list).find((e) => e.cardId === cardId && e.board === target.board && finishOf(e) === finish && langOf(e) === target.lang)?.qty ?? 0 : 0)
    : target.kind === "owned" ? places.find((p) => p.place === selected)?.qty ?? 0
    : target.line.qty;
  const n = Math.min(Math.max(count || have, 1), Math.max(have, 1));
  const splits = target.kind !== "trade";

  if (!catalog) {
    return (
      <LibScreen>
        <Bar title="Change printing" onBack={onClose} />
        {catError ? <Notice tone="error">{catError}</Notice> : <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>}
      </LibScreen>
    );
  }
  const name = oi >= 0 ? catalog.oName[oi] : undefined;
  const label = (p: number) => `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`;
  const shown = q ? printings.filter((p) => printingMatches(q, catalog.pSet[p], catalog.pCn[p], catalog.pReleased[p] ?? "")) : printings;
  const currentDetail = [p0 != null ? label(p0) : null, FINISH_LABEL[finish],
    ...(target.kind === "list" ? [target.lang === "en" ? null : target.lang.toUpperCase(), list ? boardTitle(list.kind, target.board) : null]
      : target.kind === "owned" ? [target.item.condition, target.item.lang === "en" ? null : target.item.lang.toUpperCase()]
      : [target.line.condition])].filter(Boolean).join(" · ");

  const pick = async (p: number, toFinish: Finish) => {
    const props = { where: target.kind === "list" ? "list" : target.kind === "trade" ? "trade" : target.place == null ? "collection" : "binder",
                    copies: n, finish_only: catalog.pId[p] === cardId };
    if (target.kind === "list") {
      // A non-English printing is its own language; another English printing keeps the line's.
      void editList(target.listId, [{ card_id: cardId, board: target.board, finish, lang: target.lang, to_card_id: catalog.pId[p], to_finish: toFinish,
                                      to_lang: langForNew(catalog.pLang[p], target.lang), qty: n, swap: true }]);
      capture("printing_changed", props);
      return onClose();
    }
    if (target.kind === "trade") {
      target.apply(catalog.pId[p], toFinish);
      capture("printing_changed", props);
      return onClose();
    }
    const ops = live && printingChangeOps(live, selected, catalog.pId[p], toFinish, catalog.pLang[p], n);
    if (!ops) return;
    setBusy(true);
    setError(null);
    try {
      const res = await applyOps(ops);
      capture("printing_changed", props);
      onChanged?.(res.batch_id, `Changed ${n} to ${label(p)}${toFinish === "nonfoil" ? "" : ` ${FINISH_LABEL[toFinish]}`}`);
      onClose();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  /** Owned copies: the same printing and finish in another language, `n` of them from the chosen place. */
  const changeLanguage = async (lang: string) => {
    if (!live) return;
    const ops = languageChangeOps(live, printingPlaces(live), lang, n, selected);
    if (!ops) return;
    setBusy(true);
    setError(null);
    try {
      const res = await applyOps(ops);
      capture("language_changed", { where: target.kind === "owned" && target.place != null ? "binder" : "collection", copies: n });
      onChanged?.(res.batch_id, `Moved ${n} to ${languageName(lang)}`);
      onClose();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <LibScreen>
      <Bar title="Change printing" subtitle={name} onBack={onClose} />
      {error && <Notice tone="error">{error}</Notice>}
      {have === 0 ? <Notice tone="info">This line has no copies left.</Notice> : (
        <>
          {printings.length > 8 && <Field label="Set, number or year" value={q} onChange={setQ} />}
          <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
            <div className="h-[60px] shrink-0">
              <CardRow c={catalog} p={p0 ?? null} title={name ?? "Card"} detail={currentDetail} value={have} />
            </div>
            {places.length > 1 && (
              <>
                <Section title="From" />
                {places.map((pl) => (
                  <Row key={pl.place} title={pl.name} detail={`${pl.qty} here`} value={pl.place === selected ? "From here" : undefined} accentValue
                       onClick={() => { setPlace(pl.place); setCount(pl.qty); }} />
                ))}
              </>
            )}
            {have > 1 && splits && (
              <div className="bg-t1-surface flex items-stretch gap-px h-[52px] shrink-0">
                <span className="flex-1 px-4 flex items-center t1-label">Change {n} of {have}</span>
                <button type="button" aria-label="Fewer" className="w-14 bg-t1-surface-hover text-[20px]" onClick={() => setCount(Math.max(1, n - 1))}>−</button>
                <button type="button" aria-label="More" className="w-14 bg-t1-surface-hover text-[20px]" onClick={() => setCount(Math.min(have, n + 1))}>+</button>
              </div>
            )}
            {live && <LanguageRow lang={live.lang} onClick={() => setPickingLang(true)} />}
            <Section title={q ? `Change to · ${shown.length} of ${printings.length}` : `Change to · ${printings.length}`} />
            {q && !shown.length && <Row title="No printings match" />}
            {shown.map((p) => {
              const finishes = FINISHES.filter((f) => catalog.pFinishes[p].includes(f[0]));
              const price = usdPrice(catalog.pId[p], finishes[0] ?? "nonfoil", condition);
              const detail = [RARITY_NAME[catalog.pRarity[p]], catalog.pReleased[p]?.slice(0, 4), p === catalog.oOriginal[oi] ? "Original" : null,
                              catalog.pLang[p] !== "en" ? catalog.pLang[p].toUpperCase() : null, price != null ? usdText(price) : null].filter(Boolean).join(" · ");
              return (
                <div key={p} className="bg-t1-surface flex items-stretch gap-px shrink-0">
                  <div className="flex-1 min-w-0 px-4 py-[5px] flex items-center gap-3">
                    <CardArt c={catalog} p={p} width={36} />
                    <span className="min-w-0 flex flex-col gap-0.5">
                      <span className="text-[13px] truncate">{label(p)}</span>
                      <span className="t1-label truncate">{detail}</span>
                    </span>
                  </div>
                  {finishes.map((f) => {
                    const same = catalog.pId[p] === cardId && f === finish;
                    return (
                      <button key={f} type="button" disabled={same || busy}
                              className="px-3 bg-t1-surface-hover t1-label hover:text-t1-text disabled:text-t1-disabled"
                              onClick={() => void pick(p, f)}>{same ? "Current" : FINISH_LABEL[f]}</button>
                    );
                  })}
                </div>
              );
            })}
          </div>
        </>
      )}
      {pickingLang && live && (
        <LanguagePicker current={live.lang} subtitle={name ?? undefined} onClose={() => setPickingLang(false)} onPick={(l) => void changeLanguage(l)} />
      )}
    </LibScreen>
  );
}
