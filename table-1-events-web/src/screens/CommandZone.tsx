import { useEffect, useRef, useState } from "react";
import { Bar, Menu, Row, Section, type MenuItem } from "../components/kit";
import { cardMatches } from "../lib/librarySearch";
import { coverPrinting, normName, type Catalog } from "../lib/catalog";
import { ROLE_CHOOSE, ROLE_HINT, ROLE_LABEL, ROLE_TITLE, roleFits, zoneInDeck, zonePairs, zonePartnerHint, type ZoneDeckLine, type ZoneMate, type ZoneRole, type ZoneSlot } from "../lib/commandZone";
import { CardSearchBar, useCardSearch } from "./CardSearch";
import { CardArt, CardRow, type CardFinish } from "./Library";

/* The command zone's cards and its card picker (contract/command-zone-2026-10-27.md), on New deck and the deck screen. */

/** A card already in the deck, outside the command zone, with its name and printing. */
export interface ZoneDeckCard extends ZoneDeckLine { name: string; p: number | null }

const PROMPT: Record<ZoneRole, string> = {
  commander: "A legendary creature", partner: "A legendary creature or background", oathbreaker: "A planeswalker", signature: "An instant or sorcery",
};

/** Full screen over the page: the catalog by name (or Scryfall syntax), filtered to cards that can fill the slot. A
 *  click picks the card in its original paper printing. */
export function CommandZonePicker({ catalog, role, onPick, onClose, deck = [], onPickDeck, partnerOf }: {
  catalog: Catalog; role: ZoneRole; onPick: (cardId: string, oracle: number) => void; onClose: () => void;
  /** The deck's own cards: those that fit come first, and a click moves that copy in (a deck made before the command zone
   *  has its commander in the main deck). */
  deck?: ZoneDeckCard[]; onPickDeck?: (card: ZoneDeckCard) => void;
  /** The partner slot: the commander it partners, so only cards that can pair are offered. */
  partnerOf?: ZoneMate | null;
}) {
  // Partner with names its partner: search for it straight away.
  const [q, setQ] = useState(partnerOf?.pair?.startsWith("P:") ? partnerOf.pair.slice(2) : "");
  const found = useCardSearch(catalog, q);
  const mates = (typeLine: string, pair: string | null, name: string) =>
    role !== "partner" || !partnerOf || zonePairs(partnerOf, { typeLine, pair, name });
  const fromDeck = onPickDeck
    ? zoneInDeck(role, deck).filter((d) => mates(d.typeLine, d.pair ?? null, d.name) && (!q.trim() || cardMatches(q, d.name, d.typeLine)))
    : [];
  const hits = q.trim()
    ? (found?.result.hits ?? []).filter((i) => roleFits(role, catalog.oType[i]) && mates(catalog.oType[i], catalog.oPair[i], catalog.oName[i]))
    : [];
  const hint = partnerOf ? zonePartnerHint(partnerOf) : ROLE_HINT[role];
  const pick = (i: number) => {
    const p = found?.result.covers.get(i) ?? coverPrinting(catalog, i);
    onClose();
    onPick(catalog.pId[p], i);
  };
  return (
    <div className="fixed inset-0 z-50 bg-t1-bg flex flex-col gap-px" role="dialog" aria-modal="true" aria-label={ROLE_TITLE[role]}>
      <Bar title={ROLE_TITLE[role]} subtitle={hint}
           right={<button type="button" className="t1-label hover:text-t1-text" onClick={onClose}>Cancel</button>} />
      <CardSearchBar label="Card" value={q} onChange={setQ} placeholder={PROMPT[role]} autoFocus onSubmit={() => { if (hits[0] != null) pick(hits[0]); }} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px w-full max-w-[720px] mx-auto">
        {fromDeck.length > 0 && <Section title="In this deck" />}
        {fromDeck.map((d) => (
          <div key={`${d.board}|${d.cardId}|${d.finish}|${d.lang}`} className="h-[60px] shrink-0">
            <CardRow c={catalog} p={d.p} title={d.name} detail={d.typeLine} value="Move in" onClick={() => { onClose(); onPickDeck?.(d); }} />
          </div>
        ))}
        {fromDeck.length > 0 && hits.length > 0 && <Section title="All cards" />}
        {found?.query === q && normName(q).length >= 2 && !hits.length && <Row title={`No ${ROLE_TITLE[role].toLowerCase()} by that name`} />}
        {hits.map((i) => (
          <div key={i} className="h-[60px] shrink-0">
            <CardRow c={catalog} p={found?.result.covers.get(i) ?? coverPrinting(catalog, i)} title={catalog.oName[i]}
                     detail={`${catalog.oType[i]}${catalog.oCost[i] ? ` · ${catalog.oCost[i]}` : ""}`} onClick={() => pick(i)} />
          </div>
        ))}
      </div>
    </div>
  );
}

/** "Command zone" and its cards side by side: commander | partner or background, oathbreaker | signature spell. A filled
 *  card offers Open card / Change / Remove; an empty one opens the picker. */
export function CommandZoneCards({ catalog, slots, onChoose, onRemove, onOpen, commander }: {
  catalog: Catalog | null; slots: ZoneSlot[]; onChoose: (slot: ZoneSlot) => void; onRemove: (slot: ZoneSlot) => void;
  onOpen?: (slot: ZoneSlot) => void;
  /** The commander, so an empty partner slot names what it pairs with. */
  commander?: ZoneMate | null;
}) {
  const [menu, setMenu] = useState<{ title: string; items: MenuItem[] } | null>(null);
  const box = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(390);
  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const w = Math.max(0, Math.min(220, Math.floor((width - 48) / 2)));
  return (
    <>
      <Section title="Command zone" />
      <div ref={box} className="bg-t1-bg p-4 flex items-start gap-4 shrink-0">
        {slots.map((s, n) => {
          const p = s.cardId && catalog ? catalog.printingIndex.get(s.cardId) ?? null : null;
          const name = p != null && catalog ? catalog.oName[catalog.pOracle[p]] : null;
          const click = () => {
            if (s.cardId == null) return onChoose(s);
            setMenu({ title: name ?? ROLE_TITLE[s.role], items: [
              ...(onOpen ? [{ title: "Open card", onClick: () => onOpen(s) }] : []),
              { title: `Change ${ROLE_TITLE[s.role].toLowerCase()}`, onClick: () => onChoose(s) },
              { title: "Remove", onClick: () => onRemove(s) },
            ] });
          };
          return (
            <button key={`${s.role}-${n}`} type="button" onClick={click} className="flex flex-col gap-2 text-left" style={{ width: w }}
                    aria-label={s.cardId == null ? ROLE_CHOOSE[s.role] : `${ROLE_TITLE[s.role]}: ${name ?? ""}`}>
              <span className="t1-label">{ROLE_LABEL[s.role]}</span>
              {s.cardId != null && p != null && catalog ? (
                <CardArt c={catalog} p={p} width={w} alt={name ?? ""} finish={s.finish as CardFinish} />
              ) : (
                <span className="flex flex-col items-center justify-center gap-2 bg-t1-surface hover:bg-t1-surface-hover text-center p-3"
                      style={{ width: w, height: Math.round(w * 680 / 488), borderRadius: w * 0.0432 }}>
                  {s.cardId == null && <span className="text-[28px] leading-none">+</span>}
                  <span className="text-[13px]">{s.cardId == null ? ROLE_CHOOSE[s.role] : name ?? "Card not in local data yet"}</span>
                  {s.cardId == null && <span className="text-[11px] text-t1-muted">{s.role === "partner" && commander ? zonePartnerHint(commander) : ROLE_HINT[s.role]}</span>}
                </span>
              )}
            </button>
          );
        })}
      </div>
      {menu && <Menu title={menu.title} items={menu.items} onClose={() => setMenu(null)} />}
    </>
  );
}
