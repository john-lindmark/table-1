/**
 * A set's Scryfall symbol, tinted with the text colour (CSS mask), so it reads on the dark surface and
 * inverts with the row when selected. draftable_sets rows carry the exact URL; otherwise Scryfall's path by code.
 */
export function SetIcon({ code, uri, size = 18, className = "" }: { code: string; uri?: string | null; size?: number; className?: string }) {
  const src = uri ?? `https://svgs.scryfall.io/sets/${code.toLowerCase()}.svg`;
  return (
    <span
      aria-hidden
      className={`inline-block shrink-0 bg-current ${className}`}
      style={{
        width: size,
        height: size,
        WebkitMaskImage: `url("${src}")`,
        maskImage: `url("${src}")`,
        WebkitMaskRepeat: "no-repeat",
        maskRepeat: "no-repeat",
        WebkitMaskPosition: "center",
        maskPosition: "center",
        WebkitMaskSize: "contain",
        maskSize: "contain",
      }}
    />
  );
}
