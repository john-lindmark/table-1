import { useMemo, useState } from "react";
import { Bar, GhostAction, Notice, Row, Section, Segmented, SwitchRow, useEscape } from "../components/kit";
import { errorMessage } from "../lib/api";
import { basicCardIds, type Catalog } from "../lib/catalog";
import { applyOps, undoBatch } from "../lib/collection";
import { copiesOf, listAddOps, toCollectionOps, type AddMode } from "../lib/listToCollection";
import { entriesOf, type CardList } from "../lib/lists";
import { capture } from "../lib/telemetry";
import { CONDITIONS, CardRow, useAddCondition } from "./Library";

const plural = (n: number) => `${n} ${n === 1 ? "card" : "cards"}`;

/** Add to collection from a deck or cube (contract/list-to-collection-2026-10-22.md): what's missing or every card,
    sideboard or not, in the picked condition and the listed printing's language, as one undoable batch. */
export function ListToCollectionScreen({ list, catalog, owned, onClose }: {
  list: CardList; catalog: Catalog; owned: Map<string, number>; onClose: () => void;
}) {
  const [mode, setMode] = useState<AddMode>("missing");
  const [sideboard, setSideboard] = useState(true);
  const [condition, setCondition] = useAddCondition();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<{ batch: string; copies: number } | null>(null);
  useEscape(onClose);

  const entries = entriesOf(list);
  const missing = useMemo(() => listAddOps(entries, list.kind, owned, "missing", sideboard, undefined, basicCardIds(catalog)),
                          [entries, list.kind, owned, sideboard, catalog]);
  const all = useMemo(() => listAddOps(entries, list.kind, owned, "all", sideboard), [entries, list.kind, sideboard]);
  const ops = mode === "missing" ? missing : all;
  const copies = copiesOf(ops);
  const side = entries.filter((e) => e.board === "side").reduce((n, e) => n + e.qty, 0);

  const add = async () => {
    if (!ops.length) return;
    if (ops.length > 5000) { setError("That's more than 5,000 different printings at once. Add the deck in parts."); return; }
    setBusy(true);
    setError(null);
    try {
      const pLang = (id: string) => { const p = catalog.printingIndex.get(id); return p == null ? undefined : catalog.pLang[p]; };
      const res = await applyOps(toCollectionOps(ops, pLang, condition), "import");
      setDone({ batch: res.batch_id, copies });
      capture("list_added_to_collection", { kind: list.kind, mode, sideboard, copies, lines: ops.length, from: "list" });
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  const undo = async () => {
    if (!done) return;
    setBusy(true);
    try {
      await undoBatch(done.batch);
      setDone(null);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 bg-t1-bg text-t1-text flex flex-col gap-px" role="dialog" aria-modal="true" aria-label={`Add ${list.name} to your collection`}>
      <Bar title="Add to collection" subtitle={list.name} onBack={onClose} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px lg:w-[960px] lg:max-w-full lg:mx-auto">
        {error && <Notice tone="error">{error}</Notice>}
        {done && <>
          <Notice tone="info">Added {plural(done.copies)} to your collection.</Notice>
          <Row title={busy ? "Undoing…" : "Undo"} detail="Takes those copies out again" onClick={() => { if (!busy) void undo(); }} />
        </>}
        <Segmented options={[{ value: "missing", label: `Missing ${copiesOf(missing)}` }, { value: "all", label: `Every card ${copiesOf(all)}` }]}
                   value={mode} onChange={(m) => setMode(m as AddMode)} />
        {list.kind === "deck" && side > 0 && <SwitchRow label="Sideboard" detail={plural(side)} on={sideboard} onChange={setSideboard} />}
        <Segmented options={CONDITIONS.map((c) => ({ value: c, label: c }))} value={condition} onChange={setCondition} />
        <Notice tone="info">Each card goes in as the printing, finish and language this {list.kind} lists. Considering isn't added.</Notice>
        <Section title="To add" count={copies} />
        {!ops.length && <Row title={mode === "missing" ? "You own every card here" : "No cards to add"}
                             detail={mode === "missing" ? "Pick Every card to add another copy of each" : undefined} />}
        {ops.map((o) => {
          const p = catalog.printingIndex.get(o.card_id) ?? null;
          const oi = p == null ? -1 : catalog.pOracle[p];
          const set = p == null ? null : `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`;
          return (
            <div key={`${o.card_id}|${o.finish}`} className="h-[60px] shrink-0">
              <CardRow c={catalog} p={p} title={oi >= 0 ? catalog.oName[oi] : "Unknown card"} finish={o.finish}
                       detail={[set, o.finish === "nonfoil" ? null : o.finish === "foil" ? "Foil" : "Etched"].filter(Boolean).join(" · ")}
                       value={`+${o.delta}`} />
            </div>
          );
        })}
      </div>
      <div className="shrink-0 flex gap-px pb-px">
        {done ? <GhostAction label="Done" onClick={onClose} />
          : <button type="button" disabled={busy || !copies} onClick={() => void add()}
                    className="flex-1 bg-t1-accent text-t1-ink disabled:bg-t1-disabled px-4 py-3 text-[11px] uppercase tracking-[1px]">
              {busy ? "Adding…" : copies ? `Add ${plural(copies)}` : "Nothing to add"}
            </button>}
      </div>
    </div>
  );
}
