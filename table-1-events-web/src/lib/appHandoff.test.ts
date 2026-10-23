import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { phonePlatform, signInHint, storeLink, type Phone } from "./appHandoff";

/* Get the app after joining, against the cases the Android app shares (it reads the referrer this builds). */

const cases = JSON.parse(readFileSync(new URL("../../../testdata/app-handoff/cases.json", import.meta.url), "utf8"));

describe("app handoff", () => {
  it("platforms", () => {
    for (const c of cases.platform as { ua: string; want: Phone | null }[]) expect(phonePlatform(c.ua), c.ua).toBe(c.want);
  });

  it("store links", () => {
    for (const c of cases.store) expect(storeLink(c.platform, c.base, c.event_id)).toBe(c.want);
  });

  it("the Android referrer is what Play hands back", () => {
    // Play decodes the referrer parameter once before the app reads it.
    const url = new URL(storeLink("android", "https://play.google.com/store/apps/details?id=x", "E1")!);
    expect(url.searchParams.get("referrer")).toBe("t1=%2Fp%2FE1");
    expect(cases.referrer.some((r: { raw: string }) => r.raw.startsWith("t1=%2Fp%2F"))).toBe(true);
  });

  it("sign-in hints", () => {
    for (const c of cases.hint) expect(signInHint(c.provider, c.email)).toBe(c.want);
  });
});
