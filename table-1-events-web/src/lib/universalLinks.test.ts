import { readFileSync } from "node:fs";
import { matchPath } from "react-router-dom";
import { describe, expect, it } from "vitest";

/* Universal / app links (contract/universal-links-2026-10-22.md). The apps parse testdata/universal-links/cases.json
   in their own tests; this one checks the three places that must agree with them: every link an app opens is also a
   page here (for phones without the app), and both apple-app-site-association and the Android manifest claim it, while
   the pages left to the browser stay unclaimed. */

type Case = { url: string; to: string | null; browser?: boolean };
const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const cases: Case[] = JSON.parse(read("../../../testdata/universal-links/cases.json")).cases;
const aasa = JSON.parse(read("../../public/.well-known/apple-app-site-association"));
const manifest = read("../../../apps/android/app/src/main/AndroidManifest.xml");
const routes = [...read("../App.tsx").matchAll(/<Route path="([^"]+)"/g)].map((m) => m[1]).filter((p) => p !== "*");

/** Apple's pattern rules: * is any run of characters, ? one character. */
function glob(pattern: string, value: string) {
  const re = pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".");
  return new RegExp(`^${re}$`).test(value);
}

/** The first component that matches decides; an exclude means Safari keeps the link. */
function appleClaims(u: URL) {
  type Component = { "/"?: string; "?"?: Record<string, string>; "#"?: string; exclude?: boolean };
  const components: Component[] = aasa.applinks.details[0].components;
  const query = Object.fromEntries(u.searchParams);
  for (const c of components) {
    if (c["/"] !== undefined && !glob(c["/"], u.pathname)) continue;
    if (c["#"] !== undefined && !glob(c["#"], u.hash.slice(1))) continue;
    if (c["?"] && !Object.entries(c["?"]).every(([k, p]) => k in query && glob(p, query[k]))) continue;
    return !c.exclude;
  }
  return false;
}

/** The app-link filter's paths (Android matches by path only). */
function androidClaims(u: URL) {
  const filter = manifest.match(/<intent-filter android:autoVerify="true">[\s\S]*?<\/intent-filter>/)?.[0] ?? "";
  const hosts = [...filter.matchAll(/android:host="([^"]+)"/g)].map((m) => m[1]);
  const paths = [...filter.matchAll(/android:path="([^"]+)"/g)].map((m) => m[1]);
  const prefixes = [...filter.matchAll(/android:pathPrefix="([^"]+)"/g)].map((m) => m[1]);
  return hosts.includes(u.hostname) && (paths.includes(u.pathname) || prefixes.some((p) => u.pathname.startsWith(p)));
}

describe("universal links", () => {
  const opened = cases.filter((c) => c.to && c.to !== "web");

  it.each(opened.map((c) => [c.url, c]))("%s opens in the app, or on the web without it", (_, c) => {
    const u = new URL(c.url);
    expect(appleClaims(u)).toBe(true);
    expect(androidClaims(u)).toBe(true);
    expect(routes.some((r) => matchPath(r, u.pathname.replace(/(.)\/$/, "$1")))).toBe(true);
  });

  it.each(cases.filter((c) => c.browser).map((c) => [c.url, c]))("%s stays in the browser", (_, c) => {
    const u = new URL(c.url);
    expect(appleClaims(u)).toBe(false);
    if (!u.hash && !u.search) expect(androidClaims(u)).toBe(false);
  });

  // The TV display (contract/public-events-leagues-2026-11-13.md § 5) is a web page only: a phone that scans the
  // organizer's Display QR, or a TV's browser, must not be handed to the app.
  it("the TV display stays in the browser and is a page here", () => {
    for (const host of ["table-1.site", "www.table-1.site"]) {
      const u = new URL(`https://${host}/d/8f3c1d2e-0000-4000-8000-000000000000`);
      expect(appleClaims(u)).toBe(false);
      expect(androidClaims(u)).toBe(false);
      expect(routes.some((r) => matchPath(r, u.pathname))).toBe(true);
    }
  });

  it("claims both hosts", () => {
    expect(androidClaims(new URL("https://www.table-1.site/library"))).toBe(true);
    expect(read("../../../apps/ios/project.yml")).toContain('"applinks:table-1.site", "applinks:www.table-1.site"');
  });
});
