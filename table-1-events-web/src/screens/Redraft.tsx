import { useEffect, useState } from "react";
import { Bar, Menu, Notice, Row, Screen, SwitchRow } from "../components/kit";
import { errorMessage } from "../lib/api";
import { FINISH_LETTER, coverPrinting, normName } from "../lib/catalog";
import { usdText } from "../lib/prices";
import { redraftAdd, redraftDetail, redraftList, redraftPrinting, redraftRemove, type RedraftCard, type RedraftPile } from "../lib/redraft";
import { capture, screen as captureScreen } from "../lib/telemetry";
import { CardSearchBar, useCardSearch } from "./CardSearch";
import { CardRow, useCatalog } from "./Library";

/* The redraft pile for a finished set draft (contract/event-night-2026-10-16.md § 6): anyone in the event adds cards,
   most valuable first, and it stays with the event. Same as iOS RedraftView and Android RedraftScreen; on the web cards
   are added by search (in the drafted set's printing when the card is in it). */

export function RedraftScreen({ eventId, setCode, onBack }: { eventId: string; setCode: string | null; onBack: () => void }) {
  const { catalog } = useCatalog();
  const [pile, setPile] = useState<RedraftPile | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [menuFor, setMenuFor] = useState<RedraftCard | null>(null);
  useEffect(() => {
    captureScreen("redraft");
    redraftList(eventId).then(setPile, (e) => setError(errorMessage(e)));
  }, [eventId]);
  const add = async (cardId: string, finish: string) => {
    try {
      setPile(await redraftAdd(eventId, [{ card_id: cardId, finish }]));
      setError(null);
      capture("redraft_cards_added", { cards: 1, exact: true });
    } catch (e) {
      setError(errorMessage(e));
    }
  };
  const remove = async (c: RedraftCard) => {
    try {
      setPile(await redraftRemove(c.id));
      capture("redraft_card_removed");
    } catch (e) {
      setError(errorMessage(e));
    }
  };
  const p = pile;
  return (
    <Screen>
      <Bar title="Redraft" subtitle={p && p.count > 0 ? `${p.count} ${p.count === 1 ? "card" : "cards"} · ${usdText(p.total_usd) ?? ""}` : undefined} onBack={onBack}
           right={<button type="button" onClick={() => setAdding(true)} className="t1-label hover:text-t1-text px-2 py-1 -my-1">Add</button>} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {error && <Notice tone="error">{error}</Notice>}
        <Row title="Add cards" detail="Search the cards going into the redraft" onClick={() => setAdding(true)} />
        {!p && !error && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {p?.cards.length === 0 && (
          <Notice tone="info">Add the cards going into the redraft. They line up most valuable first so the table can see what's in the pile.</Notice>
        )}
        {catalog && p?.cards.map((c, i) => (
          <div key={c.id} className="h-[60px] shrink-0">
            <CardRow c={catalog} p={catalog.printingIndex.get(c.card_id) ?? null} title={`${i + 1}. ${c.name}`} detail={redraftDetail(c)}
                     finish={c.finish} value={usdText(c.usd) ?? "–"} onClick={() => setMenuFor(c)} />
          </div>
        ))}
      </div>
      {menuFor && <Menu title={menuFor.name} onClose={() => setMenuFor(null)} items={[{ title: "Remove from the pile", onClick: () => void remove(menuFor) }]} />}
      {adding && catalog && <RedraftAdd setCode={setCode} onAdd={add} onClose={() => setAdding(false)} />}
    </Screen>
  );
}

/** Full screen: search the catalog; a click adds one copy (the drafted set's printing when the card is in it). */
function RedraftAdd({ setCode, onAdd, onClose }: { setCode: string | null; onAdd: (cardId: string, finish: string) => Promise<void>; onClose: () => void }) {
  const { catalog } = useCatalog();
  const [q, setQ] = useState("");
  const [foil, setFoil] = useState(false);
  const [added, setAdded] = useState<string[]>([]);
  const found = useCardSearch(catalog, q, 30);
  if (!catalog) return null;
  const hits = q.trim() ? found?.result.hits ?? [] : [];
  const pick = (i: number) => {
    const p = redraftPrinting(catalog, i, setCode, found?.result.covers.get(i) ?? coverPrinting(catalog, i));
    const finishes = [...(catalog.pFinishes[p] ?? "n")].map((l) => FINISH_LETTER[l]).filter(Boolean);
    const finish = foil && finishes.includes("foil") ? "foil" : finishes.includes("nonfoil") ? "nonfoil" : finishes[0] ?? "nonfoil";
    void onAdd(catalog.pId[p], finish).then(() => setAdded((a) => [catalog.oName[i], ...a].slice(0, 5)));
    setQ("");
  };
  return (
    <div className="fixed inset-0 z-50 bg-t1-bg flex flex-col gap-px" role="dialog" aria-modal="true" aria-label="Add to the redraft">
      <Bar title="Add to the redraft" subtitle={setCode ? `${setCode.toUpperCase()} printings first` : undefined}
           right={<button type="button" className="t1-label hover:text-t1-text" onClick={onClose}>Done</button>} />
      <CardSearchBar label="Card" value={q} onChange={setQ} autoFocus onSubmit={() => { if (hits[0] != null) pick(hits[0]); }} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px w-full max-w-[720px] mx-auto">
        <SwitchRow label="Foil" detail="Adds the foil when the printing has one" on={foil} onChange={setFoil} />
        {added.length > 0 && <Notice tone="info">Added {added.join(", ")}.</Notice>}
        {found?.query === q && normName(q).length >= 2 && !hits.length && <Row title="No card by that name" />}
        {hits.map((i) => {
          const p = redraftPrinting(catalog, i, setCode, found?.result.covers.get(i) ?? coverPrinting(catalog, i));
          return (
            <div key={i} className="h-[60px] shrink-0">
              <CardRow c={catalog} p={p} title={catalog.oName[i]} detail={`${catalog.pSet[p].toUpperCase()} ${catalog.pCn[p]}`} value="Add" onClick={() => pick(i)} />
            </div>
          );
        })}
      </div>
    </div>
  );
}
