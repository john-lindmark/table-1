import { useState } from "react";
import { Bar, Menu, Row, Section, type MenuItem } from "../components/kit";
import { coverPrinting, normName, type Catalog } from "../lib/catalog";
import { ROLE_CHOOSE, ROLE_HINT, ROLE_TITLE, roleFits, type ZoneRole, type ZoneSlot } from "../lib/commandZone";
import { CardSearchBar, useCardSearch } from "./CardSearch";
import { CardRow } from "./Library";

/* The command zone's rows and its card picker (contract/command-zone-2026-10-27.md), on New deck and the deck screen. */

const PROMPT: Record<ZoneRole, string> = {
  commander: "A legendary creature", partner: "A legendary creature or background", oathbreaker: "A planeswalker", signature: "An instant or sorcery",
};

/** Full screen over the page: the catalog by name (or Scryfall syntax), filtered to cards that can fill the slot. A
 *  click picks the card in its original paper printing. */
export function CommandZonePicker({ catalog, role, onPick, onClose }: {
  catalog: Catalog; role: ZoneRole; onPick: (cardId: string, oracle: number) => void; onClose: () => void;
}) {
  const [q, setQ] = useState("");
  const found = useCardSearch(catalog, q);
  const hits = q.trim() ? (found?.result.hits ?? []).filter((i) => roleFits(role, catalog.oType[i])) : [];
  const pick = (i: number) => {
    const p = found?.result.covers.get(i) ?? coverPrinting(catalog, i);
    onClose();
    onPick(catalog.pId[p], i);
  };
  return (
    <div className="fixed inset-0 z-50 bg-t1-bg flex flex-col gap-px" role="dialog" aria-modal="true" aria-label={ROLE_TITLE[role]}>
      <Bar title={ROLE_TITLE[role]} subtitle={ROLE_HINT[role]}
           right={<button type="button" className="t1-label hover:text-t1-text" onClick={onClose}>Cancel</button>} />
      <CardSearchBar label="Card" value={q} onChange={setQ} placeholder={PROMPT[role]} autoFocus onSubmit={() => { if (hits[0] != null) pick(hits[0]); }} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px w-full max-w-[720px] mx-auto">
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

/** "Command zone" and one row per slot: the card (click for Change / Remove) or the empty slot (click to choose). */
export function CommandZoneRows({ catalog, slots, onChoose, onRemove, onOpen }: {
  catalog: Catalog | null; slots: ZoneSlot[]; onChoose: (slot: ZoneSlot) => void; onRemove: (slot: ZoneSlot) => void;
  onOpen?: (slot: ZoneSlot) => void;
}) {
  const [menu, setMenu] = useState<{ title: string; items: MenuItem[] } | null>(null);
  return (
    <>
      <Section title="Command zone" />
      {slots.map((s, n) => {
        const p = s.cardId && catalog ? catalog.printingIndex.get(s.cardId) ?? null : null;
        if (s.cardId == null || !catalog) {
          return <Row key={`${s.role}-${n}`} title={ROLE_CHOOSE[s.role]} detail={ROLE_HINT[s.role]} value="Choose" onClick={() => onChoose(s)} />;
        }
        const name = p != null ? catalog.oName[catalog.pOracle[p]] : "Card not in local data yet";
        const items: MenuItem[] = [
          ...(onOpen ? [{ title: "Open card", onClick: () => onOpen(s) }] : []),
          { title: `Change ${ROLE_TITLE[s.role].toLowerCase()}`, onClick: () => onChoose(s) },
          { title: "Remove", onClick: () => onRemove(s) },
        ];
        return (
          <div key={`${s.role}-${n}`} className="h-[60px] shrink-0">
            <CardRow c={catalog} p={p} title={name} detail={ROLE_TITLE[s.role]} value="Change" onClick={() => setMenu({ title: name, items })} />
          </div>
        );
      })}
      {menu && <Menu title={menu.title} items={menu.items} onClose={() => setMenu(null)} />}
    </>
  );
}
