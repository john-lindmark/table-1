import type { EventType, FormatName } from "./types";

export const CONSTRUCTED_FORMATS: { value: FormatName; label: string }[] = [
  { value: "standard", label: "Standard" },
  { value: "pioneer", label: "Pioneer" },
  { value: "modern", label: "Modern" },
  { value: "legacy", label: "Legacy" },
  { value: "vintage", label: "Vintage" },
  { value: "pauper", label: "Pauper" },
  { value: "premodern", label: "Premodern" },
  { value: "canadian_highlander", label: "Canadian Highlander" },
  { value: "other_constructed", label: "Other" },
];

export const LIMITED_FORMATS: { value: FormatName; label: string }[] = [
  { value: "draft", label: "Draft" },
  { value: "team_draft", label: "Team draft" },
  { value: "sealed", label: "Sealed" },
  { value: "team_sealed", label: "Team sealed" },
];

export const isTeamFormat = (f: FormatName | null | undefined) => f === "team_draft" || f === "team_sealed";
export const isDraftFormat = (f: FormatName | null | undefined) => f === "draft" || f === "team_draft";
export const typeOfFormat = (f: FormatName): EventType =>
  LIMITED_FORMATS.some((o) => o.value === f) ? "limited" : "constructed";

export function formatLabel(f: FormatName): string {
  return [...CONSTRUCTED_FORMATS, ...LIMITED_FORMATS].find((o) => o.value === f)?.label ?? f;
}

/** Name prefilled from the format: "Modern night", "Duskmourn draft", "Vintage Cube team draft". */
export function defaultEventName(f: FormatName, opts: { other?: string; product?: string | null } = {}): string {
  if (typeOfFormat(f) === "constructed") {
    const base = f === "other_constructed" ? opts.other?.trim() || "Constructed" : formatLabel(f);
    return `${base} night`;
  }
  const what = formatLabel(f).toLowerCase();
  const product = opts.product?.trim();
  if (product) return `${product} ${what}`;
  return `${formatLabel(f)} night`;
}

/** What the server will call a new event: "<format label> · <Tue 14 Oct>". */
export function eventNamePreview(
  f: FormatName,
  opts: { other?: string; product?: string | null } = {},
  date = new Date(),
): string {
  const base = f === "other_constructed" ? opts.other?.trim() || "Constructed" : formatLabel(f);
  const product = opts.product?.trim();
  const day = `${date.toLocaleDateString("en-US", { weekday: "short" })} ${date.getDate()} ${date.toLocaleDateString("en-US", { month: "short" })}`;
  return `${product ? `${base} · ${product}` : base} · ${day}`;
}

/** Seat letter on a team: slot 1 = A. */
export const slotLetter = (slot: number | null | undefined) => (slot && slot > 0 ? String.fromCharCode(64 + slot) : "–");
