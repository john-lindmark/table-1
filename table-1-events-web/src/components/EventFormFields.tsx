import { useEffect, useRef, useState } from "react";
import { fetchRecentCubes, lookupCube, type RecentCube } from "../lib/api";
import { CONSTRUCTED_FORMATS, LIMITED_FORMATS, typeOfFormat } from "../lib/formats";
import type { DraftableSet, FormatName } from "../lib/types";
import { SetPicker } from "./SetPicker";
import { Field, Notice, Row, Section, Segmented, SwitchRow } from "./kit";

/** CubeCobra links must be https. */
export const URL_OK = /^https:\/\/\S+$/i;

export const cubeUrlProblem = (cubeUrl: string) =>
  cubeUrl.trim() !== "" && !URL_OK.test(cubeUrl.trim()) ? "The CubeCobra link must start with https://" : null;

/**
 * Type (Constructed | Limited) → Format list, plus "Format name" for Other. Shared by Create and the
 * organizer's Setup → Details. Switching type picks that type's first format (Modern / Draft).
 */
export function FormatPicker({
  format,
  onFormat,
  formatOther,
  onFormatOther,
  onCommit,
}: {
  format: FormatName;
  onFormat: (f: FormatName) => void;
  formatOther: string;
  onFormatOther: (v: string) => void;
  /** Called when a text field loses focus. */
  onCommit?: () => void;
}) {
  const limited = typeOfFormat(format) === "limited";
  return (
    <>
      <Segmented
        label="Type"
        value={limited ? "limited" : "constructed"}
        onChange={(t) => {
          if ((t === "limited") !== limited) onFormat(t === "limited" ? "draft" : "modern");
        }}
        options={[
          { value: "constructed", label: "Constructed" },
          { value: "limited", label: "Limited" },
        ]}
      />
      <Segmented
        label="Format"
        value={format}
        onChange={onFormat}
        columns={limited ? 2 : 3}
        options={limited ? LIMITED_FORMATS : CONSTRUCTED_FORMATS}
      />
      {format === "other_constructed" && (
        <Field
          label="Format name"
          value={formatOther}
          onChange={(v) => onFormatOther(v.slice(0, 40))}
          onBlur={onCommit}
          placeholder="e.g. Oathbreaker"
        />
      )}
    </>
  );
}

/** Limited events: a set from draftable_sets (or a typed set name), or a cube with an optional CubeCobra link. */
export function ProductPicker({
  product,
  onProduct,
  set,
  onSet,
  setNameText,
  onSetNameText,
  cubeName,
  onCubeName,
  cubeUrl,
  onCubeUrl,
  onCommit,
}: {
  product: "set" | "cube";
  onProduct: (p: "set" | "cube") => void;
  set: DraftableSet | null;
  onSet: (s: DraftableSet | null) => void;
  setNameText: string;
  onSetNameText: (v: string) => void;
  cubeName: string;
  onCubeName: (v: string) => void;
  cubeUrl: string;
  onCubeUrl: (v: string) => void;
  onCommit?: () => void;
}) {
  return (
    <>
      <Segmented
        label="Product"
        value={product}
        onChange={onProduct}
        options={[
          { value: "set", label: "Set" },
          { value: "cube", label: "Cube" },
        ]}
      />
      {product === "set" ? (
        <SetPicker picked={set} onPick={onSet} fallbackName={setNameText} onFallbackName={onSetNameText} />
      ) : (
        <CubeFields cubeName={cubeName} onCubeName={onCubeName} cubeUrl={cubeUrl} onCubeUrl={onCubeUrl} onCommit={onCommit} />
      )}
    </>
  );
}

/**
 * Cube: your recent cubes, a Cube Cobra link (the name fills in from Cube Cobra), and the name.
 * Picking a recent cube hides the link and name; "Another cube" brings them back.
 * (Your Table 1 cubes join this list once the Library keeps cubes.)
 */
export function CubeFields({
  cubeName,
  onCubeName,
  cubeUrl,
  onCubeUrl,
  onCommit,
}: {
  cubeName: string;
  onCubeName: (v: string) => void;
  cubeUrl: string;
  onCubeUrl: (v: string) => void;
  onCommit?: () => void;
}) {
  const [recent, setRecent] = useState<RecentCube[]>([]);
  // A recent cube is the choice, so the link and name fields stay hidden.
  const [picked, setPicked] = useState(false);
  const [lookup, setLookup] = useState<{ kind: "idle" | "looking" } | { kind: "found"; cards: number | null } | { kind: "failed"; message: string }>({ kind: "idle" });
  // The link the last lookup answered for, so writing its canonical form back doesn't look it up again.
  const settled = useRef<string | null>(null);
  const handlers = useRef({ onCubeName, onCubeUrl, onCommit });
  handlers.current = { onCubeName, onCubeUrl, onCommit };

  useEffect(() => {
    let live = true;
    fetchRecentCubes().then((rows) => {
      if (!live) return;
      setRecent(rows);
      setPicked(rows.some((c) => c.cube_name === cubeName.trim() && (c.cube_url ?? "") === cubeUrl.trim()));
    });
    return () => {
      live = false;
    };
  }, []);

  useEffect(() => {
    const link = cubeUrl.trim();
    if (!link) {
      setLookup({ kind: "idle" });
      return;
    }
    if (link === settled.current) return;
    let live = true;
    const id = window.setTimeout(() => {
      setLookup({ kind: "looking" });
      lookupCube(link)
        .then((cube) => {
          if (!live) return;
          settled.current = cube.url;
          handlers.current.onCubeName(cube.name);
          handlers.current.onCubeUrl(cube.url);
          setLookup({ kind: "found", cards: cube.card_count });
          handlers.current.onCommit?.();
        })
        .catch((e) => live && setLookup({ kind: "failed", message: e instanceof Error ? e.message : String(e) }));
    }, 450);
    return () => {
      live = false;
      window.clearTimeout(id);
    };
  }, [cubeUrl]);

  const use = (c: RecentCube) => {
    settled.current = c.cube_url ?? "";
    onCubeName(c.cube_name);
    onCubeUrl(c.cube_url ?? "");
    setLookup({ kind: "idle" });
    setPicked(true);
    onCommit?.();
  };
  const current = (c: RecentCube) => c.cube_name === cubeName.trim() && (c.cube_url ?? "") === cubeUrl.trim();
  const urlProblem = lookup.kind !== "looking" ? cubeUrlProblem(cubeUrl) : null;

  return (
    <>
      {recent.length > 0 && (
        <>
          <Section title="Recent cubes" />
          {recent.map((c) => (
            <Row
              key={`${c.cube_name}|${c.cube_url ?? ""}`}
              title={c.cube_name}
              value={current(c) ? "Selected" : "Use"}
              accentValue={current(c)}
              onClick={() => use(c)}
            />
          ))}
          {picked && <Row title="Another cube" value="Enter" onClick={() => setPicked(false)} />}
        </>
      )}
      {!picked && (
        <>
          <Section title="Cube" />
          <Field
            label="Cube Cobra link"
            value={cubeUrl}
            onChange={onCubeUrl}
            onBlur={onCommit}
            placeholder="https://cubecobra.com/cube/overview/…"
            type="url"
          />
          {lookup.kind === "looking" && <Notice tone="info">Looking it up on Cube Cobra…</Notice>}
          {lookup.kind === "found" && (
            <Notice tone="info">Found on Cube Cobra{lookup.cards != null ? ` · ${lookup.cards} cards` : ""}.</Notice>
          )}
          {lookup.kind === "failed" && <Notice tone="error">{lookup.message}</Notice>}
          <Field
            label="Cube name"
            value={cubeName}
            onChange={(v) => onCubeName(v.slice(0, 80))}
            onBlur={onCommit}
            placeholder="e.g. Vintage Cube"
          />
          {urlProblem && <Notice tone="error">Paste a Cube Cobra link (https://cubecobra.com/…)</Notice>}
        </>
      )}
    </>
  );
}

/** "Round timer · 50 min": on shows clocks to everyone; off hides them. Rounds run 50 minutes either way. */
export function RoundTimerSwitch({ on, onChange }: { on: boolean; onChange: (next: boolean) => void }) {
  return <SwitchRow label="Round timer · 50 min" detail={on ? "Clocks shown" : "Clocks hidden"} on={on} onChange={onChange} />;
}

/** A name field with an Add button beside it; Enter adds too. */
export function AddByName({
  value,
  onChange,
  onAdd,
  disabled,
  label = "Add a player by name",
}: {
  value: string;
  onChange: (v: string) => void;
  onAdd: () => void;
  disabled?: boolean;
  label?: string;
}) {
  return (
    <div className="flex gap-px">
      <label className="flex-1 min-w-0 bg-t1-surface px-4 py-3 flex flex-col gap-1">
        <span className="t1-label">{label}</span>
        <input
          value={value}
          onChange={(e) => onChange(e.target.value.slice(0, 40))}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !disabled) {
              e.preventDefault();
              onAdd();
            }
          }}
          placeholder="e.g. Alex"
          className="bg-transparent border-0 outline-0 text-[15px] text-t1-text placeholder:text-t1-muted/60 w-full"
        />
      </label>
      <button
        type="button"
        onClick={onAdd}
        disabled={disabled}
        className="w-20 shrink-0 bg-t1-accent text-t1-ink t1-label text-t1-ink! disabled:bg-t1-disabled disabled:text-t1-muted!"
      >
        Add
      </button>
    </div>
  );
}

/** Tidied name: trimmed, inner whitespace collapsed. */
export const tidyName = (s: string) => s.trim().replace(/\s+/g, " ");

/** Create: you (on by default) plus players by name only. People with accounts are invited after. */
export function PlayersEditor({
  includeMe,
  onIncludeMe,
  myName,
  guests,
  onGuests,
}: {
  includeMe: boolean;
  onIncludeMe: (v: boolean) => void;
  myName: string | null;
  guests: string[];
  onGuests: (g: string[]) => void;
}) {
  const [draft, setDraft] = useState("");
  const name = tidyName(draft);
  const dup =
    !!name &&
    (guests.some((g) => g.toLowerCase() === name.toLowerCase()) || (includeMe && myName?.toLowerCase() === name.toLowerCase()));
  const add = () => {
    if (!name || dup) return;
    onGuests([...guests, name.slice(0, 40)]);
    setDraft("");
  };
  return (
    <>
      <Section title="Players" count={guests.length + (includeMe ? 1 : 0)} />
      <SwitchRow label={myName ? `You · ${myName}` : "You"} detail={includeMe ? "Playing" : "Not playing"} on={includeMe} onChange={onIncludeMe} />
      {guests.map((g, i) => (
        <Row key={`${g}-${i}`} title={g} detail="Guest · no account" action={{ label: "Remove", onClick: () => onGuests(guests.filter((_, j) => j !== i)) }} />
      ))}
      <AddByName value={draft} onChange={setDraft} onAdd={add} disabled={!name || dup} />
      {dup && <Notice tone="error">{name} is already on the list.</Notice>}
      <Notice tone="info">Add people with accounts on the next screen; they get an invitation.</Notice>
    </>
  );
}
