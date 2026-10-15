import { CONSTRUCTED_FORMATS, LIMITED_FORMATS, typeOfFormat } from "../lib/formats";
import type { DraftableSet, FormatName } from "../lib/types";
import { SetPicker } from "./SetPicker";
import { Field, Notice, Segmented } from "./kit";

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
  const urlProblem = product === "cube" ? cubeUrlProblem(cubeUrl) : null;
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
        <>
          <Field
            label="Cube name"
            value={cubeName}
            onChange={(v) => onCubeName(v.slice(0, 80))}
            onBlur={onCommit}
            placeholder="e.g. Vintage Cube"
          />
          <Field
            label="CubeCobra link (optional)"
            value={cubeUrl}
            onChange={onCubeUrl}
            onBlur={onCommit}
            placeholder="https://cubecobra.com/cube/overview/…"
            type="url"
          />
          {urlProblem && <Notice tone="error">The link must start with https://</Notice>}
        </>
      )}
    </>
  );
}
