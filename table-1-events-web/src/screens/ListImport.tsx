// Import a deck or cube from a link (Cube Cobra, Archidekt, MTGGoldfish, ManaBox and other pages) or a pasted list
// (Moxfield, ManaBox, Arena, MTGO exports); contract/list-import-2026-10-15.md. Lines resolve to exact printings
// when the source names them, else to the card's original paper printing. Same flow as iOS and Android.
import { useState } from "react";
import { Bar, BigAction, Field, Notice, Row, Section, Segmented } from "../components/kit";
import { printingBySetCn, printingsByName, type Catalog } from "../lib/catalog";
import { BOARD_ORDER, boardTitle, createList, type Board, type Entry, type ListFinish, type ListKind } from "../lib/lists";
import { supabase } from "../lib/supabaseClient";
import { CardRow, LibScreen, useCatalog } from "./Library";
import { useListsData } from "./Lists";

interface ImportLine { qty: number; board: string; name: string; set?: string; cn?: string; scryfall_id?: string; finish?: string }
interface Imported { kind: ListKind; name: string; format: string; source_url: string; entries: ImportLine[] }

const DECK_FORMATS = ["modern", "pioneer", "standard", "legacy", "vintage", "pauper", "commander", "canlander", "other"];
const CUBE_FORMATS = ["vintage", "legacy", "pauper", "peasant", "other"];
const FINISH_LETTER: Record<string, string> = { nonfoil: "n", foil: "f", etched: "e" };

/** Scryfall id, then set + collector number, then the name's original printing. Cubes fold side/commander into main. */
export function resolveImport(c: Catalog, lines: ImportLine[], kind: ListKind) {
  const byName = printingsByName(c, lines.map((l) => l.name));
  const entries = new Map<string, Entry>();
  const names = new Map<string, string>();
  const missing = new Set<string>();
  for (const l of lines) {
    const p = (l.scryfall_id ? c.printingIndex.get(l.scryfall_id.toLowerCase()) : undefined)
      ?? (l.set && l.cn ? printingBySetCn(c, l.set, l.cn) : undefined)
      ?? byName.get(l.name);
    if (p === undefined) { missing.add(l.name); continue; }
    const finish: ListFinish = l.finish && c.pFinishes[p].includes(FINISH_LETTER[l.finish] ?? "?") ? (l.finish as ListFinish) : "nonfoil";
    let board = (["main", "side", "maybe", "commander"].includes(l.board) ? l.board : "main") as Board;
    if (kind === "cube" && (board === "side" || board === "commander")) board = "main";
    const cardId = c.pId[p];
    names.set(cardId, l.name);
    const k = `${board}|${cardId}|${finish}`;
    const e = entries.get(k);
    if (e) e.qty = Math.min(999, e.qty + l.qty);
    else entries.set(k, finish === "nonfoil" ? { cardId, board, qty: l.qty } : { cardId, board, qty: l.qty, finish });
  }
  return { entries: [...entries.values()], names, missing: [...missing].sort() };
}

export function ListImportScreen({ kind, onBack, onCreated }: { kind: ListKind; onBack: () => void; onCreated: (id: string) => void }) {
  const { session, ready } = useListsData();
  const { catalog } = useCatalog();
  const [link, setLink] = useState("");
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<(Omit<Imported, "entries"> & ReturnType<typeof resolveImport>) | null>(null);
  const [name, setName] = useState("");
  const formats = kind === "deck" ? DECK_FORMATS : CUBE_FORMATS;
  const [format, setFormat] = useState(formats[0]);

  const read = async () => {
    if (!catalog) return;
    setBusy(true);
    setError(null);
    try {
      const { data, error: e } = await supabase.functions.invoke("list-import", { body: link.trim() ? { url: link.trim() } : { text } });
      if (e) {
        const body = await (e as { context?: Response }).context?.json?.().catch(() => null);
        return setError(body?.error ?? "That list couldn't be read.");
      }
      const r = data as Imported;
      if (!r.entries?.length) return setError("No cards in that list.");
      const resolved = resolveImport(catalog, r.entries, kind);
      setName((r.name ?? "").slice(0, 60));
      if (formats.includes(r.format)) setFormat(r.format);
      setResult({ ...r, ...resolved });
    } finally {
      setBusy(false);
    }
  };
  const create = async () => {
    if (!result) return;
    setBusy(true);
    try {
      const host = result.source_url ? new URL(result.source_url).host : null;
      onCreated(await createList(kind, name.trim().slice(0, 60), format, result.entries, host ? `Imported from ${host}` : "Imported"));
    } finally {
      setBusy(false);
    }
  };

  const title = kind === "deck" ? "Import deck" : "Import cube";
  if (!ready) return <LibScreen><div className="flex-1" /></LibScreen>;
  if (!session) return <LibScreen><Bar title={title} onBack={onBack} /><Notice tone="info">Sign in to import lists.</Notice></LibScreen>;
  const count = (b: Board) => result?.entries.filter((e) => e.board === b).reduce((n, e) => n + e.qty, 0) ?? 0;
  return (
    <LibScreen>
      <Bar title={title} subtitle="From a link or a pasted list" onBack={onBack} />
      {error && <Notice tone="error">{error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {!result && (
          <>
            <Field label={kind === "deck" ? "Link (ManaBox, Archidekt, MTGGoldfish…)" : "Cube Cobra link"} value={link} onChange={setLink} autoFocus />
            <label className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
              <span className="t1-label">Or paste a list</span>
              <textarea value={text} onChange={(e) => setText(e.target.value)} rows={8} spellCheck={false}
                        className="bg-transparent text-[13px] outline-none resize-y caret-t1-accent" />
            </label>
            <Notice tone="info">
              {kind === "deck"
                ? "Moxfield doesn't share decks with other apps: in Moxfield choose Export, copy the list as text and paste it here."
                : "Cube Cobra: paste the cube's link. Any one-card-per-line list works too."}
            </Notice>
            <BigAction label={busy ? "Reading…" : "Import"} busy={busy} onClick={() => void read()}
                       disabled={busy || !catalog || (!link.trim() && !text.trim())} />
          </>
        )}
        {result && catalog && (
          <>
            <Field label="Name" value={name} onChange={setName} />
            <Segmented options={formats.map((f) => ({ value: f, label: f }))} value={format} onChange={setFormat} columns={4} />
            <Row title={(kind === "deck"
                           ? [`${count("main")} main`, count("side") ? `${count("side")} sideboard` : "", count("maybe") ? `${count("maybe")} considering` : "",
                              count("commander") ? `${count("commander")} commander` : ""]
                           : [`${count("main")} cards`, count("maybe") ? `${count("maybe")} considering` : ""]).filter(Boolean).join(" · ")}
                 detail={result.source_url ? new URL(result.source_url).host : undefined} />
            {result.missing.length > 0 && (
              <Notice tone="error">
                Not in the card data, left out: {result.missing.slice(0, 12).join(", ")}{result.missing.length > 12 ? ` and ${result.missing.length - 12} more` : ""}
              </Notice>
            )}
            <BigAction label={kind === "deck" ? "Create deck" : "Create cube"} busy={busy} onClick={() => void create()}
                       disabled={busy || !result.entries.length || !name.trim()} />
            <Row title="Start over" onClick={() => setResult(null)} />
            {BOARD_ORDER.filter((b) => result.entries.some((e) => e.board === b)).map((b) => (
              <div key={b} className="flex flex-col gap-px">
                <Section title={boardTitle(kind, b)} count={count(b)} />
                {result.entries.filter((e) => e.board === b).map((e) => {
                  const p = catalog.printingIndex.get(e.cardId) ?? null;
                  return (
                    <div key={`${e.cardId}|${e.finish ?? ""}`} className="h-[60px]">
                      <CardRow c={catalog} p={p} title={result.names.get(e.cardId) ?? ""} value={e.qty}
                               detail={[p !== null ? `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}` : null, e.finish && e.finish !== "nonfoil" ? e.finish : null].filter(Boolean).join(" · ")} />
                    </div>
                  );
                })}
              </div>
            ))}
          </>
        )}
      </div>
    </LibScreen>
  );
}
