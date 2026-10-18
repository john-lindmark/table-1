// Library → Import and export (contract/collection-import-2026-10-17.md). Pick another app's CSV export, see what
// matched, fix or skip what didn't, then add it to the collection (or replace the collection with it) as
// collection_apply batches of up to 5000 ops, each with its own idempotency key, with one Undo for the lot.
// Export downloads the collection in Moxfield's or ManaBox's layout. Same flow as iOS (CollectionImport.swift).
import { useEffect, useMemo, useRef, useState } from "react";
import { Bar, BigAction, Dialog, Field, Notice, Row, Section, Segmented, Stat } from "../components/kit";
import { errorMessage } from "../lib/api";
import { coverPrinting, searchCatalog, type Catalog } from "../lib/catalog";
import { applyOps, sync, undoBatch, useCollection, type CollectionOp, type Item } from "../lib/collection";
import {
  CsvError, FORMAT_LABEL, ImportResolver, exportCsv, importItemKey, importItems, parseCsv, rowSetLabel,
  type CsvFormat, type ExportCard, type ExportLayout, type ImportItem, type ImportRow, type ResolvedLine,
} from "../lib/collectionCsv";
import { usdPrice, usePrices } from "../lib/prices";
import { supabase } from "../lib/supabaseClient";
import { capture } from "../lib/telemetry";
import { CardRow, LibScreen, useCatalog, useLibrarySession } from "./Library";

/* ── set names (mtg_sets, readable signed out), cached for offline imports ── */

type SetName = { code: string; name: string };
const SETS_KEY = "table1.setNames";
let setsLoad: Promise<SetName[]> | null = null;

export function loadSetNames(): Promise<SetName[]> {
  if (!setsLoad) {
    setsLoad = (async () => {
      try {
        const all: SetName[] = [];
        for (let from = 0; from < 10_000; from += 1000) {
          const { data, error } = await supabase.from("mtg_sets").select("code,name").order("code").range(from, from + 999);
          if (error) throw error;
          all.push(...(data as SetName[]));
          if (data.length < 1000) break;
        }
        try {
          localStorage.setItem(SETS_KEY, JSON.stringify(all));
        } catch {
          /* storage blocked */
        }
        return all;
      } catch {
        setsLoad = null; // try again next time; meanwhile the saved list (set codes still match without it)
        try {
          return JSON.parse(localStorage.getItem(SETS_KEY) ?? "[]") as SetName[];
        } catch {
          return [];
        }
      }
    })();
  }
  return setsLoad;
}

const ROW_H = 58;
const SHOWN = 80;
const usd0 = (n: number) => new Intl.NumberFormat(undefined, { style: "currency", currency: "USD", maximumFractionDigits: 0 }).format(n);

interface Preview {
  fileName: string;
  format: CsvFormat;
  lines: number;
  matched: ResolvedLine[];
  unmatched: ImportRow[];
  fixed: number;
  skipped: number;
}

type Part = { key: string; ops: CollectionOp[]; batchId: string | null };

/** The collection as ManaBox/Moxfield rows; items whose printing isn't in the catalog are counted, not written. */
function exportCards(c: Catalog, items: Iterable<Item>, sets: Map<string, string>): { cards: ExportCard[]; left: number } {
  const cards: ExportCard[] = [];
  let left = 0;
  for (const it of items) {
    const p = c.printingIndex.get(it.cardId);
    if (p === undefined) {
      left += it.qty;
      continue;
    }
    cards.push({
      name: c.oName[c.pOracle[p]], set: c.pSet[p], setName: sets.get(c.pSet[p]) ?? c.pSet[p].toUpperCase(), cn: c.pCn[p],
      rarity: c.pRarity[p], cardId: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, qty: it.qty,
    });
  }
  return { cards, left };
}

export function CollectionImportScreen({ onBack, onAllCards }: { onBack: () => void; onAllCards: () => void }) {
  const { userId } = useLibrarySession();
  const col = useCollection(userId);
  const { catalog, error: catalogError } = useCatalog();
  const [preview, setPreview] = useState<Preview | null>(null);
  const [reading, setReading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [mode, setMode] = useState<"add" | "replace">("add");
  const [parts, setParts] = useState<Part[]>([]);
  const [writing, setWriting] = useState(false);
  const [confirmReplace, setConfirmReplace] = useState(false);
  const [done, setDone] = useState<{ batchIds: string[]; undone: boolean } | null>(null);
  const [undoing, setUndoing] = useState(false);
  const [fixing, setFixing] = useState<ImportRow | null>(null);
  const [exportNote, setExportNote] = useState<string | null>(null);
  const resolver = useRef<ImportResolver | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);

  const items: ImportItem[] = useMemo(() => (catalog && preview ? importItems(catalog, preview.matched) : []), [catalog, preview]);
  const copies = items.reduce((n, it) => n + it.qty, 0);
  const priceIds = useMemo(() => items.map((it) => it.cardId), [items]);
  usePrices(priceIds);
  let value = 0, priced = 0;
  for (const it of items) {
    const p = usdPrice(it.cardId, it.finish);
    if (p != null) {
      value += p * it.qty;
      priced++;
    }
  }
  const removed = useMemo(() => {
    const keep = new Set(items.map(importItemKey));
    let n = 0;
    for (const it of col.items.values()) if (!keep.has(importItemKey(it))) n += it.qty;
    return n;
  }, [items, col.items]);
  const partsDone = parts.filter((p) => p.batchId).length;
  const retrying = partsDone > 0 && partsDone < parts.length;

  useEffect(() => {
    void loadSetNames();
  }, []);

  const reset = () => {
    setPreview(null);
    setParts([]);
    setDone(null);
    setError(null);
    resolver.current = null;
  };

  const read = async (file: File) => {
    if (!catalog) return;
    reset();
    setReading(true);
    try {
      const buf = await file.arrayBuffer();
      let text: string;
      try {
        text = new TextDecoder("utf-8", { fatal: true }).decode(buf);
      } catch {
        text = new TextDecoder("windows-1252").decode(buf); // Excel on Windows
      }
      const parsed = parseCsv(text);
      const r = new ImportResolver(catalog, await loadSetNames());
      const { matched, unmatched } = r.resolveAll(parsed.rows);
      resolver.current = r;
      setPreview({ fileName: file.name, format: parsed.format, lines: parsed.rows.length, matched, unmatched, fixed: 0, skipped: 0 });
      capture("collection_import_previewed", { format: parsed.format, lines: parsed.rows.length, matched: matched.length, unmatched: unmatched.length });
    } catch (e) {
      setError(e instanceof CsvError ? e.message : errorMessage(e));
    } finally {
      setReading(false);
    }
  };

  const change = (next: Preview) => {
    setPreview(next);
    setParts([]); // the ops change, so a retry starts over with new keys
  };
  const fix = (row: ImportRow, oracle: number) => {
    if (!preview || !resolver.current) return;
    change({ ...preview, matched: [...preview.matched, resolver.current.resolveAs(row, oracle)],
             unmatched: preview.unmatched.filter((u) => u !== row), fixed: preview.fixed + 1 });
  };
  const skip = (row: ImportRow) =>
    preview && change({ ...preview, unmatched: preview.unmatched.filter((u) => u !== row), skipped: preview.skipped + 1 });
  const skipAll = () => preview && change({ ...preview, unmatched: [], skipped: preview.skipped + preview.unmatched.length });

  /** Sends every chunk that hasn't landed yet, in order, each with the key it was given. */
  const write = async () => {
    if (!preview) return;
    setWriting(true);
    setError(null);
    let todo = parts;
    if (!todo.length) {
      let ops: CollectionOp[];
      if (mode === "replace") {
        await sync();
        const keep = new Set(items.map(importItemKey));
        ops = items.map((it) => ({ card_id: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, qty: it.qty }));
        for (const it of col.items.values()) {
          if (!keep.has(importItemKey(it))) ops.push({ card_id: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, qty: 0 });
        }
      } else {
        ops = items.map((it) => ({ card_id: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, delta: it.qty }));
      }
      todo = [];
      for (let i = 0; i < ops.length; i += 5000) todo.push({ key: crypto.randomUUID(), ops: ops.slice(i, i + 5000), batchId: null });
    }
    const next = todo.map((p) => ({ ...p }));
    for (const p of next) {
      if (p.batchId) continue;
      try {
        p.batchId = (await applyOps(p.ops, "import", p.key)).batch_id;
      } catch (e) {
        const n = next.filter((x) => x.batchId).length;
        setParts(next);
        setError(n ? `Imported ${n} of ${next.length} parts, then: ${errorMessage(e)} Try again to send the rest.` : errorMessage(e));
        setWriting(false);
        return;
      }
    }
    setParts(next);
    setWriting(false);
    setDone({ batchIds: next.map((p) => p.batchId!), undone: false });
    capture("collection_imported", { format: preview.format, mode, cards: copies, items: items.length, parts: next.length,
                                     fixed: preview.fixed, skipped: preview.skipped });
  };

  const undo = async () => {
    if (!done || undoing) return;
    setUndoing(true);
    setError(null);
    const left = [...done.batchIds];
    try {
      while (left.length) {
        await undoBatch(left[left.length - 1]);
        left.pop();
      }
      setDone({ batchIds: [], undone: true });
    } catch (e) {
      setDone({ batchIds: left, undone: false });
      setError(errorMessage(e));
    } finally {
      setUndoing(false);
    }
  };

  const download = async (layout: ExportLayout) => {
    if (!catalog) return;
    const sets = new Map((await loadSetNames()).map((s) => [s.code, s.name]));
    const { cards, left } = exportCards(catalog, col.items.values(), sets);
    const blob = new Blob([exportCsv(cards, layout)], { type: "text/csv;charset=utf-8" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    const d = new Date();
    const day = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    a.download = `table1-collection-${layout}-${day}.csv`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
    setExportNote(left ? `${left} card${left === 1 ? "" : "s"} newer than the card data ${left === 1 ? "was" : "were"} left out.` : null);
    capture("collection_exported", { layout, cards: cards.reduce((n, c) => n + c.qty, 0) });
  };

  const subtitle = done ? (done.undone ? "Import undone" : "Imported") : preview ? FORMAT_LABEL[preview.format]
    : reading ? "Reading…" : col.summary ? `${col.summary.total_qty.toLocaleString()} cards in collection` : undefined;

  return (
    <LibScreen>
      <Bar title="Import and export" subtitle={subtitle} onBack={onBack} />
      {(error || catalogError) && <Notice tone="error">{error ?? catalogError}</Notice>}
      {!catalog && !catalogError && <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>}
      <input ref={fileInput} type="file" accept=".csv,.tsv,.txt,text/csv,text/tab-separated-values,text/plain" className="hidden"
             onChange={(e) => {
               const f = e.target.files?.[0];
               e.target.value = "";
               if (f) void read(f);
             }} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px"
           onDragOver={(e) => !preview && e.preventDefault()}
           onDrop={(e) => {
             if (preview) return;
             e.preventDefault();
             const f = e.dataTransfer.files?.[0];
             if (f) void read(f);
           }}>
        {done && preview ? (
          <>
            <Row title={done.undone ? "Import undone" : `${mode === "replace" ? "Replaced with" : "Imported"} ${copies.toLocaleString()} cards`}
                 detail={`${items.length.toLocaleString()} printings · ${FORMAT_LABEL[preview.format]}`}
                 action={done.undone ? undefined : { label: undoing ? "Undoing…" : "Undo", onClick: () => void undo(), disabled: undoing }} />
            <Row title="All cards" detail={col.summary ? `${col.summary.total_qty.toLocaleString()} cards in collection` : undefined} onClick={onAllCards} />
            <Row title="Import another file" onClick={reset} />
          </>
        ) : preview && catalog ? (
          <>
            <Row title={preview.fileName} detail={`${FORMAT_LABEL[preview.format]} · ${preview.lines.toLocaleString()} lines`} />
            <div className="bg-t1-surface px-4 py-3 flex gap-4">
              <Stat label="Matched" value={`${copies.toLocaleString()} cards`} accent />
              <Stat label="Printings" value={items.length.toLocaleString()} />
              <Stat label="Value" value={priced ? usd0(value) : "—"} end />
            </div>
            {preview.unmatched.length > 0 && (
              <>
                <Section title="Not matched" count={preview.unmatched.length}
                         right={<button type="button" onClick={skipAll} className="t1-label hover:text-t1-text">Skip all</button>} />
                {preview.unmatched.map((r) => (
                  <div key={r.line} className="bg-t1-surface flex items-stretch gap-px">
                    <div className="flex-1 min-w-0 px-4 py-2.5 flex flex-col gap-0.5">
                      <span className="text-[13px] truncate">{r.name || "No name"}</span>
                      <span className="t1-label truncate">
                        {[r.problem, `Line ${r.line}`, rowSetLabel(r) || null, `${r.qty} cop${r.qty === 1 ? "y" : "ies"}`].filter(Boolean).join(" · ")}
                      </span>
                    </div>
                    <button type="button" onClick={() => setFixing(r)} className="bg-t1-surface-hover px-4 t1-label !text-t1-text">Fix</button>
                    <button type="button" onClick={() => skip(r)} className="bg-t1-surface-hover px-4 t1-label !text-t1-text">Skip</button>
                  </div>
                ))}
              </>
            )}
            <Segmented options={[{ value: "add", label: "Add to collection" }, { value: "replace", label: "Replace collection" }]}
                       value={mode} onChange={(v) => { setMode(v); setParts([]); }} />
            {mode === "replace" && (
              <Notice tone="info">
                Your collection becomes exactly this file: {removed.toLocaleString()} cards that aren't in it are removed. Undo puts them back.
              </Notice>
            )}
            {preview.unmatched.length > 0 && <Notice tone="info">Lines left unmatched aren't imported. Fix them or skip them first.</Notice>}
            <BigAction label={retrying ? "Try again" : mode === "replace" ? `Replace with ${copies.toLocaleString()} cards` : `Import ${copies.toLocaleString()} cards`}
                       disabled={preview.unmatched.length > 0 || (copies === 0 && mode === "add")} busy={writing}
                       onClick={() => (mode === "replace" && !retrying ? setConfirmReplace(true) : void write())} />
            <Section title="Matched" count={preview.matched.length} />
            {preview.matched.slice(0, SHOWN).map((l, i) => (
              <div key={`${l.row.line}-${i}`} style={{ height: ROW_H }}>
                <CardRow c={catalog} p={l.p} title={l.row.name || catalog.oName[catalog.pOracle[l.p]]}
                         detail={[`${catalog.pSet[l.p].toUpperCase()} #${catalog.pCn[l.p]}`, l.finish === "nonfoil" ? null : l.finish === "foil" ? "Foil" : "Etched",
                                  l.row.condition, l.row.lang === "en" ? null : l.row.lang.toUpperCase()].filter(Boolean).join(" · ")}
                         value={l.row.qty} />
              </div>
            ))}
            {preview.matched.length > SHOWN && <Notice tone="info">And {(preview.matched.length - SHOWN).toLocaleString()} more lines.</Notice>}
            {!writing && <Row title="Choose another file" onClick={reset} />}
          </>
        ) : (
          <>
            <Section title="Import" />
            <BigAction label="Choose a file" disabled={!catalog} busy={reading} onClick={() => fileInput.current?.click()} />
            <Notice tone="info">
              Export the collection as CSV from ManaBox, Moxfield, Archidekt, Deckbox, Dragon Shield, TCGplayer or Delver Lens, then
              choose the file here (or drop it on this page). A card name and its set are enough; collector number, foil, condition and
              language are read when the file has them.
            </Notice>
            <Section title="Export" />
            {(["moxfield", "manabox"] as const).map((layout) => (
              <Row key={layout} title={`For ${layout === "moxfield" ? "Moxfield" : "ManaBox"}`}
                   detail={`CSV in ${layout === "moxfield" ? "Moxfield" : "ManaBox"}'s layout`}
                   onClick={catalog && col.items.size ? () => void download(layout) : undefined} dim={!catalog || !col.items.size} />
            ))}
            {exportNote && <Notice tone="info">{exportNote}</Notice>}
          </>
        )}
      </div>
      {confirmReplace && (
        <Dialog title="Replace your collection?" tone="danger" cancelLabel="Cancel" confirmLabel="Replace"
                message={`Your collection becomes exactly this file. ${removed.toLocaleString()} cards that aren't in it are removed. Undo puts them back.`}
                onCancel={() => setConfirmReplace(false)} onConfirm={() => { setConfirmReplace(false); void write(); }} />
      )}
      {fixing && catalog && (
        <FixPanel c={catalog} row={fixing} onClose={() => setFixing(null)}
                  onPick={(o) => { fix(fixing, o); setFixing(null); }} />
      )}
    </LibScreen>
  );
}

/** Fix one unmatched line: search the catalog with the line's name filled in, pick the card. */
function FixPanel({ c, row, onPick, onClose }: { c: Catalog; row: ImportRow; onPick: (oracle: number) => void; onClose: () => void }) {
  const [q, setQ] = useState(row.name);
  const hits = useMemo(() => {
    const found = searchCatalog(c, q, 40);
    // A name with set or version noise ("Bolt (Borderless)") still finds the card by its first words.
    const cut = q.search(/[[(]/);
    return found.length || cut < 0 ? found : searchCatalog(c, q.slice(0, cut), 40);
  }, [c, q]);
  return (
    <div className="fixed inset-0 z-50 bg-t1-bg flex flex-col gap-px" role="dialog" aria-modal="true" aria-label={`Fix line ${row.line}`}>
      <Bar title={`Line ${row.line}`} subtitle={[row.name, rowSetLabel(row)].filter(Boolean).join(" · ")} onBack={onClose} />
      <Field label="Card name" value={q} onChange={setQ} autoFocus />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {q.trim().length >= 2 && hits.length === 0 && <div className="bg-t1-surface px-4 py-4 t1-label">No card by that name</div>}
        {hits.map((i) => (
          <div key={i} style={{ height: ROW_H }}>
            <CardRow c={c} p={coverPrinting(c, i)} title={c.oName[i]} detail={c.oType[i]} value="Pick" onClick={() => onPick(i)} />
          </div>
        ))}
      </div>
    </div>
  );
}
