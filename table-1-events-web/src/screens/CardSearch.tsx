import { useEffect, useRef, useState } from "react";
import { Bar, BigAction, Field, Notice, Section, Segmented } from "../components/kit";
import type { Catalog } from "../lib/catalog";
import {
  EMPTY_ADVANCED, advancedQuery, hasSyntax, runCardSearch, searchDelay, type AdvancedFields, type ColorMode, type SearchResult,
} from "../lib/cardQuery";
import { capture } from "../lib/telemetry";

/* The search row every Add cards screen shares (contract/library-polish-2026-10-19.md § Advanced search): the box (a
   name, or Scryfall syntax) and Adv, the form that writes the syntax. The web has no scanner, so no Scan here. */

/** Runs the box's search after typing settles: the ranked name search, the local advanced search, or Scryfall. `query`
 *  says which text the result belongs to. */
export function useCardSearch(catalog: Catalog | null, q: string, nameLimit = 40): { query: string; result: SearchResult } | null {
  const [found, setFound] = useState<{ query: string; result: SearchResult } | null>(null);
  useEffect(() => {
    if (!catalog || !q.trim()) {
      setFound(null);
      return;
    }
    const ctl = new AbortController();
    const t = setTimeout(() => {
      void runCardSearch(q, catalog, ctl.signal, nameLimit).then((result) => {
        if (!ctl.signal.aborted) setFound({ query: q, result });
      });
    }, searchDelay(q));
    return () => {
      clearTimeout(t);
      ctl.abort();
    };
  }, [catalog, q, nameLimit]);
  return found;
}

export function CardSearchBar({ label = "Search", value, onChange, placeholder = "Name, or Scryfall syntax", autoFocus, onSubmit, onFocus, inputRef }: {
  label?: string; value: string; onChange: (v: string) => void; placeholder?: string; autoFocus?: boolean;
  /** Return in the box: usually picks the top hit. */
  onSubmit?: () => void;
  onFocus?: () => void;
  inputRef?: React.Ref<HTMLInputElement>;
}) {
  const [advanced, setAdvanced] = useState(false);
  return (
    <div className="shrink-0 flex items-stretch gap-px">
      <label className="flex-1 min-w-0 bg-t1-surface px-4 py-3 flex flex-col gap-1">
        <span className="t1-label">{label}</span>
        <input type="search" value={value} autoFocus={autoFocus} placeholder={placeholder} ref={inputRef} onFocus={onFocus}
               autoCapitalize="off" autoCorrect="off" spellCheck={false}
               onChange={(e) => onChange(e.target.value)}
               onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); onSubmit?.(); } }}
               className="bg-transparent border-0 outline-0 text-[15px] text-t1-text placeholder:text-t1-muted/60 w-full" />
      </label>
      <button type="button" aria-label="Advanced search" onClick={() => setAdvanced(true)}
              className="bg-t1-surface hover:bg-t1-surface-hover px-4 t1-label !text-t1-text">Adv</button>
      {advanced && <AdvancedSearch start={value} onClose={() => setAdvanced(false)} onApply={(q) => { setAdvanced(false); onChange(q); }} />}
    </div>
  );
}

/** A line under the search box saying what an advanced search found, and where. */
export function CardSearchStatus({ query, found }: { query: string; found: { query: string; result: SearchResult } | null }) {
  if (!found || !hasSyntax(query)) return null;
  const r = found.result;
  if (r.error) return <Notice tone="error">{r.error}</Notice>;
  const shown = r.hits.length < r.total ? `${r.hits.length} of ${r.total.toLocaleString()}` : r.total.toLocaleString();
  return (
    <div className="shrink-0 bg-t1-surface px-4 py-2 t1-label">
      {shown} card{r.total === 1 ? "" : "s"}{r.remote ? " · from Scryfall" : ""}
    </div>
  );
}

const FORMATS: { value: string; label: string }[] = [
  { value: "", label: "Any" }, { value: "standard", label: "Standard" }, { value: "pioneer", label: "Pioneer" },
  { value: "modern", label: "Modern" }, { value: "legacy", label: "Legacy" }, { value: "vintage", label: "Vintage" },
  { value: "pauper", label: "Pauper" }, { value: "commander", label: "Commander" }, { value: "premodern", label: "Premodern" },
];
const RARITY_LABEL: Record<string, string> = { c: "Common", u: "Uncommon", r: "Rare", m: "Mythic" };

/** Scryfall's advanced search, kept to what players filter by. The fields are written as syntax into the search box,
 *  so the search can be edited there afterwards. */
export function AdvancedSearch({ start, onClose, onApply }: { start: string; onClose: () => void; onApply: (q: string) => void }) {
  const [f, setF] = useState<AdvancedFields>(() => (hasSyntax(start) ? EMPTY_ADVANCED : { ...EMPTY_ADVANCED, name: start }));
  const patch = (p: Partial<AdvancedFields>) => setF((x) => ({ ...x, ...p }));
  const q = advancedQuery(f);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") closeRef.current(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  const toggles = (keys: string[], selected: string[], onChange: (v: string[]) => void, label: (k: string) => string = (k) => k) => (
    <div className="flex gap-px bg-t1-bg">
      {keys.map((k) => {
        const on = selected.includes(k);
        return (
          <button key={k} type="button" aria-pressed={on}
                  onClick={() => {
                    if (on) return onChange(selected.filter((x) => x !== k));
                    // Colorless and colors don't mix.
                    const rest = k === "C" ? [] : selected.filter((x) => x !== "C");
                    onChange([...rest, k]);
                  }}
                  className={`flex-1 min-w-0 py-3 text-[11px] uppercase tracking-[1px] ${on ? "bg-t1-text text-t1-bg" : "bg-t1-surface hover:bg-t1-surface-hover"}`}>
            {label(k)}
          </button>
        );
      })}
    </div>
  );
  return (
    <div className="fixed inset-0 z-50 bg-t1-bg text-t1-text flex flex-col gap-px" role="dialog" aria-modal="true" aria-label="Advanced search">
      <Bar title="Advanced search" subtitle="Scryfall syntax" onBack={onClose}
           right={<button type="button" className="t1-label hover:text-t1-text px-2 py-1 -my-1" onClick={() => setF(EMPTY_ADVANCED)}>Clear</button>} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px w-full max-w-[640px] mx-auto">
        <Field label="Card name" value={f.name} onChange={(name) => patch({ name })} autoFocus />
        <Field label="Text · needs a connection" value={f.text} onChange={(text) => patch({ text })} />
        <Field label="Type line · e.g. legendary creature" value={f.type} onChange={(type) => patch({ type })} />
        <Section title="Colors" />
        {toggles(["W", "U", "B", "R", "G", "C"], f.colors, (colors) => patch({ colors }))}
        {f.colors.length > 0 && !f.colors.includes("C") && (
          <Segmented<ColorMode> options={[{ value: "exactly", label: "Exactly" }, { value: "including", label: "Including" }, { value: "atMost", label: "At most" }]}
                                value={f.colorMode} onChange={(colorMode) => patch({ colorMode })} />
        )}
        <Section title="Mana value" />
        <div className="flex items-stretch gap-px">
          <div className="flex-1 min-w-0">
            <Segmented options={[{ value: "=", label: "=" }, { value: "<", label: "<" }, { value: "<=", label: "≤" }, { value: ">", label: ">" }, { value: ">=", label: "≥" }]}
                       value={f.mvOp} onChange={(mvOp) => patch({ mvOp })} />
          </div>
          <input inputMode="decimal" value={f.mv} placeholder="3" aria-label="Mana value" onChange={(e) => patch({ mv: e.target.value })}
                 className="w-16 bg-t1-surface text-center text-[15px] outline-0 placeholder:text-t1-muted/60" />
        </div>
        <Section title="Rarity" />
        {toggles(["c", "u", "r", "m"], f.rarities, (rarities) => patch({ rarities }), (k) => RARITY_LABEL[k])}
        <Field label="Set code · e.g. mh3" value={f.set} onChange={(s) => patch({ set: s })} />
        <Section title="Legal in" />
        <Segmented options={FORMATS} value={f.format} onChange={(format) => patch({ format })} columns={3} />
        <Notice tone="info">{q || "Fill any field. Everything but card text searches the card data in this browser."}</Notice>
      </div>
      <div className="w-full max-w-[640px] mx-auto">
        <BigAction label="Search" disabled={!q} onClick={() => {
          capture("advanced_search_used", { text: !!f.text.trim(), colors: f.colors.length, mv: !!f.mv.trim(), rarity: f.rarities.length,
                                            set: !!f.set.trim(), format: f.format });
          onApply(q);
        }} />
      </div>
    </div>
  );
}
