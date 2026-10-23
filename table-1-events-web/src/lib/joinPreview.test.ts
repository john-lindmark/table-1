import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { joinHeader } from "./joinPreview";

/* The header over sign-in for a scanned join QR, against the cases the apps share. */

const cases: { name: string; wire: unknown; want: unknown }[] = JSON.parse(
  readFileSync(new URL("../../../testdata/join-preview/cases.json", import.meta.url), "utf8"),
).cases;

describe("joinHeader", () => {
  it.each(cases.map((c) => [c.name, c] as const))("%s", (_, c) => {
    expect(joinHeader(c.wire)).toEqual(c.want);
  });
});
