import { useEffect, useState } from "react";
import { capture } from "../lib/telemetry";
import { manaSymbols, MANA_SYMBOLS } from "../lib/limitedCards";

export interface FilterOption { value: string; label: string; detail?: string }
/** A filter as an attribute cell: its value, and the picker it opens (design guidance § Attribute row, § Picker). */
export interface FilterCell {
  name: string; value: string; options: FilterOption[]; current: string | null; onPick: (v: string) => void;
  /** A filter that takes several picks (Rarity, Color): what's picked (empty = the "all" option). The picker stays open,
   *  each tap puts an option in or out, and "all" clears the picks and closes it. */
  picked?: readonly string[];
}

/** The option at the end of the format and set pickers that opens Edit. */
export const EDIT_VALUE = "__edit";

const DROP = "M9 11.25L5.25 7.5H12.75L9 11.25Z";   // Material Symbols Sharp arrow_drop_down

/** Insights' filters: one row of equal cells, 50 px tall and 1 px apart, each a dropdown that opens its picker. */
export function FilterRow({ cells }: { cells: FilterCell[] }) {
  const [openName, setOpenName] = useState<string | null>(null);
  // looked up each render so a multi-pick picker shows the picks as they change
  const open = cells.find((c) => c.name === openName) ?? null;
  const setOpen = (c: FilterCell | null) => setOpenName(c?.name ?? null);
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(null); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);
  return (
    <>
      <div className="flex gap-px bg-t1-bg">
        {cells.map((c) => (
          <button key={c.name} type="button" aria-label={`${c.name}: ${c.value}`} aria-haspopup="dialog" onClick={() => setOpen(c)}
                  className="flex-1 min-w-0 h-[50px] px-1.5 flex items-center justify-center gap-0.5 bg-t1-surface hover:bg-t1-surface-hover">
            <span className="truncate text-[11px] uppercase tracking-[1.5px]">{c.value}</span>
            <svg viewBox="0 0 18 18" width="16" height="16" className="shrink-0 fill-t1-muted" aria-hidden><path d={DROP} /></svg>
          </button>
        ))}
      </div>
      {open && (
        <div className="fixed inset-0 z-50 flex flex-col justify-end lg:justify-center" role="dialog" aria-modal="true" aria-label={open.name}>
          <div className="absolute inset-0 bg-black/60" onClick={() => setOpen(null)} />
          <div className="relative bg-t1-bg w-full max-w-[480px] mx-auto pb-[env(safe-area-inset-bottom)]">
            <div className="p-4 flex flex-col gap-2.5">
              <div className="h-[18px] flex items-center justify-between">
                <span className="text-[12px] uppercase tracking-[1.5px] text-t1-muted">{open.name}</span>
                {open.picked && <button type="button" onClick={() => setOpen(null)} className="text-[12px] uppercase tracking-[1.5px] text-t1-text">Done</button>}
              </div>
              <div className="max-h-[400px] overflow-y-auto flex flex-col">
                {open.options.map((o) => {
                  const many = open.picked;
                  const on = many ? (many.length ? many.includes(o.value) : o.value === "all") : o.value === open.current;
                  return (
                    <button key={o.value} type="button" aria-pressed={on}
                            onClick={() => {
                              const c = open;
                              if (many) {
                                if (o.value === "all") setOpen(null);
                                capture("insights_filter_changed", { filter: c.name.toLowerCase(), value: o.value, on: o.value === "all" ? true : !on });
                                c.onPick(o.value);
                                return;
                              }
                              setOpen(null);
                              if (o.value !== c.current && o.value !== EDIT_VALUE) capture("insights_filter_changed", { filter: c.name.toLowerCase(), value: o.value });
                              c.onPick(o.value);
                            }}
                            className={`shrink-0 flex flex-col items-center justify-center gap-0.5 active:bg-t1-surface hover:bg-t1-surface ${o.detail ? "h-[62px]" : "h-[50px]"} ${on ? "outline outline-1 -outline-offset-1 outline-t1-accent" : ""}`}>
                      <span className={`text-[12px] uppercase tracking-[1.5px] truncate ${on ? "text-t1-text" : "text-t1-muted"}`}>{o.label}</span>
                      {o.detail && <span className="text-[8px] uppercase tracking-[1.5px] text-t1-disabled truncate">{o.detail}</span>}
                    </button>
                  );
                })}
              </div>
            </div>
          </div>
        </div>
      )}
    </>
  );
}

/** A mana cost as Scryfall's symbols (public/mana); one it doesn't bundle is a grey circle with its text. */
export function ManaCost({ cost, size = 13 }: { cost: string; size?: number }) {
  const symbols = manaSymbols(cost);
  if (!symbols.length) return null;
  return (
    <span className="inline-flex items-center gap-0.5 shrink-0" role="img" aria-label={symbols.join(" ")}>
      {symbols.map((s, i) => s === "//" ? <span key={i} className="text-t1-muted" style={{ fontSize: size * 0.8 }}>//</span>
        : MANA_SYMBOLS.has(s) ? <img key={i} src={`/mana/${s}.svg`} alt="" width={size} height={size} draggable={false} />
        : <span key={i} className="inline-flex items-center justify-center rounded-full text-t1-ink" style={{ width: size, height: size, fontSize: size * 0.6, background: "#CAC5C0" }}>{s}</span>)}
    </span>
  );
}
