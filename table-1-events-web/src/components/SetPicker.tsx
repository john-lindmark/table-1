import { useEffect, useState } from "react";
import { fetchDraftableSets } from "../lib/api";
import type { DraftableSet } from "../lib/types";
import { Field } from "./kit";

/** Searchable list of draftable sets, newest first. Falls back to a free-text set name when the list is empty. */
export function SetPicker({
  picked,
  onPick,
  fallbackName,
  onFallbackName,
}: {
  picked: DraftableSet | null;
  onPick: (s: DraftableSet | null) => void;
  fallbackName: string;
  onFallbackName: (v: string) => void;
}) {
  const [query, setQuery] = useState("");
  const [sets, setSets] = useState<DraftableSet[] | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let live = true;
    const id = window.setTimeout(
      () => {
        fetchDraftableSets(query, 40)
          .then((rows) => {
            if (!live) return;
            setSets(rows);
            setFailed(false);
          })
          .catch(() => {
            if (!live) return;
            setSets([]);
            setFailed(true);
          });
      },
      query ? 250 : 0,
    );
    return () => {
      live = false;
      window.clearTimeout(id);
    };
  }, [query]);

  // Nothing to pick from at all (or the lookup failed): take a typed set name instead.
  const noCatalog = sets !== null && sets.length === 0 && (!query || failed);

  if (noCatalog) {
    return <Field label="Set name" value={fallbackName} onChange={(v) => onFallbackName(v.slice(0, 80))} placeholder="e.g. Duskmourn" />;
  }

  return (
    <div className="flex flex-col gap-px">
      <label className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
        <span className="t1-label">{picked ? `Set · ${picked.name}` : "Set"}</span>
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search sets"
          className="bg-transparent border-0 outline-0 text-[15px] text-t1-text placeholder:text-t1-muted/60 w-full"
        />
      </label>
      <div className="max-h-[240px] overflow-y-auto flex flex-col gap-px">
        {sets === null && <div className="bg-t1-surface px-4 py-3 t1-label">Loading sets…</div>}
        {sets !== null && sets.length === 0 && <div className="bg-t1-surface px-4 py-3 t1-label">No sets match “{query}”</div>}
        {sets?.map((s) => {
          const on = picked?.code === s.code;
          return (
            <button
              key={s.code}
              type="button"
              onClick={() => onPick(on ? null : s)}
              className={`px-4 py-2.5 flex items-center gap-3 text-left ${on ? "bg-t1-accent text-t1-ink" : "bg-t1-surface hover:bg-t1-surface-hover"}`}
            >
              {s.icon_svg_uri ? (
                <img src={s.icon_svg_uri} alt="" className={`size-4 shrink-0 ${on ? "" : "invert"}`} />
              ) : (
                <span className="size-4 shrink-0" />
              )}
              <span className="flex-1 min-w-0 truncate text-[13px]">{s.name}</span>
              <span className={`t1-label shrink-0 ${on ? "text-t1-ink!" : ""}`}>
                {s.code.toUpperCase()}
                {s.released_at ? ` · ${s.released_at.slice(0, 4)}` : ""}
              </span>
            </button>
          );
        })}
      </div>
    </div>
  );
}
